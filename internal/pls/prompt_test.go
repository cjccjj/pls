package pls

import (
	"strings"
	"testing"
)

func TestBuildPromptArgsAndPipe(t *testing.T) {
	prompt, truncated := BuildPrompt(PromptInput{
		ArgInput:       "summarize",
		PipedInput:     "hello",
		MaxInputLength: 100,
	})
	if truncated {
		t.Fatal("unexpected truncation")
	}
	want := `Given the data: "hello", perform the task: "summarize" using given data as input, and output the result only`
	if prompt != want {
		t.Fatalf("prompt = %q", prompt)
	}
}

func TestBuildPromptSanitizeAndTruncate(t *testing.T) {
	prompt, truncated := BuildPrompt(PromptInput{
		PipedInput:     "abc\x00\x01def",
		MaxInputLength: 5,
	})
	if !truncated {
		t.Fatal("expected truncation")
	}
	if prompt != "abcde" {
		t.Fatalf("prompt = %q", prompt)
	}
}

func TestSystemInstructionReplacesSpecialCases(t *testing.T) {
	cfg := defaultConfig("/tmp/pls.conf", "/tmp/home")
	cfg.UserSystemInstruction = "custom"
	got := BuildSystemInstruction(cfg, "cj", "bash")
	for _, s := range []string{"named cj", "custom", "update yourself", "#pls:update", "#pls:edit-config", "#pls:clear-history", "#pls:list-profiles", "#pls:switch:"} {
		if !strings.Contains(got, s) {
			t.Fatalf("system instruction missing %q", s)
		}
	}
}
