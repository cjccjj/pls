# pls: AI CLI Helper (Go)

**Stop switching contexts.** `pls` is a lightweight AI CLI tool that seamlessly switches between chat and shell commands. Type what you want, get answers or shell commands, edit them, and run them — all inline.

## Install

```bash
go install github.com/cjccjj/pls/cmd/pls@latest
```

Requires Go 1.25+. Works on Linux and macOS.

Then export your API key for one of the supported providers:

```bash
export OPENAI_API_KEY="sk-..."      # OpenAI
export GEMINI_API_KEY="..."         # Google Gemini
export DEEPSEEK_API_KEY="sk-..."    # DeepSeek
```

Optional: install [`glow`](https://github.com/charmbracelet/glow) for prettier markdown output.

## Usage

```
pls v0.1.0

Usage:    pls [messages...]                # Chat with an input
          > what is llm                    # Continue chat, q or empty input to quit

Examples: pls                              # Start without input
          pls count files                  # Shell command, wait for run
          > include subdirs                # Update command

Pipe and Chain:
          echo how to cook rice | pls      # Input from pipe
          echo rice | pls how to cook      # Args + pipe (task from args, data from pipe)
          pls name a dish | pls -p         # Chain with -p to show piped input
```

In interactive mode, after each response you can:

| Key | Action |
|-----|--------|
| `r` | Run the suggested shell command |
| `e` | Edit the command before running |
| `q` or empty | Quit |
| anything else | Continue the chat |

## Config

Config lives at `~/.pls/pls.conf`. To switch providers, change the `profile` field:

```ini
[Global]
profile="openai_1"

[openai_1]
provider="openai"
model="gpt-5-mini"
base_url="https://api.openai.com/v1"
env_key="OPENAI_API_KEY"

[gemini_1]
provider="gemini"
model="gemini-3-flash-preview"
base_url="https://generativelanguage.googleapis.com/v1beta"
env_key="GEMINI_API_KEY"

[deepseek_1]
provider="deepseek"
model="deepseek-v4-flash"
base_url="https://api.deepseek.com/beta"
env_key="DEEPSEEK_API_KEY"
```

You can also type `edit config` in pls chat to modify settings.

## Features

- AI chat and shell command generation in a single request
- Streaming responses with real-time markdown rendering
- Inline command editing and execution (appends to shell history)
- Pipes and command chaining, clean output in piped mode
- Short-term conversation history (JSONL, no session management)
- Supports OpenAI, Gemini, and DeepSeek APIs

## Tips

- Pipe any command output into `pls` for analysis: `my_app --help | pls learn it`
- Chain commands: `pls generate demo data | python my_render.py`
- For short context, let AI do it directly; for large datasets, ask AI to generate scripts
- Quit and restart anytime — your recent conversation is preserved automatically

## Build from Source

```bash
git clone https://github.com/cjccjj/pls.git
cd pls
go build -ldflags="-s -w" -o pls ./cmd/pls
```

## Legacy Bash Version

The original Bash version (v0.56) is available for download:

```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/$(git ls-remote https://github.com/cjccjj/pls.git main | awk '{print $1}')/pls.sh
```

Or browse the [git history](https://github.com/cjccjj/pls) for the last Bash release. Note: the Bash version requires `curl` and `jq`.

## License

MIT
