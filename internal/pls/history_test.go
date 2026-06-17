package pls

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHistoryRecentFiltersWindowAndMax(t *testing.T) {
	now := time.Date(2026, 6, 16, 12, 0, 0, 0, time.Local)
	path := filepath.Join(t.TempDir(), "hist.log")
	data := `{"timestamp":"2026-06-16 11:00:00","role":"user","content":"old"}
{"timestamp":"2026-06-16 11:50:00","role":"assistant","content":"recent 1"}
{"timestamp":"2026-06-16 11:55:00","role":"user","content":"recent 2"}
`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	store := HistoryStore{Path: path, Now: func() time.Time { return now }}
	got, err := store.Recent(2, 30)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Content != "recent 1" || got[1].Content != "recent 2" {
		t.Fatalf("recent = %#v", got)
	}
}

func TestHistoryAddWritesJSONL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hist.log")
	now := time.Date(2026, 6, 16, 12, 0, 0, 0, time.Local)
	store := HistoryStore{Path: path, Now: func() time.Time { return now }}
	if err := store.Add("u", "a"); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "{\"timestamp\":\"2026-06-16 12:00:00\",\"role\":\"user\",\"content\":\"u\"}\n{\"timestamp\":\"2026-06-16 12:00:00\",\"role\":\"assistant\",\"content\":\"a\"}\n"
	if string(got) != want {
		t.Fatalf("history = %q", got)
	}
}
