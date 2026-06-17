package pls

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/chzyer/readline"
	markdown "github.com/cjccjj/mdflow/pkg/markdown"
)

type App struct {
	in     *os.File
	out    io.Writer
	errOut io.Writer
	env    map[string]string
}

func NewApp(in *os.File, out, errOut io.Writer, environ []string) *App {
	env := map[string]string{}
	for _, item := range environ {
		k, v, ok := strings.Cut(item, "=")
		if ok {
			env[k] = v
		}
	}
	return &App{in: in, out: out, errOut: errOut, env: env}
}

func (a *App) Run(ctx context.Context, args []string) error {
	parsed, err := parseArgs(args)
	if err != nil {
		return err
	}
	if parsed.help {
		fmt.Fprint(a.errOut, Usage())
		return nil
	}

	cfg, err := LoadConfig(a.env)
	if err != nil {
		return err
	}
	profile, err := cfg.ActiveProfile(a.env)
	if err != nil {
		return err
	}
	piped, err := a.readPipedInput()
	if err != nil {
		return err
	}
	if parsed.showPiped && piped != "" {
		showPipedInput(a.errOut, piped)
	}

	prompt, truncated := BuildPrompt(PromptInput{
		ArgInput:       strings.Join(parsed.messages, " "),
		PipedInput:     piped,
		MaxInputLength: cfg.MaxInputLength,
	})
	history := HistoryStore{Path: cfg.HistoryFile}
	client := OpenAIClient{
		Profile: profile,
		Config:  cfg,
		System:  BuildSystemInstruction(cfg, a.env["USER"], filepath.Base(a.env["SHELL"])),
		History: history,
	}
	stdoutTTY := isTerminalWriter(a.out)
	if !stdoutTTY {
		if prompt == "" {
			return fmt.Errorf("no input provided")
		}
		resp, streamed, err := a.createResponseStreaming(ctx, client, prompt)
		if err != nil {
			return err
		}
		if resp.ShellCommandRequested {
			_ = history.Add(prompt, `suggested shell cmd:"`+resp.ShellCommand+`"`)
			if !streamed {
				fmt.Fprintln(a.out, resp.ShellCommand)
			}
		} else {
			_ = history.Add(prompt, resp.ChatResponse)
			if !streamed {
				fmt.Fprintln(a.out, resp.ChatResponse)
			}
		}
		if truncated {
			fmt.Fprintln(a.errOut, "Note: this response is generated on a truncated input")
		}
		return nil
	}
	return a.interactive(ctx, client, history, prompt, truncated)
}

