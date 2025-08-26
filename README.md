## pls - cli AI helper
- A command-line helper that talks to AI and generates shell commands, which await your confirmation before running.
- pls is not a coding tool, but a quick and convenient helper you can use anytime without leaving the command line.

## To stay quick and responsive, pls:
- Avoids back-and-forth: generates both the chat message and clean shell commands in a single request.
- Maintains short-term conversation history, no need to manage sessions.
- Uses a short system instruction, customizable by the user, with no tool calling.
- Supports inline shell command regeneration and editing.
- Accepts input from pipes and allows command chaining.
- Is polite, minimal, and easy to use.
- (Experimental) Can be configured by conversation, e.g. “update yourself,” “edit config,” “delete chat history.”
- Supports both the OpenAI API and Gemini API.

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
