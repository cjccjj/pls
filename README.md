## pls - cli AI helper
- a command-line helper that talks to AI, and generate shell commands that await your confirm to run
- support both Openai and Gemini
- structured output to ensure you can chat and get clean shell commands at the same time 
- maintains a short term conversation history
- support input from pipes, and command chaining
- allow inline shell command regeneration and editing
- polite, minimal, and easy to use
- (experimental) change local config by talking, e.g. "edit config", "delete all chat history"

## Usage
```
pls v0.5

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
          nano ~/.config/pls/pls.conf             # Choose AI model and change settings
```

## Examples to try
ask anything 

<img width="643" height="327" alt="image" src="https://github.com/user-attachments/assets/77837a07-dcef-4dab-ab96-437463234b35" />

generate a shell command and run it  
request regeneration, or manually edit

<img width="646" height="731" alt="image" src="https://github.com/user-attachments/assets/6524a0c3-5774-448f-9f19-99a367fcf8cb" />


## Installation
- install jq if not installed already
- install glow (optional for Markdown color rendering)
- run the follow script to install or update
```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```
- to uninstall
```bash
sudo rm /usr/local/bin/pls # remove the bin
rm -rf ~/.config/pls # remove config file and chat history
```
