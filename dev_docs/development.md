# pls — Developer Reference

## Overview

`pls` is an interactive AI CLI tool that switches between chat and shell commands. This is the Go port — a single static binary using OpenAI, DeepSeek, and Gemini APIs with streaming output and native Markdown rendering.

| | |
|---|---|
| Repo | `github.com/cjccjj/pls` |
| Module | `github.com/cjccjj/pls` |
| Go version | 1.25 |
| Binary size | ~6.1 MB stripped, ~2.0 MB UPX-compressed |
| Dependencies | `readline` (pre-filled line editing), `mdflow` (Markdown-to-ANSI, pure stdlib) |
| Tests | 22 passing in `internal/pls/` |
| Version | Set at build via ldflags (`v0.1.0` on tagged releases, `dev` otherwise) |

## Quick Start

```bash
git clone git@github.com:cjccjj/pls.git
cd pls

make build          # build binary (stripped, static, version injected)
make test           # run all tests
make release        # cross-compile linux/amd64 + arm64 to dist/
make release-upx    # same + UPX compress
```

## Project Layout

```
pls/
├── cmd/pls/main.go              # Entry point: NewApp().Run()
├── internal/pls/
│   ├── app.go                   # App struct, Run(), interactive loop, streaming
│   ├── app_test.go              # parseArgs unit tests
│   ├── app_integration_test.go  # Fake OpenAI server integration tests (SSE, pipe+args)
│   ├── config.go                # LoadConfig, ActiveProfile, INI parser, default profiles
│   ├── config_test.go           # Config loading + inline comment tests
│   ├── history.go               # HistoryStore: JSONL append + time-window/max-record filter
│   ├── history_test.go          # History write + filter tests
│   ├── llm.go                   # Client, provider dispatch, payload/parse for all 3 providers
│   ├── openai_test.go           # Payload, parse, stream tests for all 3 providers (fake SSE)
│   ├── prompt.go                # BuildSystemInstruction, BuildPrompt, sanitizeInput
│   ├── prompt_test.go           # Prompt + system instruction tests
│   ├── stream_json.go           # fieldStreamer: partial-JSON progressive streaming
│   ├── tui.go                   # ANSI colors, spinner, formatMenu()
│   └── types.go                 # Config, Profile, ShellHelperResponse, HistoryRecord, PromptInput
├── go.mod / go.sum
├── Makefile                     # build, test, release, release-upx targets
├── install.sh                   # Downloads latest release binary → /usr/local/bin
├── README.md
├── LICENSE (MIT)
├── .gitignore
└── .github/workflows/
    └── release.yaml             # Builds linux/amd64 + arm64 on tag push, UPX compresses, creates release
```

Legacy bash version lives locally in `archive/bash/` (gitignored).

## Build & Release

### Makefile targets

| Target | What it does |
|--------|--------------|
| `make build` | `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X ...Version=..." -o pls ./cmd/pls` |
| `make build-upx` | build + `upx --best --lzma pls` (requires UPX installed) |
| `make test` | `go test ./...` |
| `make release` | Cross-compile linux/amd64 + arm64 to `dist/` |
| `make release-upx` | release + UPX compress both binaries |

### Version injection

`types.go` declares `var Version = "dev"`. At build time, ldflags injects the version:

```
-ldflags="-X 'github.com/cjccjj/pls/internal/pls.Version=${VERSION}'"
```

- Dev builds: `5fc20ba-dirty` (git describe)
- Tagged releases: `v0.1.0` (tag name via GitHub Actions)

### GitHub Actions Release Workflow

File: `.github/workflows/release.yaml`

Triggers on `v*` tag push. Two jobs:

1. **build** (matrix: amd64, arm64) — checkouts, sets up Go 1.25, installs UPX via apt, builds with `-trimpath -s -w`, UPX compresses, generates SHA256
2. **release** — collects artifacts, creates GitHub release via `softprops/action-gh-release`

Result: `pls-linux-amd64` (~2.0 MB) and `pls-linux-arm64` (~1.7 MB) with `.sha256` files.

### install.sh

