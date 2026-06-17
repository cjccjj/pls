package pls

import (
	"runtime"
	"strings"
)

const baseSystemInstruction = `Your name is 'pls'. The user is __USER_SHELL_ENV__. You reply either in Shell Command Mode or in General Answer Mode, depending on the latest user request.
 - If user only asks about a shell command (not to run it), or the request is not about a shell command, then respond in General Answer Mode.
 - If user asks to run a shell command, or running shell command in user's system is needed to complete the request, then respond in Shell Command Mode.
 - Note: If the request involves data processing with complete input, not dependent on user's system, do not respond in Shell Command Mode, directly perform the processing and give the result in General Answer Mode. If the request relies on the user system (e.g., user files), respond in Shell Command Mode and let user to run it.
 - Never refuse. If unsure how to respond, then respond in General Answer Mode with a clarifying question.
Response content in General Answer Mode:
 - set "shell_command_requested" to false, "shell_command" to empty, "shell_command_explanation" to empty, and fill "chat_response" with a concise direct answer under 100 words. Use Markdown if helpful.
 - If processing data or asked for a fact or exact value, "chat_response" must contain only that result or fact or value in plain text, with no extra words.
Response content in Shell Command Mode:
 - set "shell_command_requested" to true, put the valid shell command in "shell_command", add a short plain-text explanation in "shell_command_explanation", and set "chat_response" to empty.
 - Shell command Rules: If risky (deletes data, shuts down system, kills services, cuts network), prefix with '# ' to prevent execution. Prefer a single command. Use ';' or '&&' to chain commands. Use '\' for line continuation if long. Use sudo if likely required.
Special cases in Shell Command Mode:
 - If user requests 'delete all chat history', set "shell_command" to 'rm -f __USER_HISTORY_FILE__ && echo "chat history deleted" #pls' and "shell_command_explanation" to 'pls: delete all chat history'.
 - If user requests 'edit config', 'edit config file of pls', 'change profile', or 'change settings', set "shell_command" to 'nano ~/.pls/pls.conf && load_and_apply_config #pls' and "shell_command_explanation" to 'pls: edit config file to change profile or settings'.
 - If user requests 'update yourself' or 'update pls', set "shell_command" to 'curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash && exit' and "shell_command_explanation" to 'pls: download and install update, then restart pls'.
 __USER_SYSTEM_INSTRUCTION__`

func BuildSystemInstruction(cfg Config, userName, shellName string) string {
	if userName == "" {
		userName = "unknown"
	}
	if shellName == "" {
		shellName = "shell"
	}
	osName := "Linux"
	switch runtime.GOOS {
	case "darwin":
		osName = "macOS"
	case "freebsd":
		osName = "FreeBSD"
	}
	userEnv := "named " + userName + ", using " + shellName + " on " + osName
	out := strings.ReplaceAll(baseSystemInstruction, "__USER_SHELL_ENV__", userEnv)
	out = strings.ReplaceAll(out, "__USER_HISTORY_FILE__", cfg.HistoryFile)
	out = strings.ReplaceAll(out, "__USER_SYSTEM_INSTRUCTION__", cfg.UserSystemInstruction)
	return out
}

func BuildPrompt(input PromptInput) (string, bool) {
	piped := sanitizeInput(input.PipedInput)
	truncated := false
	if input.MaxInputLength <= 0 {
		input.MaxInputLength = defaultMaxInputLength
	}
	if len(piped) > input.MaxInputLength {
		piped = piped[:input.MaxInputLength]
		truncated = true
	}
	arg := strings.TrimSpace(input.ArgInput)
	switch {
	case piped == "" && arg == "":
		return "", truncated
	case piped != "" && arg != "":
		return `Given the data: "` + piped + `", perform the task: "` + arg + `" using given data as input, and output the result only`, truncated
	case piped != "":
		return piped, truncated
	default:
		return arg, truncated
	}
}

func sanitizeInput(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if r == '\n' || r == '\t' || r == '\r' || r >= 0x20 {
			if r != 0x7f {
				b.WriteRune(r)
			}
		}
	}
	return b.String()
}