func (a *App) interactive(ctx context.Context, client OpenAIClient, history HistoryStore, prompt string, truncated bool) error {
	readerFile := a.in
	if !isTerminalFile(readerFile) {
		tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
		if err == nil {
			defer tty.Close()
			readerFile = tty
		}
	}
	reader := bufio.NewReader(readerFile)
	var resp ShellHelperResponse
	var streamed bool
	action := "empty_user_prompt"
	if prompt != "" {
		resp2, streamed2, err := a.createResponseStreaming(ctx, client, prompt)
		if err != nil {
			return err
		}
		resp = resp2
		streamed = streamed2
		action = "new_assistant_response"
	}

	for {
		if action == "new_assistant_response" {
			if resp.ShellCommandRequested {
				action = "cmd_new_response"
			} else {
				action = "chat_new_response"
			}
		}
		switch action {
		case "empty_user_prompt":
			fmt.Fprint(a.out, "\n  Hi!\n\n")
			action = "chat_new_response"
		case "chat_new_response":
			if prompt != "" {
				if err := history.Add(prompt, resp.ChatResponse); err != nil {
					return err
				}
				if resp.ChatResponse != "" && !streamed {
					a.renderMarkdown(resp.ChatResponse)
				}
			}
			a.showMenu("q", truncated)
		case "cmd_new_response":
			if err := history.Add(prompt, `suggested shell cmd:"`+resp.ShellCommand+`"`); err != nil {
				return err
			}
			if !streamed {
				fmt.Fprintf(a.out, "\n%s# %s%s\n", colorGrey, resp.ShellCommandExplanation, colorReset)
				fmt.Fprintf(a.out, "%s# Command:%s\n", colorGrey, colorReset)
				fmt.Fprintf(a.out, "%s%s%s\n", colorYellow, resp.ShellCommand, colorReset)
			}
			a.showMenu("req", truncated)
		case "cmd_edited":
			fmt.Fprintf(a.out, "%s# Updated command:%s\n", colorGrey, colorReset)
			fmt.Fprintf(a.out, "%s%s%s\n", colorYellow, resp.ShellCommand, colorReset)
			a.showMenu("req", truncated)
		case "cmd_executed":
			a.showMenu("eq", truncated)
		}

		streamed = false
		fmt.Fprintf(a.out, "%s>%s ", colorGreen, colorReset)
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return err
		}
		userInput := strings.TrimSpace(line)
		if err == io.EOF && userInput == "" {
			return nil
		}

		switch {
		case userInput == "" || strings.EqualFold(userInput, "q"):
			fmt.Fprintf(a.out, "%sbye%s\n", colorGrey, colorReset)
			return nil
		case strings.EqualFold(userInput, "r") && (action == "cmd_new_response" || action == "cmd_edited"):
			ok := a.runShellCommand(resp.ShellCommand)
			if ok {
				_ = history.Add(`Command succeeded: "`+resp.ShellCommand+`"`, "Ok")
			} else {
				_ = history.Add(`Command failed: "`+resp.ShellCommand+`"`, "Sorry")
			}
			action = "cmd_executed"
		case strings.EqualFold(userInput, "e") && (action == "cmd_new_response" || action == "cmd_edited" || action == "cmd_executed"):
			edited := a.editShellCommand(resp.ShellCommand)
			if edited != "" {
				resp.ShellCommand = edited
			}
			action = "cmd_edited"
		default:
			prompt, truncated = BuildPrompt(PromptInput{ArgInput: userInput, MaxInputLength: client.Config.MaxInputLength})
			resp2, streamed2, err := a.createResponseStreaming(ctx, client, prompt)
			if err != nil {
				return err
			}
			resp = resp2
			streamed = streamed2
			action = "new_assistant_response"
		}
	}
}

func (a *App) createResponseStreaming(ctx context.Context, client OpenAIClient, prompt string) (ShellHelperResponse, bool, error) {
	useTTY := isTerminalWriter(a.out)
	var spinnerStop func()
	var mdRenderer *markdown.Renderer
	if useTTY {
		spinnerStop = startSpinner(a.errOut, client.Profile.Model)
		mdRenderer = markdown.NewRenderer(a.out)
	}
	streamed := false
	var seenExplanation bool

	resp, err := client.CreateResponse(ctx, prompt, StreamHooks{OnDelta: func(field, content string) {
		if !streamed {
			if useTTY {
				spinnerStop()
				fmt.Fprintln(a.out)
			}
			streamed = true
		}
		if !useTTY && field == "shell_command_explanation" {
			return
		}
		switch field {
		case "shell_command_explanation":
			if useTTY {
				if !seenExplanation {
					seenExplanation = true
					fmt.Fprint(a.out, colorGrey+"# ")
				}
				fmt.Fprint(a.out, colorGrey+content+colorReset)
			}
		case "shell_command":
			if useTTY {
				if seenExplanation {
					seenExplanation = false
					fmt.Fprintf(a.out, "\n%s# Command:%s\n", colorGrey, colorReset)
				}
				fmt.Fprint(a.out, colorYellow+content+colorReset)
			} else {
				fmt.Fprint(a.out, content)
			}
		case "chat_response":
			if useTTY {
				mdRenderer.Write([]byte(content))
			} else {
				fmt.Fprint(a.out, content)
			}
		}
	}})
	if mdRenderer != nil {
		mdRenderer.Close()
	}
	if !streamed {
		if useTTY {
			spinnerStop()
		}
	} else {
		fmt.Fprintln(a.out)
	}
	return resp, streamed, err
}

