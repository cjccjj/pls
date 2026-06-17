package pls

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenAIPayloadIncludesHistoryAndSchema(t *testing.T) {
	home := t.TempDir()
	cfg := defaultConfig(filepath.Join(home, ".pls", "pls.conf"), home)
	cfg.HistoryFile = filepath.Join(home, ".pls", "hist.log")
	history := HistoryStore{Path: cfg.HistoryFile}
	if err := history.Add("hello", "hi"); err != nil {
		t.Fatal(err)
	}
	client := OpenAIClient{
		Profile: cfg.Profiles["openai_1"],
		Config:  cfg,
		System:  "sys",
		History: history,
	}
	payload, err := client.payload("next", true)
	if err != nil {
		t.Fatal(err)
	}
	if payload["stream"] != true {
		t.Fatalf("stream = %#v", payload["stream"])
	}
	input := payload["input"].([]map[string]string)
	if len(input) != 4 || input[0]["role"] != "developer" || input[3]["content"] != "next" {
		t.Fatalf("input = %#v", input)
	}
	text := payload["text"].(map[string]any)
	format := text["format"].(map[string]any)
	if format["type"] != "json_schema" {
		t.Fatalf("format = %#v", format)
	}
	reasoning := payload["reasoning"].(map[string]any)
	if reasoning["effort"] != "minimal" {
		t.Fatalf("reasoning = %#v", reasoning)
	}
}

func TestOpenAICreateResponseParsesStructuredOutput(t *testing.T) {
	var request map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/responses" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("auth = %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		fmt.Fprint(w, `{"output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hello\"}"}]}]}`)
	}))
	defer server.Close()

	cfg := defaultConfig("/tmp/pls.conf", t.TempDir())
	profile := cfg.Profiles["openai_1"]
	profile.BaseURL = server.URL
	profile.APIKey = "test-key"
	client := OpenAIClient{Profile: profile, Config: cfg, System: "sys", History: HistoryStore{Path: filepath.Join(t.TempDir(), "hist")}}
	resp, err := client.CreateResponse(context.Background(), "hello", StreamHooks{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
	if request["stream"] != nil {
		t.Fatalf("unexpected stream in request: %#v", request)
	}
}

func TestOpenAIStreamParsesAndStreamsChatResponse(t *testing.T) {
	var deltas []string
	body := strings.Join([]string{
		`sse: ignore`,
		`data: {"type":"response.output_text.delta","delta":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hel"}`,
		`data: {"type":"response.output_text.delta","delta":"lo\"}"}`,
		`data: [DONE]`,
		``,
	}, "\n")
	resp, err := parseOpenAIStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		deltas = append(deltas, content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" {
		t.Fatalf("resp = %#v", resp)
	}
	if strings.Join(deltas, "") != "hello" {
		t.Fatalf("deltas = %#v", deltas)
	}
}

func TestOpenAIStreamStreamsExplanationThenCommand(t *testing.T) {
	var events []string
	body := strings.Join([]string{
		`data: {"type":"response.output_text.delta","delta":"{\"shell_command_requested\":true,\"shell_command_explanation\":\"list\",\"shell_command\":\"ls\",\"chat_response\":\"\"}"}`,
		`data: [DONE]`,
		``,
	}, "\n")
	resp, err := parseOpenAIStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		events = append(events, field+":"+content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.ShellCommandRequested || resp.ShellCommand != "ls" || resp.ShellCommandExplanation != "list" {
		t.Fatalf("resp = %#v", resp)
	}
	if len(events) < 2 || events[0] != "shell_command_explanation:list" || events[1] != "shell_command:ls" {
		t.Fatalf("events = %#v", events)
	}
}

func TestOpenAIStreamFiltersReasoningEvents(t *testing.T) {
	var deltas []string
	body := strings.Join([]string{
		`data: {"type":"response.reasoning_text.delta","delta":"Let me think..."}`,
		`data: {"type":"response.reasoning_text.done","text":"Let me think about this carefully."}`,
		`data: {"type":"response.output_text.delta","delta":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hel"}`,
		`data: {"type":"response.output_text.delta","delta":"lo\"}"}`,
		`data: [DONE]`,
		``,
	}, "\n")
	resp, err := parseOpenAIStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		deltas = append(deltas, content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
	if strings.Join(deltas, "") != "hello" {
		t.Fatalf("deltas = %#v", deltas)
	}
}

func TestDeepSeekPayloadIncludesToolCall(t *testing.T) {
	cfg := defaultConfig("/tmp/pls.conf", t.TempDir())
	cfg.HistoryFile = filepath.Join(t.TempDir(), "hist.log")
	client := OpenAIClient{
		Profile: cfg.Profiles["deepseek_1"],
		Config:  cfg,
		System:  "sys",
		History: HistoryStore{Path: cfg.HistoryFile},
	}
	payload, err := client.deepseekPayload("test", false)
	if err != nil {
		t.Fatal(err)
	}
	if payload["model"] != "deepseek-v4-flash" {
		t.Fatalf("model = %v", payload["model"])
	}
	tools := payload["tools"].([]map[string]any)
	if len(tools) != 1 || tools[0]["type"] != "function" {
		t.Fatalf("tools = %v", tools)
	}
	if payload["stream"] != false {
		t.Fatalf("stream = %v", payload["stream"])
	}
	messages := payload["messages"].([]map[string]string)
	if messages[0]["role"] != "system" || messages[1]["role"] != "user" {
		t.Fatalf("messages = %#v", messages)
	}
}

func TestDeepSeekResponseParsesToolCall(t *testing.T) {
	body := `{"choices":[{"message":{"tool_calls":[{"function":{"arguments":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hello\"}"}}]}}]}`
	resp, err := parseDeepSeekResponse(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
}

func TestDeepSeekStreamParsesArguments(t *testing.T) {
	var deltas []string
	body := strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"{\"shell"}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hel"}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"lo\"}"}}]}}]}`,
		`data: {"choices":[{"index":0,"finish_reason":"tool_calls"}]}`,
		`data: [DONE]`,
		``,
	}, "\n")
	resp, err := parseDeepSeekStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		deltas = append(deltas, content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
	if strings.Join(deltas, "") != "hello" {
		t.Fatalf("deltas = %#v", deltas)
	}
}

func TestDeepSeekStreamChatBeforeFlag(t *testing.T) {
	// DeepSeek often emits chat_response before shell_command_requested
	var deltas []string
	body := strings.Join([]string{
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"{\"chat_response\":\"hel"}}]}}]}`,
		`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"lo\",\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\"}"}}]}}]}`,
		`data: {"choices":[{"index":0,"finish_reason":"tool_calls"}]}`,
		`data: [DONE]`,
		``,
	}, "\n")
	resp, err := parseDeepSeekStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		deltas = append(deltas, content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
	if strings.Join(deltas, "") != "hello" {
		t.Fatalf("deltas = %#v", deltas)
	}
}

