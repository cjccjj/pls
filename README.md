# pls: Lightweight AI CLI Tool

**Stop switching contexts.** `pls` is a single Bash script — lightweight, fast, and built for everyday CLI tasks. Seamlessly switch between AI chat and shell commands.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```

Requires `curl` and `jq`. Works on Linux and macOS.

Then export your API key for one of the supported providers:

```bash
export OPENAI_API_KEY="sk-..."      # OpenAI (GPT)
export GEMINI_API_KEY="..."         # Google Gemini
export DEEPSEEK_API_KEY="sk-..."    # DeepSeek
```

Optional: install [`glow`](https://github.com/charmbracelet/glow) for prettier markdown output.

## Usage

```
pls v0.56

Usage:    pls [messages...]                       # Chat with an input
          > what is llm                           # Continue chat, q or empty input to quit
                                                
Examples: pls                                     # Start without input 
          pls count files                         # ls -1 | wc -l           # shell cmd wait for run
          > include subdirs                       # find . -type f | wc -l  # shell cmd update

Pipe and Chain:          
          echo how to cook rice | pls             # Use input from pipe
          echo rice | pls how to cook             # Args + pipe (task from args, data from pipe)
          pls name a dish | pls -p how to cook    # Chain commands and show piped input with -p

Settings: pls -h                                  # Show this help
          pls edit config                         # config pls and AI model via chat
```

## Config

To switch AI providers, edit `~/.pls/pls.conf` and change the `profile` field (or type `edit config` in pls chat):

```ini
[Global]
profile="deepseek_1"    # change to openai_1, gemini_1, or deepseek_1

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

> **Note:** DeepSeek uses the beta endpoint (`api.deepseek.com/beta`) for reliable structured output via tool calls, avoiding the known JSON mode whitespace bug.

## Key Capabilities

- Generate **chat messages and shell commands in a single request**, it never "thinks twice."
- Switch effortlessly between **interactive mode** and **command mode** with shared memory.
- Keep a **short-term history**, allowing you to pick up anytime without session management.
- Run as a **single Bash script**, with no extra tools or MCP needed, consumes very few tokens.
- *(Experimental)* Configure via chat: `update yourself`, `edit config`, `delete chat history`.

## Features

- AI chat and shell command generation
- Inline command regeneration and editing
- Supports pipes and command chaining, clean output in piped mode
- Works on Linux and macOS
- Supports OpenAI, Gemini, and DeepSeek APIs

## Examples

- You are working on a file, and use `pls` to help process it:

<img width="854" height="298" alt="image" src="https://github.com/user-attachments/assets/33dc3baa-769b-4f66-908c-8e580014e1cf" />

- You `cat` the result, are happy with it, and move on something else
- You logout ... and login back
- Then you `cd` to another working folder where you want to continue the task,
- By simple type `pls`, the AI picks up the task, and through interative chats you provide new input:

<img width="843" height="535" alt="image" src="https://github.com/user-attachments/assets/15136d95-eb85-471a-8230-0677b7ca7e3e" />

- The AI generated shell commands for you to run,
- And you decided to further tweek the commands,
- Finally, the command runs successfully.

## Tips

- Use `cat`, `tail`, or any command **pipe** to feed data into `pls`.
- You can also feed "knowhow" like `my_app --help | pls learn it`
- Or generate data for your app `pls generate some markdown demo | python my_markdown_render.py`
- Give orders in chat mode, refine your request as many times until satisfied.
- Quit chat at any time to run any command you want, and pick it up again anywhere, anytime, by typing `pls`.
- Use AI for its **flexibility** to handle anything; for simple commands, run them yourself for **efficiency**.
- For short context, let AI do it directly; for large datasets, ask AI to generate commands or scripts for you to run.
- If not satisfied with anything, simply provide your feedback.
- You can apply the workflow to tasks like system administration, config file tweaking, log analysis, and script writing and testing.

## Update

```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```

Or say `update yourself` in pls chat. Updates preserve your existing config and automatically append any new provider profiles.

## Uninstall

```bash
sudo rm /usr/local/bin/pls
rm -rf ~/.pls
```