Downloads `pls-$(uname -s)-$(uname -m)` from `https://github.com/cjccjj/pls/releases/latest/download/` and copies to `/usr/local/bin/pls`. Uses sudo if needed. Linux-only currently.

---

## All Providers

### OpenAI
- Endpoint: `{base}/v1/responses`
- Method: structured JSON via `json_schema` format
- Streaming: SSE `response.output_text.delta` events, filters out reasoning events
- Reasoning: `{effort: "minimal"}` (can't disable fully, model is gpt-5-mini)
- History: `{role, content}` (user/assistant)

### DeepSeek
- Endpoint: `{base}/chat/completions` (beta endpoint)
- Method: strict tool calling (`respond` function, `tool_choice` forced)
- Streaming: SSE `choices[0].delta.tool_calls[0].function.arguments` chunks
- Thinking: `{type: "disabled"}`
- History: `{role, content}` (same as OpenAI)
- Note: model may emit `chat_response` before `shell_command_requested`; streamer handles this eagerly

### Gemini
- Endpoint non-streaming: `{base}/models/{model}:generateContent?key={key}`
- Endpoint streaming: `{base}/models/{model}:streamGenerateContent?alt=sse&key={key}`
- Method: `responseMimeType: "application/json"` with `responseSchema`
- Streaming: SSE chunks return incremental `candidates[0].content.parts[0].text` (deltas, NOT full accumulated)
- History: role `assistant` → `model`, content in `parts: [{text: ...}]`
- Validates `finishReason == "STOP"`

### Provider dispatch
`Client.CreateResponse()` switches on `Profile.Provider`:
- `"openai"` → `createOpenAIResponse(ctx, prompt, hooks)`
- `"deepseek"` → `createDeepSeekResponse(ctx, prompt, hooks)`
- `"gemini"` → `createGeminiResponse(ctx, prompt, hooks)`

Each provider method checks `hooks.OnDelta != nil` to decide streaming vs non-streaming path.
Shared `doRequest()` handles HTTP; `requestContext()` wraps timeout.

---

## Streaming Architecture (`stream_json.go`)

The `fieldStreamer` receives raw JSON text deltas and progressively extracts field values:

1. Detect mode from partial JSON: `shellRequestedMode(raw)` looks for `"shell_command_requested": true/false`
2. Chat mode (`shellFalse`): extracts and streams `chat_response` field
3. Shell mode (`shellTrue`): streams `shell_command_explanation` first (with `# ` prefix in app callback), then `shell_command`
4. Unknown mode: eagerly drains `chat_response` (handles DeepSeek field reordering)

`partialJSONStringField()` finds a named field in partial JSON, extracts its string value with escape handling, returns `(value, complete, ok)`.

---

## TUI (`tui.go` + `app.go` interactive loop)

- ANSI colors: green `>`, grey info, cyan shortcuts, yellow commands — defined in `tui.go`
- Spinner: goroutine writes animated frames + model name to stderr; `startSpinner(w, model)` returns `stop()`
- Menu: `formatMenu(items)` renders `( r ⏎ : run cmd | ... )` with colors
- Command edit: `editShellCommand()` uses `github.com/chzyer/readline` with `WriteStdin` to pre-fill
- Shell command run: `runShellCommand()` executes via user's SHELL, appends to `~/.bash_history`

### Interactive flow (`app.go` `interactive()`)
1. If initial prompt, call `createResponseStreaming()` — starts spinner, streams response
2. Loop: normalize action → show output/menu → prompt `> ` → read input → dispatch
3. Actions: `cmd_new_response`, `chat_new_response`, `cmd_edited`, `cmd_executed`
4. Input dispatch: `""`/`q` quit, `r` run command, `e` edit command, else new API call
5. `createResponseStreaming()` returns `(resp, streamed, error)` — streamed flag skips re-display

### Streaming output formatting (in app callback, `app.go:218-255`)
- `shell_command_explanation` (TTY): `# content` in grey, `# ` prefix on first chunk only
- `shell_command` (TTY): `# Command:\n` header (once) then content in yellow
- `shell_command_explanation` (pipe): skipped entirely
- `shell_command` (pipe): raw text only, no header
- `chat_response` (TTY): fed through mdflow renderer for ANSI-formatted markdown
- `chat_response` (pipe): raw text via `fmt.Fprint`
- Spinner: TTY-only, stops on first delta. No initial newline in pipe mode (no spinner to clear).
- `cmd_new_response`/`chat_new_response` skip re-display when streamed (already shown)

---

## Config (`config.go`)

INI-style `~/.pls/pls.conf`. Default profiles:
- `openai_1` (gpt-5-mini), `openai_2` (gpt-5.4)
- `deepseek_1` (deepseek-v4-flash)
- `gemini_1` (gemini-3-flash-preview)

Global settings: `profile`, `timeout_seconds` (60), `max_input_length` (64000), `history_file`, `history_time_window_minutes` (30), `history_max_records` (30), `USER_SYSTEM_INSTRUCTION`.
`ensureProfiles()` merges missing profiles into existing config. `$HOME` and `~/` expanded in paths.

---

## History (`history.go`)

JSONL format at `history_file` path. Each record: `{timestamp, role, content}`.
`Add(userMsg, assistantMsg)` appends two lines. `Recent(maxRecords, windowMinutes)` tails the file, filters by time window, returns up to max records. Lines over 4 MB handled via scanner buffer.

---

## Prompt (`prompt.go`)

`BuildSystemInstruction(cfg, userName, shellName)` substitutes user env, history path, custom instructions into the base system prompt. Special cases: delete history, edit config, update yourself.

`BuildPrompt(PromptInput)` combines arg and piped input: `Given the data: "X", perform the task: "Y"`. Sanitizes control chars, truncates at max length.

---

## Markdown

`createResponseStreaming()` (`app.go:208`) handles all four streaming modes via a single `useTTY` branch:

| Mode | `chat_response` | `shell_command` |
|------|-----------------|-----------------|
| Interactive (TTY) | mdflow ANSI render | grey explanation + yellow command |
| Pipe (non-TTY) | raw text | raw command only (no header/explanation) |

- **TTY**: `markdown.NewRenderer(a.out)` created once before streaming; `chat_response` deltas fed via `Write()`; `Close()` flushes parser state after API call.
- **Pipe**: raw `fmt.Fprint` — no mdflow, no ANSI colors, no spinner. `shell_command_explanation` delta is skipped entirely (only the raw command matters for pipe consumers).
- Non-streamed fallback: `renderMarkdown()` uses mdflow instead of external `glow` (`app.go:335-343`).
- mdflow supports: `#`/`##`/`###` headers, `**bold**`, `*italic*`, `~~strikethrough~~`, `` `inline code` ``, fenced code blocks, `-`/`*` bullets, `---` horizontal rules, code block language labels.
- Provider-agnostic: all three providers converge into the same `fieldStreamer` → `OnDelta` callback → single mdflow integration point.

---

## Open Items

### macOS terminal support (resolved)
`chzyer/readline` has `term_bsd.go` for macOS/BSD terminal ioctl. The Go binary cross-compiles for darwin/arm64 (Apple Silicon) and is included in releases. The `isTerminalFile` check and `/dev/tty` fallback are POSIX-compliant. If readline fails to initialize, `editShellCommand` silently returns the current command as a safe fallback.

### Config `base_url` edge case for DeepSeek
DeepSeek config has `base_url="https://api.deepseek.com/beta"`. The endpoint is built as `baseURL + "/chat/completions"` → `https://api.deepseek.com/beta/chat/completions`. Verify behavior when user sets a custom base_url.

### Error handling improvements
- Network errors: currently returns error string; could add retry for transient failures
- API errors: status code + body dumped; could parse error JSON for clearer messages
- Invalid JSON from providers: `invalid structured response` error; could add fallback parsing

### Code organization
`llm.go` (~505 lines) contains all 3 providers. Consider splitting into `llm.go`, `deepseek.go`, `gemini.go` for maintainability.

### Test coverage gaps
- No integration tests for DeepSeek/Gemini fake servers (only OpenAI has `app_integration_test.go`)
- No test for the interactive loop TUI flow (hard to test programmatically)
