package pls

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func LoadConfig(env map[string]string) (Config, error) {
	home := env["HOME"]
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return Config{}, err
		}
	}

	path := filepath.Join(home, ".pls", "pls.conf")
	if err := ensureDefaultConfig(path); err != nil {
		return Config{}, err
	}

	cfg := defaultConfig(path, home)
	file, err := os.Open(path)
	if err != nil {
		return Config{}, err
	}
	defer file.Close()

	section := ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			if section != "Global" {
				p := cfg.Profiles[section]
				p.Name = section
				cfg.Profiles[section] = p
			}
			continue
		}
		key, value, ok := parseAssignment(line)
		if !ok {
			continue
		}
		value = expandHome(value, home)
		if section == "Global" {
			applyGlobal(&cfg, key, value)
			continue
		}
		if section != "" {
			p := cfg.Profiles[section]
			p.Name = section
			applyProfile(&p, key, value)
			cfg.Profiles[section] = p
		}
	}
	if err := scanner.Err(); err != nil {
		return Config{}, err
	}
	ensureProfiles(&cfg)
	return cfg, nil
}

func (c Config) ActiveProfile(env map[string]string) (Profile, error) {
	p, ok := c.Profiles[c.Profile]
	if !ok {
		return Profile{}, fmt.Errorf("profile %q not found in %s", c.Profile, c.Path)
	}
	if p.Provider != "openai" && p.Provider != "deepseek" && p.Provider != "gemini" {
		return Profile{}, fmt.Errorf("provider %q is not supported; supported providers: openai, deepseek, gemini", p.Provider)
	}
	if p.EnvKey == "" {
		return Profile{}, fmt.Errorf("profile %q is missing env_key", p.Name)
	}
	p.APIKey = env[p.EnvKey]
	if p.APIKey == "" {
		return Profile{}, fmt.Errorf("API key for %q not set. Please export %s", p.Name, p.EnvKey)
	}
	return p, nil
}

func defaultConfig(path, home string) Config {
	return Config{
		Path:                     path,
		Profile:                  defaultProfile,
		TimeoutSeconds:           defaultTimeoutSeconds,
		MaxInputLength:           defaultMaxInputLength,
		HistoryFile:              filepath.Join(home, ".pls", "pls_hist.log"),
		HistoryTimeWindowMinutes: defaultHistoryWindowMinutes,
		HistoryMaxRecords:        defaultHistoryMaxRecords,
		Profiles: map[string]Profile{
			"openai_1": {
				Name:     "openai_1",
				Provider: "openai",
				Model:    "gpt-5-mini",
				BaseURL:  "https://api.openai.com/v1",
				EnvKey:   "OPENAI_API_KEY",
			},
			"openai_2": {
				Name:     "openai_2",
				Provider: "openai",
				Model:    "gpt-5.4",
				BaseURL:  "https://api.openai.com/v1",
				EnvKey:   "OPENAI_API_KEY",
			},
			"deepseek_1": {
				Name:     "deepseek_1",
				Provider: "deepseek",
				Model:    "deepseek-v4-flash",
				BaseURL:  "https://api.deepseek.com/beta",
				EnvKey:   "DEEPSEEK_API_KEY",
			},
			"gemini_1": {
				Name:     "gemini_1",
				Provider: "gemini",
				Model:    "gemini-3-flash-preview",
				BaseURL:  "https://generativelanguage.googleapis.com/v1beta",
				EnvKey:   "GEMINI_API_KEY",
			},
		},
	}
}

func ensureDefaultConfig(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(defaultConfigText), 0o600)
}

func ensureProfiles(cfg *Config) {
	if cfg.Profiles == nil {
		cfg.Profiles = map[string]Profile{}
	}
	profiles := []Profile{
		{Name: "openai_1", Provider: "openai", Model: "gpt-5-mini", BaseURL: "https://api.openai.com/v1", EnvKey: "OPENAI_API_KEY"},
		{Name: "openai_2", Provider: "openai", Model: "gpt-5.4", BaseURL: "https://api.openai.com/v1", EnvKey: "OPENAI_API_KEY"},
		{Name: "deepseek_1", Provider: "deepseek", Model: "deepseek-v4-flash", BaseURL: "https://api.deepseek.com/beta", EnvKey: "DEEPSEEK_API_KEY"},
		{Name: "gemini_1", Provider: "gemini", Model: "gemini-3-flash-preview", BaseURL: "https://generativelanguage.googleapis.com/v1beta", EnvKey: "GEMINI_API_KEY"},
	}
	for _, p := range profiles {
		if _, ok := cfg.Profiles[p.Name]; !ok {
			cfg.Profiles[p.Name] = p
		}
	}
}

