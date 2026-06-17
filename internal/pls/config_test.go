package pls

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigCreatesDefaultAndReadsOpenAIProfile(t *testing.T) {
	home := t.TempDir()
	cfg, err := LoadConfig(map[string]string{"HOME": home, "OPENAI_API_KEY": "test-key"})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Profile != "openai_1" {
		t.Fatalf("profile = %q", cfg.Profile)
	}
	if cfg.HistoryFile != filepath.Join(home, ".pls", "pls_hist.log") {
		t.Fatalf("history file = %q", cfg.HistoryFile)
	}
	p, err := cfg.ActiveProfile(map[string]string{"OPENAI_API_KEY": "test-key"})
	if err != nil {
		t.Fatal(err)
	}
	if p.Provider != "openai" || p.APIKey != "test-key" {
		t.Fatalf("profile = %#v", p)
	}
	if _, err := os.Stat(filepath.Join(home, ".pls", "pls.conf")); err != nil {
		t.Fatal(err)
	}
}

func TestParseAssignmentStripsInlineCommentOutsideQuotes(t *testing.T) {
	key, value, ok := parseAssignment(`profile="openai_1" # comment`)
	if !ok || key != "profile" || value != "openai_1" {
		t.Fatalf("got %q %q %v", key, value, ok)
	}
	_, value, ok = parseAssignment(`USER_SYSTEM_INSTRUCTION="keep # inside" # strip`)
	if !ok || value != "keep # inside" {
		t.Fatalf("value = %q", value)
	}
}
