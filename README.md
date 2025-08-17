## pls - pls cli AI helper
- A command-line helper that talks to OpenAI API, and generate shell commands that await your confirm to run
- structured output ensures AI can chat and generate clean shell commands at same time 
- support a short term conversation history
- support input from pipe, and command chaining
- support inline shell command regeneration and edit
- polite and  easy to use 

## Usage
```
pls v0.51

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
```
pls
> how to get string length in java
> in javascript

pls show total files and size
> y # run and see output
> including sub dirs
> y # run again
> e # edit command 
> y # run again
```
## Installation
- install jq if not installed already
- install glow (optional for Markdown render)
- set OPENAI_API_KEY in env 
- install pls
```
chmod +x ./pls
sudo cp ./pls /usr/local/bin/pls
```