func (a *App) showMenu(items string, truncated bool) {
	fmt.Fprintln(a.out, formatMenu(items))
	if truncated {
		fmt.Fprintln(a.errOut, "Note: this response is generated on a truncated input")
	}
}

func (a *App) editShellCommand(current string) string {
	singleLine := strings.ReplaceAll(current, "\\\n", "")
	singleLine = strings.ReplaceAll(singleLine, "\n", " ")
	fmt.Fprintf(a.out, "\n%s# Edit:%s\n", colorGrey, colorReset)
	fmt.Fprintf(a.out, "%s( %s⏎%s : save changes, won't run yet )%s\n", colorGrey, colorCyan, colorGrey, colorReset)

	prompt := fmt.Sprintf("%s>%s ", colorGreen, colorReset)
	rl, err := readline.NewEx(&readline.Config{Prompt: prompt})
	if err != nil {
		return current
	}
	defer rl.Close()
	rl.SetPrompt(prompt)
	// Pre-fill the buffer by writing the current command
	rl.WriteStdin([]byte(singleLine))

	line, err := rl.Readline()
	if err != nil {
		return current
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return current
	}
	return line
}

func (a *App) runShellCommand(command string) bool {
	appendShellHistory(a.env["HOME"], command)
	shell := a.env["SHELL"]
	if shell == "" {
		shell = "/bin/sh"
	}
	cmd := exec.Command(shell, "-c", command)
	cmd.Stdin = a.in
	cmd.Stdout = a.out
	cmd.Stderr = a.errOut
	err := cmd.Run()
	if err != nil {
		fmt.Fprintf(a.out, "%s# Command failed%s\n", colorGrey, colorReset)
		return false
	}
	fmt.Fprintf(a.out, "%s# Command succeeded%s\n", colorGrey, colorReset)
	return true
}

func appendShellHistory(home, command string) {
	if home == "" || command == "" {
		return
	}
	path := filepath.Join(home, ".bash_history")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	fmt.Fprintln(file, command)
}

func (a *App) renderMarkdown(s string) {
	if isTerminalWriter(a.out) {
		r := markdown.NewRenderer(a.out)
		r.Write([]byte(s))
		r.Close()
		return
	}
	fmt.Fprintf(a.out, "\n%s\n\n", s)
}

func (a *App) readPipedInput() (string, error) {
	if a.in == nil || isTerminalFile(a.in) {
		return "", nil
	}
	b, err := io.ReadAll(a.in)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func showPipedInput(w io.Writer, s string) {
	fmt.Fprintln(w, ">")
	preview := s
	if len(preview) > 250 {
		preview = preview[:250] + "\n..."
	}
	fmt.Fprintln(w, preview)
}

type parsedArgs struct {
	help      bool
	showPiped bool
	messages  []string
}

func parseArgs(args []string) (parsedArgs, error) {
	var out parsedArgs
	if len(args) > 0 {
		switch args[0] {
		case "-h", "--help":
			out.help = true
			return out, nil
		case "-p":
			out.showPiped = true
			args = args[1:]
		}
	}
	if len(args) > 0 && strings.HasPrefix(args[0], "-") {
		return parsedArgs{}, errors.New(Usage())
	}
	out.messages = args
	return out, nil
}

func Usage() string {
	return fmt.Sprintf(`pls v%s

Usage:    pls [messages...]                       # Chat with an input
          > what is llm                           # Continue chat, q or empty input to quit

Examples: pls                                     # Start without input
          pls count files                         # ls -1 | wc -l
          > include subdirs                       # find . -type f | wc -l

Pipe and Chain:
          echo how to cook rice | pls             # Use input from pipe
          echo rice | pls how to cook             # Args + pipe
          pls name a dish | pls -p how to cook    # Chain commands and show piped input with -p

Settings: pls -h                                  # Show this help
          pls edit config                         # config pls and AI model via chat
`, Version)
}

func isTerminalFile(f *os.File) bool {
	if f == nil {
		return false
	}
	info, err := f.Stat()
	return err == nil && (info.Mode()&os.ModeCharDevice) != 0
}

func isTerminalWriter(w io.Writer) bool {
	f, ok := w.(*os.File)
	return ok && isTerminalFile(f)
}
