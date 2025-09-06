## pls – Lightweight Command-Line AI Helper

**Stop switching contexts.** Many AI CLI tools are heavy, Node.js-based, and trap you in their interface. They might go back and forth just to run a simple `ls`, cutting off real access to your command line.  

`pls` is different: **lightweight, fast, and built for everyday CLI tasks**, keeping you fully in the command line while letting you **seamlessly switch between AI and shell commands**.  

## Key Capabilities
- Generate **chat messages and shell commands in a single request**, it never “thinks twice.”  
- Switch effortlessly between **interactive mode** and **command mode** with shared memory.  
- Keep a **short-term history**, allowing you to pick up anytime without session management.  
- Run as a **single Bash script**, with no extra tools or MCP needed, consumes very few tokens.  
- *(Experimental)* Configure via chat: `update yourself`, `edit config`, `delete chat history`.  

## Features
- AI **chat and shell command generation**  
- Inline **command regeneration and editing**  
- Supports **pipes and command chaining**  
- Works on **Linux and macOS**  
- Compatible with **OpenAI API** and **Gemini API**  

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
- Linux or macOS, need an Openai or Gemini API key
- install jq if not installed already
- install glow (optional for Markdown color rendering)
- run the follow script to install or update
```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```
- to uninstall
```bash
sudo rm /usr/local/bin/pls # remove the bin
rm -rf ~/.pls # remove config file and chat history
```
