package pls

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAppRawOutputWithFakeOpenAI(t *testing.T) {
	home := t.TempDir()
	var prompt string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Stream bool `json:"stream"`
			Input  []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"input"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		prompt = payload.Input[len(payload.Input)-1].Content
		respJSON := `{"shell_command_requested":false,"shell_command_explanation":"","shell_command":"","chat_response":"ok"}`
		if payload.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":%q}\n\ndata: [DONE]\n\n", respJSON)
		} else {
			fmt.Fprint(w, `{"output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"`+respJSON+`"}]}]}`)
		}
	}))
	defer server.Close()

	writeIntegrationConfig(t, home, server.URL)
	stdin := tempInputFile(t, "")
	defer stdin.Close()
	var stdout, stderr bytes.Buffer
	app := NewApp(stdin, &stdout, &stderr, []string{
		"HOME=" + home,
		"OPENAI_API_KEY=test-key",
		"USER=cj",
		"SHELL=/bin/bash",
	})
	if err := app.Run(context.Background(), []string{"say", "hi"}); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "ok\n" {
		t.Fatalf("stdout = %q stderr = %q", stdout.String(), stderr.String())
	}
	if prompt != "say hi" {
		t.Fatalf("prompt = %q", prompt)
	}
	hist, err := os.ReadFile(filepath.Join(home, ".pls", "pls_hist.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(hist), `"content":"ok"`) {
		t.Fatalf("history = %s", hist)
	}
}

func TestAppPipeAndArgsPromptWithFakeOpenAI(t *testing.T) {
	home := t.TempDir()
	var prompt string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Stream bool `json:"stream"`
			Input  []struct {
				Content string `json:"content"`
			} `json:"input"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		prompt = payload.Input[len(payload.Input)-1].Content
		respJSON := `{"shell_command_requested":true,"shell_command_explanation":"count","shell_command":"wc -l","chat_response":""}`
		if payload.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":%q}\n\ndata: [DONE]\n\n", respJSON)
		} else {
			fmt.Fprint(w, `{"output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"`+respJSON+`"}]}]}`)
		}
	}))
	defer server.Close()

	writeIntegrationConfig(t, home, server.URL)
	stdin := tempInputFile(t, "rice")
	defer stdin.Close()
	var stdout, stderr bytes.Buffer
	app := NewApp(stdin, &stdout, &stderr, []string{
		"HOME=" + home,
		"OPENAI_API_KEY=test-key",
		"USER=cj",
		"SHELL=/bin/bash",
	})
	if err := app.Run(context.Background(), []string{"cook"}); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "wc -l\n" {
		t.Fatalf("stdout = %q stderr = %q", stdout.String(), stderr.String())
	}
	want := `Given the data: "rice", perform the task: "cook" using given data as input, and output the result only`
	if prompt != want {
		t.Fatalf("prompt = %q", prompt)
	}
}

func writeIntegrationConfig(t *testing.T, home, baseURL string) {
	t.Helper()
	dir := filepath.Join(home, ".pls")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	conf := fmt.Sprintf(`[Global]
profile="openai_1"
timeout_seconds=60
max_input_length=64000
history_file="$HOME/.pls/pls_hist.log"
history_time_window_minutes=30
history_max_records=30

[openai_1]
provider="openai"
model="test-model"
base_url="%s"
env_key="OPENAI_API_KEY"
`, baseURL)
	if err := os.WriteFile(filepath.Join(dir, "pls.conf"), []byte(conf), 0o600); err != nil {
		t.Fatal(err)
	}
}

func tempInputFile(t *testing.T, content string) *os.File {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(content); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	return f
}
