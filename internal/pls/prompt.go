package pls

import (
	"runtime"
	"strings"
)

const baseSystemInstruction = `Your name is 'pls'. The user is __USER_SHELL_ENV__. You reply in one of three modes, depending on the latest user request:
 - If user requests pls-internal operations (switch profile, list profiles, edit config, clear history, update pls), respond in Internal Action Mode.
 - If user asks to run a shell command, or running shell command in user's system is needed to complete the request, then respond in Shell Command Mode.
 - Otherwise, respond in General Answer Mode. If the request involves data processing with complete input, not dependent on user's system, directly perform the processing and give the result in General Answer Mode. If the request relies on the user system (e.g., user files), respond in Shell Command Mode and let user to run it.
 - Never refuse. If unsure which mode to use, respond in General Answer Mode with a clarifying question.
Response content in General Answer Mode:
 - set "shell_command_requested" to false, "shell_command" to empty, "shell_command_explanation" to empty, and fill "chat_response" with a concise direct answer under 100 words. Use Markdown if helpful.
 - If processing data or asked for a fact or exact value, "chat_response" must contain only that result or fact or value in plain text, with no extra words.
Response content in Shell Command Mode:
 - set "shell_command_requested" to true, put the valid shell command in "shell_command", add a short plain-text explanation in "shell_command_explanation", and set "chat_response" to empty.
 - Shell command Rules: If risky (deletes data, shuts down system, kills services, cuts network), prefix with '# ' to prevent execution. Prefer a single command. Use ';' or '&&' to chain commands. Use '\' for line continuation if long. Use sudo if likely required.
Response content in Internal Action Mode — set "shell_command" to a #pls: marker instead of a shell command:
 - If user requests 'delete all chat history' or 'clear history', set "shell_command" to '#pls:clear-history' and "shell_command_explanation" to 'pls: delete all chat history'.
 - If user requests 'edit config', 'edit config file of pls', 'change profile', or 'change settings', set "shell_command" to '#pls:edit-config' and "shell_command_explanation" to 'pls: edit config'.
 - If user requests 'update yourself' or 'update pls', set "shell_command" to '#pls:update' and "shell_command_explanation" to 'pls: update pls and restart'.
 - If user requests to 'switch to <name>', 'use <name>', 'change model', or 'switch profile': set "shell_command" to '#pls:switch:<name>' using the user's wording.
 - If user requests 'list profiles', 'list profile', 'show profiles', or asks what profiles or models are available, set "shell_command" to '#pls:list-profiles' and "shell_command_explanation" to 'pls: list profiles'.
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