func parseAssignment(line string) (string, string, bool) {
	idx := strings.Index(line, "=")
	if idx < 0 {
		return "", "", false
	}
	key := strings.TrimSpace(line[:idx])
	value := strings.TrimSpace(stripInlineComment(line[idx+1:]))
	if key == "" {
		return "", "", false
	}
	if len(value) >= 2 {
		if (value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'') {
			value = value[1 : len(value)-1]
		}
	}
	value = strings.ReplaceAll(value, `\"`, `"`)
	return key, value, true
}

func stripInlineComment(s string) string {
	inSingle, inDouble, escaped := false, false, false
	for i, r := range s {
		if escaped {
			escaped = false
			continue
		}
		if r == '\\' && inDouble {
			escaped = true
			continue
		}
		switch r {
		case '\'':
			if !inDouble {
				inSingle = !inSingle
			}
		case '"':
			if !inSingle {
				inDouble = !inDouble
			}
		case '#':
			if !inSingle && !inDouble {
				return s[:i]
			}
		}
	}
	return s
}

func applyGlobal(cfg *Config, key, value string) {
	switch key {
	case "profile":
		cfg.Profile = value
	case "USER_SYSTEM_INSTRUCTION":
		cfg.UserSystemInstruction = value
	case "timeout_seconds":
		cfg.TimeoutSeconds = parseInt(value, cfg.TimeoutSeconds)
	case "max_input_length":
		cfg.MaxInputLength = parseInt(value, cfg.MaxInputLength)
	case "history_file":
		cfg.HistoryFile = value
	case "history_time_window_minutes":
		cfg.HistoryTimeWindowMinutes = parseInt(value, cfg.HistoryTimeWindowMinutes)
	case "history_max_records":
		cfg.HistoryMaxRecords = parseInt(value, cfg.HistoryMaxRecords)
	}
}

func applyProfile(p *Profile, key, value string) {
	switch key {
	case "provider":
		p.Provider = value
	case "model":
		p.Model = value
	case "base_url":
		p.BaseURL = strings.TrimRight(value, "/")
	case "env_key":
		p.EnvKey = value
	}
}

func parseInt(value string, fallback int) int {
	n, err := strconv.Atoi(value)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func expandHome(value, home string) string {
	value = strings.ReplaceAll(value, "$HOME", home)
	if strings.HasPrefix(value, "~/") {
		value = filepath.Join(home, value[2:])
	}
	return value
}

const defaultConfigText = `[Global]
profile="openai_1"
# Experimental. Teach AI to use your personalized shell command.
# USER_SYSTEM_INSTRUCTION="If user requests 'say thank you to <username>', set \"shell_command\" to 'echo \"<username>, thank you very much\"' and \"shell_command_explanation\" to 'pls: show thanks'."

timeout_seconds=60
max_input_length=64000
history_file="$HOME/.pls/pls_hist.log"
history_time_window_minutes=30
history_max_records=30

[openai_1]
provider="openai"
model="gpt-5-mini"
base_url="https://api.openai.com/v1"
env_key="OPENAI_API_KEY"

[openai_2]
provider="openai"
model="gpt-5.4"
base_url="https://api.openai.com/v1"
env_key="OPENAI_API_KEY"

[deepseek_1]
provider="deepseek"
model="deepseek-v4-flash"
base_url="https://api.deepseek.com/beta"
env_key="DEEPSEEK_API_KEY"

[gemini_1]
provider="gemini"
model="gemini-3-flash-preview"
base_url="https://generativelanguage.googleapis.com/v1beta"
env_key="GEMINI_API_KEY"
`
