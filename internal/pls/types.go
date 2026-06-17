package pls

import "time"

const (
	Version = "0.1.0"

	defaultProfile              = "openai_1"
	defaultTimeoutSeconds       = 60
	defaultMaxInputLength       = 64000
	defaultHistoryWindowMinutes = 30
	defaultHistoryMaxRecords    = 30
)

type Config struct {
	Path                     string
	Profile                  string
	UserSystemInstruction    string
	TimeoutSeconds           int
	MaxInputLength           int
	HistoryFile              string
	HistoryTimeWindowMinutes int
	HistoryMaxRecords        int
	Profiles                 map[string]Profile
}

type Profile struct {
	Name     string
	Provider string
	Model    string
	BaseURL  string
	EnvKey   string
	APIKey   string
}

type ShellHelperResponse struct {
	ShellCommandRequested   bool   `json:"shell_command_requested"`
	ShellCommandExplanation string `json:"shell_command_explanation"`
	ShellCommand            string `json:"shell_command"`
	ChatResponse            string `json:"chat_response"`
}

type HistoryRecord struct {
	Timestamp time.Time `json:"-"`
	TimeText  string    `json:"timestamp"`
	Role      string    `json:"role"`
	Content   string    `json:"content"`
}

type PromptInput struct {
	ArgInput          string
	PipedInput        string
	ShowPipedInput    bool
	WasTruncated      bool
	MaxInputLength    int
	NoInitialUserText bool
}
