# pls: Lightweight AI CLI Tool

**Stop switching contexts.** Many AI CLI tools are heavy, Node.js-based, and trap you in their interface. They might go back and forth just to run a simple `ls`, cutting off real access to your command line.  

`pls` is different: **lightweight, fast, and built for everyday CLI tasks**, keeping you fully in the command line while letting you **seamlessly switch between AI and shell commands**.  

## Examples of seamlessly switching between AI and shell commands 

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

## Tips for using `pls`

- Use `cat`, `tail`, or any command **pipe** to feed input into `pls`.  
- Give orders in **chat mode**, where you can refine your request as many times as needed until satisfied.  
- Quit chat mode at any time to run any command you want, and simply pick it up again anywhere, anytime, by typing `pls`.  
- Use AI for its **flexibility** to handle anything; for simple shell commands, run them yourself for **efficiency and safety**.  
- For short context, just let AI do it directly; for large datasets, ask AI to **generate commands or scripts** to help you.  
- If not satisfied with anything, simply provide your feedback.
- You can apply the workflow to command-line tasks like system administration, config file tweaking, log analysis, and script writing.  
- It will make your command-line work easier and more fun, while still keeping the traditional command-line style and feel.
  
## Key Capabilities

- Generate **chat messages and shell commands in a single request**, it never “thinks twice.”  
- Switch effortlessly between **interactive mode** and **command mode** with shared memory.  
- Keep a **short-term history**, allowing you to pick up anytime without session management.  
- Run as a **single Bash script**, with no extra tools or MCP needed, consumes very few tokens.  
- *(Experimental)* Configure via chat: `update yourself`, `edit config`, `delete chat history`.  

## Features

- AI chat and shell command generation
- Inline command regeneration and editing  
- Supports pipes and command chaining, clean output in piped mode  
- Works on Linux and macOS  
- Compatible with OpenAI API and Gemini API

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

## Installation

- install `jq` if not installed already
- run the follow script to install or update
```bash
curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash
```
- Export `OPENAI_API_KEY` or `GEMINI_API_KEY` in your shell config
- Optional: install `glow` for prettier markdown output in chat
- to edit config run `pls edit config`
- to update run `pls update yourself`
- to uninstall run
```bash
sudo rm /usr/local/bin/pls # remove the bin
rm -rf ~/.pls # remove config file and chat history
```
