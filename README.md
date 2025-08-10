## pls - please AI helper
- A command-line helper that talks, and generate shell commands that await your confirm to run 
- supports piped input, command chaining, and maintains a short term conversation history
- polite and very easy to use 

## Usage
```
pls v0.3
Usage:    pls [-t] [messages...]                  # Chat and generate shell commands if requested
Examples:        
          pls how to cook rice                    # Chat
          pls show system time                    # Generate shell commands and wait for confirmation
          pls delete all files from root          # Dangerous command will not run
          echo how to cook rice | pls             # Use pipe input
          echo rice | pls how to cook             # Args + pipe (task from args, data from pipe)
          echo rice | pls -t how to cook          # ... to show pipe input
          pls name a dish | pls how to cook       # Chain commands (-t not needed)  
          pls -h                                  # Show this help
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
