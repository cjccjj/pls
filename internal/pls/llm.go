package pls

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	HTTPClient *http.Client
	Profile    Profile
	Config     Config
	System     string
	History    HistoryStore
}

type StreamHooks struct {
	OnDelta func(field, content string)
}

func (c Client) CreateResponse(ctx context.Context, prompt string, hooks StreamHooks) (ShellHelperResponse, error) {
	switch c.Profile.Provider {
	case "deepseek":
		return c.createDeepSeekResponse(ctx, prompt, hooks)
	case "gemini":
		return c.createGeminiResponse(ctx, prompt, hooks)
	default:
		return c.createOpenAIResponse(ctx, prompt, hooks)
	}
}

func (c Client) createOpenAIResponse(ctx context.Context, prompt string, hooks StreamHooks) (ShellHelperResponse, error) {
	payload, err := c.payload(prompt, hooks.OnDelta != nil)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	endpoint := strings.TrimRight(c.Profile.BaseURL, "/") + "/responses"
	ctx, cancel := requestContext(ctx, c.Config.TimeoutSeconds)
	defer cancel()
	resp, err := c.doRequest(ctx, endpoint, body, map[string]string{
		"Authorization": "Bearer " + c.Profile.APIKey,
		"Content-Type":  "application/json",
	}, hooks.OnDelta != nil)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		b, _ := io.ReadAll(resp.Body)
		return ShellHelperResponse{}, fmt.Errorf("request failed (%d): %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if hooks.OnDelta != nil {
		return parseOpenAIStream(resp.Body, hooks)
	}
	return parseOpenAIResponse(resp.Body)
}

func (c Client) createDeepSeekResponse(ctx context.Context, prompt string, hooks StreamHooks) (ShellHelperResponse, error) {
	stream := hooks.OnDelta != nil
	payload, err := c.deepseekPayload(prompt, stream)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	endpoint := strings.TrimRight(c.Profile.BaseURL, "/") + "/chat/completions"
	ctx, cancel := requestContext(ctx, c.Config.TimeoutSeconds)
	defer cancel()
	resp, err := c.doRequest(ctx, endpoint, body, map[string]string{
		"Authorization": "Bearer " + c.Profile.APIKey,
		"Content-Type":  "application/json",
	}, stream)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		b, _ := io.ReadAll(resp.Body)
		return ShellHelperResponse{}, fmt.Errorf("request failed (%d): %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if stream {
		return parseDeepSeekStream(resp.Body, hooks)
	}
	return parseDeepSeekResponse(resp.Body)
}

func (c Client) createGeminiResponse(ctx context.Context, prompt string, hooks StreamHooks) (ShellHelperResponse, error) {
	payload, err := c.geminiPayload(prompt)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	stream := hooks.OnDelta != nil
	method := "generateContent"
	if stream {
		method = "streamGenerateContent?alt=sse"
	}
	endpoint := strings.TrimRight(c.Profile.BaseURL, "/") + "/models/" + c.Profile.Model + ":" + method + "&key=" + c.Profile.APIKey
	ctx, cancel := requestContext(ctx, c.Config.TimeoutSeconds)
	defer cancel()
	resp, err := c.doRequest(ctx, endpoint, body, map[string]string{
		"Content-Type": "application/json",
	}, stream)
	if err != nil {
		return ShellHelperResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		b, _ := io.ReadAll(resp.Body)
		return ShellHelperResponse{}, fmt.Errorf("request failed (%d): %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if stream {
		return parseGeminiStream(resp.Body, hooks)
	}
	return parseGeminiResponse(resp.Body)
}

func requestContext(parent context.Context, timeoutSeconds int) (context.Context, func()) {
	timeout := time.Duration(timeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = time.Duration(defaultTimeoutSeconds) * time.Second
	}
	return context.WithTimeout(parent, timeout)
}

func (c Client) doRequest(ctx context.Context, endpoint string, body []byte, headers map[string]string, stream bool) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if stream {
		req.Header.Set("Accept", "text/event-stream")
	}
	httpClient := c.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	return httpClient.Do(req)
}

func (c Client) payload(prompt string, stream bool) (map[string]any, error) {
	history, err := c.History.Recent(c.Config.HistoryMaxRecords, c.Config.HistoryTimeWindowMinutes)
	if err != nil {
		return nil, err
	}
	input := []map[string]string{{"role": "developer", "content": c.System}}
	for _, record := range history {
		input = append(input, map[string]string{"role": record.Role, "content": record.Content})
	}
	input = append(input, map[string]string{"role": "user", "content": prompt})
	payload := map[string]any{
		"model": c.Profile.Model,
		"input": input,
		"text": map[string]any{
			"format": responseFormatSchema(),
		},
		"reasoning": map[string]any{
			"effort": "minimal",
		},
	}
	if stream {
		payload["stream"] = true
	}
	return payload, nil
}

