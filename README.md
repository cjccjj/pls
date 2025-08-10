## pls - please AI helper
- A command-line helper that talks to OpenAI API, and generate shell commands that await your confirm to run 
- support input from pipe, from both and command chaining
- support a short term conversation history
- support inline shell command edit
- polite and very easy to use 

## Usage
```
pls v0.3
Usage:    pls [-t] [messages...]                  # Chat and generate shell commands if requested
Examples:        
          pls how to cook rice                    # Chat
          pls show total files                    # "find . -type f | wc -l" command show up and wait for run
          pls delete all files from root          # "# rm -rf /*" dangerous command show up as comment
          
          echo how to cook rice | pls             # Use pipe input
          echo rice | pls how to cook             # Args + pipe (task from args, data from pipe)
          echo rice | pls -t how to cook          # ... to show pipe input
          pls name a dish | pls how to cook       # Chain commands

          pls -h                                  # Show this help
          ~/.config/pls/pls.conf                  # Edit this file to change settings
```

## Examples

## Installation
- install curl and jq if not installed already
- install glow (optional for Markdown render)
- set OPENAI_API_KEY in env 
- install pls
```
chmod +x ./pls
sudo cp ./pls /usr/local/bin/pls
```
