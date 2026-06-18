# pls: AI CLI Helper

**Stop switching contexts.** `pls` is a lightweight AI CLI tool that seamlessly switches between chat and shell commands. Type what you want, get answers or shell commands, edit them, and run them — all inline.

This Go version adds **streaming output** with **native Markdown rendering**, real-time as the response arrives. No external renderer needed — it's fast, single-binary, and dependency-free.

> **Note:** The original single-file [Bash version (v0.56)](https://github.com/cjccjj/pls/blob/e32e8a3/pls.sh) is still available. It requires `curl` and `jq`.

## Install

**Option 1: Install script (Linux / macOS)**

```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```

Downloads the latest binary to `/usr/local/bin/pls`. Supports linux (amd64, arm64) and macOS (arm64 Apple Silicon).

**Option 2: Download binary**

Pick your platform from the [releases page](https://github.com/cjccjj/pls/releases), then:

```bash
# Linux
chmod +x pls-linux-amd64
sudo cp pls-linux-amd64 /usr/local/bin/pls

# macOS
chmod +x pls-darwin-arm64
xattr -dr com.apple.quarantine pls-darwin-arm64   # macOS may quarantine the download
sudo cp pls-darwin-arm64 /usr/local/bin/pls
```

**Option 3: Go install**

```bash
go install github.com/cjccjj/pls/cmd/pls@latest
```

Requires Go 1.25+.

## Usage

```
pls

Usage:    pls [messages...]                # Chat with an input
          > what is llm                    # Continue chat, q or empty input to quit

Examples: pls                              # Start without input
          pls count files                  # Shell command, wait for run
          > include subdirs                # Update command

Pipe and Chain:
          echo how to cook rice | pls      # Input from pipe
          echo rice | pls how to cook      # Args + pipe (task from args, data from pipe)
          pls name a dish | pls -p         # Chain with -p to show piped input

Settings: pls -h                           # Show this help
          pls edit config                  # Change provider/model via chat
```

In interactive mode, after each response you can:

| Key | Action |
|-----|--------|
| `r` | Run the suggested shell command |
| `e` | Edit the command before running |
| `q` or empty | Quit |
| anything else | Continue the chat |

Every shell command comes with an **explanation** (in grey) so you know what it does before you run it. The command **never auto-executes** — you must explicitly press `r` to run, or `e` to edit first.

## Features

- AI chat and shell command generation in a single request
- **Streaming output** with native Markdown rendering — no glow needed
- Every command includes an **explanation**, only runs when you hit `r`
- **Dangerous commands** (delete data, kill services, etc.) are **commented out** with `#` — they show but will not run
- Inline command editing and execution (appends to shell history)
- Pipes and command chaining, clean output in piped mode
- Short-term conversation history (JSONL, no session management)
- Supports OpenAI, Gemini, and DeepSeek APIs

## Config

Config lives at `~/.pls/pls.conf`. Set your API keys and choose a provider:

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

Export your API key for the provider you use:

```bash
export OPENAI_API_KEY="sk-..."      # OpenAI
export GEMINI_API_KEY="..."         # Google Gemini
export DEEPSEEK_API_KEY="sk-..."    # DeepSeek
```

### Managing profiles and settings in chat

You can manage profiles, config, and the app itself by just saying what you want in chat:

For example, say like `list profiles`, `switch model`, `switch to openai_1`, `edit config`, `update yourself` to config the session or the tool. 

## Tips

- Pipe any command output into `pls` for analysis: `my_app --help | pls learn it`
- Chain commands: `pls generate demo data | python my_render.py`
- For short context, let AI do it directly; for large datasets, ask AI to generate scripts
- Quit and restart anytime — your recent conversation is preserved automatically

## Build from Source

```bash
git clone https://github.com/cjccjj/pls.git
cd pls
make build
```

## License

MIT