func parseOpenAIResponse(r io.Reader) (ShellHelperResponse, error) {
	var raw struct {
		Output []struct {
			Type    string `json:"type"`
			Status  string `json:"status"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
	}
	if err := json.NewDecoder(r).Decode(&raw); err != nil {
		return ShellHelperResponse{}, err
	}
	for _, output := range raw.Output {
		if output.Type != "message" {
			continue
		}
		if output.Status != "" && output.Status != "completed" {
			return ShellHelperResponse{}, fmt.Errorf("OpenAI response failed (%s)", output.Status)
		}
		for _, content := range output.Content {
			if content.Type == "output_text" {
				return parseHelperJSON(content.Text)
			}
		}
	}
	return ShellHelperResponse{}, errors.New("OpenAI response did not contain output_text")
}

func parseOpenAIStream(r io.Reader, hooks StreamHooks) (ShellHelperResponse, error) {
	var full strings.Builder
	streamer := newFieldStreamer(hooks.OnDelta)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			return ShellHelperResponse{}, err
		}
		eventType, _ := event["type"].(string)
		if eventType == "error" {
			return ShellHelperResponse{}, fmt.Errorf("OpenAI stream error: %v", event["error"])
		}
		if eventType != "response.output_text.delta" {
			continue
		}
		delta, _ := event["delta"].(string)
		if delta == "" {
			continue
		}
		full.WriteString(delta)
		streamer.Feed(delta)
	}
	if err := scanner.Err(); err != nil {
		return ShellHelperResponse{}, err
	}
	return parseHelperJSON(full.String())
}

func parseHelperJSON(s string) (ShellHelperResponse, error) {
	var out ShellHelperResponse
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return ShellHelperResponse{}, fmt.Errorf("invalid structured response: %w", err)
	}
	return out, nil
}

func responseFormatSchema() map[string]any {
	// Schema fields ordered explicitly for streaming: explanation before command.
	// Go maps alphabetize keys, so we build the "properties" object as raw JSON.
	props := `{` +
		`"shell_command_requested":{"type":"boolean","description":"Whether the user requested to run shell command, or the user request needed shell command to fulfill."},` +
		`"shell_command_explanation":{"type":"string","description":"A brief plain-text explanation of the shell command."},` +
		`"shell_command":{"type":"string","description":"The shell command to accomplish the task, if applicable."},` +
		`"chat_response":{"type":"string","description":"A clear and helpful general answer to the user request."}` +
		`}`

	schema := map[string]any{
		"type": "json_schema",
		"name": "shell_helper",
		"schema": map[string]any{
			"type":                 "object",
			"properties":           json.RawMessage(props),
			"required":             []string{"shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"},
			"additionalProperties": false,
		},
		"strict": true,
	}
	return schema
}

// --- DeepSeek ---

func (c Client) deepseekPayload(prompt string, stream bool) (map[string]any, error) {
	history, err := c.History.Recent(c.Config.HistoryMaxRecords, c.Config.HistoryTimeWindowMinutes)
	if err != nil {
		return nil, err
	}
	messages := []map[string]string{{"role": "system", "content": c.System}}
	for _, record := range history {
		messages = append(messages, map[string]string{"role": record.Role, "content": record.Content})
	}
	messages = append(messages, map[string]string{"role": "user", "content": prompt})

	return map[string]any{
		"model":    c.Profile.Model,
		"messages": messages,
		"tools": []map[string]any{{
			"type": "function",
			"function": map[string]any{
				"name":        "respond",
				"strict":      true,
				"description": "Respond to the user with either a shell command or a chat answer",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"shell_command_requested":   map[string]any{"type": "boolean", "description": "Whether the user requested to run a shell command"},
						"shell_command_explanation": map[string]any{"type": "string", "description": "Brief plain-text explanation of the shell command"},
						"shell_command":             map[string]any{"type": "string", "description": "The shell command to accomplish the task"},
						"chat_response":             map[string]any{"type": "string", "description": "A clear and helpful general answer"},
					},
					"required":             []string{"shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"},
					"additionalProperties": false,
				},
			},
		}},
		"tool_choice": map[string]any{"type": "function", "function": map[string]any{"name": "respond"}},
		"stream":      stream,
		"max_tokens":  4096,
		"thinking":    map[string]any{"type": "disabled"},
	}, nil
}

func parseDeepSeekResponse(r io.Reader) (ShellHelperResponse, error) {
	var raw struct {
		Choices []struct {
			Message struct {
				ToolCalls []struct {
					Function struct {
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(r).Decode(&raw); err != nil {
		return ShellHelperResponse{}, err
	}
	if len(raw.Choices) == 0 || len(raw.Choices[0].Message.ToolCalls) == 0 {
		return ShellHelperResponse{}, errors.New("DeepSeek failed to produce a tool call")
	}
	return parseHelperJSON(raw.Choices[0].Message.ToolCalls[0].Function.Arguments)
}

func parseDeepSeekStream(r io.Reader, hooks StreamHooks) (ShellHelperResponse, error) {
	var full strings.Builder
	streamer := newFieldStreamer(hooks.OnDelta)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			continue
		}
		var event struct {
			Choices []struct {
				Delta struct {
					ToolCalls []struct {
						Function struct {
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			continue
		}
		if len(event.Choices) == 0 {
			continue
		}
		toolCalls := event.Choices[0].Delta.ToolCalls
		if len(toolCalls) == 0 {
			continue
		}
		delta := toolCalls[0].Function.Arguments
		if delta == "" {
			continue
		}
		full.WriteString(delta)
		streamer.Feed(delta)
	}
	if err := scanner.Err(); err != nil {
		return ShellHelperResponse{}, err
	}
	return parseHelperJSON(full.String())
}

// --- Gemini ---

func (c Client) geminiPayload(prompt string) (map[string]any, error) {
	history, err := c.History.Recent(c.Config.HistoryMaxRecords, c.Config.HistoryTimeWindowMinutes)
	if err != nil {
		return nil, err
	}
	contents := make([]map[string]any, 0, len(history)+1)
	for _, record := range history {
		role := record.Role
		if role == "assistant" {
			role = "model"
		}
		contents = append(contents, map[string]any{
			"role":  role,
			"parts": []map[string]any{{"text": record.Content}},
		})
	}
	contents = append(contents, map[string]any{
		"role":  "user",
		"parts": []map[string]any{{"text": prompt}},
	})

	return map[string]any{
		"system_instruction": map[string]any{
			"parts": []map[string]any{{"text": c.System}},
		},
		"contents": contents,
		"generationConfig": map[string]any{
			"responseMimeType": "application/json",
			"responseSchema": map[string]any{
				"type": "OBJECT",
				"properties": map[string]any{
					"shell_command_requested":   map[string]any{"type": "BOOLEAN", "description": "Whether the user requested to run shell command, or the user request needed shell command to fulfill."},
					"shell_command_explanation": map[string]any{"type": "STRING", "description": "A brief plain-text explanation of the shell command."},
					"shell_command":             map[string]any{"type": "STRING", "description": "The shell command to accomplish the task, if applicable."},
					"chat_response":             map[string]any{"type": "STRING", "description": "A clear and helpful general answer to the user request."},
				},
				"required": []string{"shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"},
			},
		},
	}, nil
}

func parseGeminiResponse(r io.Reader) (ShellHelperResponse, error) {
	var raw struct {
		Candidates []struct {
			FinishReason string `json:"finishReason"`
			Content      struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if err := json.NewDecoder(r).Decode(&raw); err != nil {
		return ShellHelperResponse{}, err
	}
	if len(raw.Candidates) == 0 || len(raw.Candidates[0].Content.Parts) == 0 {
		return ShellHelperResponse{}, errors.New("Gemini response did not contain content")
	}
	status := raw.Candidates[0].FinishReason
	if status != "" && status != "STOP" {
		return ShellHelperResponse{}, fmt.Errorf("Gemini response failed (%s)", status)
	}
	return parseHelperJSON(raw.Candidates[0].Content.Parts[0].Text)
}

func parseGeminiStream(r io.Reader, hooks StreamHooks) (ShellHelperResponse, error) {
	var full strings.Builder
	streamer := newFieldStreamer(hooks.OnDelta)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			continue
		}
		var event struct {
			Candidates []struct {
				Content struct {
					Parts []struct {
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"content"`
			} `json:"candidates"`
		}
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			continue
		}
		if len(event.Candidates) == 0 || len(event.Candidates[0].Content.Parts) == 0 {
			continue
		}
		delta := event.Candidates[0].Content.Parts[0].Text
		if delta == "" {
			continue
		}
		full.WriteString(delta)
		streamer.Feed(delta)
	}
	if err := scanner.Err(); err != nil {
		return ShellHelperResponse{}, err
	}
	return parseHelperJSON(full.String())
}