func TestGeminiPayloadIncludesSchema(t *testing.T) {
	cfg := defaultConfig("/tmp/pls.conf", t.TempDir())
	cfg.HistoryFile = filepath.Join(t.TempDir(), "hist.log")
	client := OpenAIClient{
		Profile: cfg.Profiles["gemini_1"],
		Config:  cfg,
		System:  "sys",
		History: HistoryStore{Path: cfg.HistoryFile},
	}
	payload, err := client.geminiPayload("test")
	if err != nil {
		t.Fatal(err)
	}
	si := payload["system_instruction"].(map[string]any)
	if si["parts"] == nil {
		t.Fatalf("system_instruction = %v", si)
	}
	gc := payload["generationConfig"].(map[string]any)
	if gc["responseMimeType"] != "application/json" {
		t.Fatalf("generationConfig = %v", gc)
	}
	contents := payload["contents"].([]map[string]any)
	if contents[0]["role"] != "user" {
		t.Fatalf("contents = %v", contents)
	}
}

func TestGeminiResponseParsesContent(t *testing.T) {
	body := `{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hello\"}"}]}}]}`
	resp, err := parseGeminiResponse(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
}

func TestGeminiHistoryRoleMapping(t *testing.T) {
	home := t.TempDir()
	history := HistoryStore{Path: filepath.Join(home, "hist.log")}
	if err := history.Add("user msg", "assistant msg"); err != nil {
		t.Fatal(err)
	}
	cfg := defaultConfig("/tmp/pls.conf", t.TempDir())
	cfg.HistoryFile = history.Path
	client := OpenAIClient{
		Profile: cfg.Profiles["gemini_1"],
		Config:  cfg,
		System:  "sys",
		History: history,
	}
	payload, err := client.geminiPayload("next")
	if err != nil {
		t.Fatal(err)
	}
	contents := payload["contents"].([]map[string]any)
	// Add() writes user + assistant pairs; index 1 should be role=mapped-to-model
	if len(contents) < 2 || contents[1]["role"] != "model" {
		t.Fatalf("expected role=model for assistant history at index 1, got %v", contents)
	}
}

func TestGeminiStreamDiffsAndParses(t *testing.T) {
	var deltas []string
	body := strings.Join([]string{
		`data: {"candidates":[{"content":{"parts":[{"text":"{\"shell_command_requested\":false,\"shell_command_explanation\":\"\",\"shell_command\":\"\",\"chat_response\":\"hel"}]}}]}`,
		`data: {"candidates":[{"content":{"parts":[{"text":"lo\"}"}]}}]}`,
		`data: {"candidates":[{"content":{"parts":[{"text":""}]},"finishReason":"STOP"}]}`,
		``,
	}, "\n")
	resp, err := parseGeminiStream(strings.NewReader(body), StreamHooks{OnDelta: func(field, content string) {
		deltas = append(deltas, content)
	}})
	if err != nil {
		t.Fatal(err)
	}
	if resp.ChatResponse != "hello" || resp.ShellCommandRequested {
		t.Fatalf("resp = %#v", resp)
	}
	if strings.Join(deltas, "") != "hello" {
		t.Fatalf("deltas = %#v", deltas)
	}
}
