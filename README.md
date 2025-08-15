## pls - pls cli AI helper
- A command-line helper that talks to OpenAI API, and generate shell commands that await your confirm to run
- structured output ensures AI can chat and generate clean shell commands at same time 
- support a short term conversation history
- support input from pipe, and command chaining
- support inline shell command regeneration and edit
- polite and  easy to use 

## Usage
```
pls v0.4
Usage:    pls [messages...]                       # Chat with an input
          > what is llm                           # Continue chat, q or empty input to quit
                                                
Examples:
          pls                                     # Chat anything
          pls count files                         # ls -1 | wc -l           # shell cmd wait for run
          > include subdirs                       # find . -type f | wc -l  # shell cmd update

Pipe and Chain:          
          echo how to cook rice | pls             # Use pipe input
          echo rice | pls how to cook             # Args + pipe (task from args, data from pipe)
          echo rice | pls -t how to cook          # ... to show pipe input
          pls name a dish | pls how to cook       # Chain commands

Settings:
          pls -h                                  # Show this help
          nano ~/.config/pls/pls.conf             # Choose AI model and change settings
```

## Examples to try
```
pls hi
pls name a chinese dish
pls how to order it in chinese
pls name a chinese dish | pls how to cook it in 10 sec
pls translate to japanese
pls how to get string length in java
pls in javascript
pls show some markdown demo
pls show total files and size
# hit y to run
pls show files
# hit e to edit the command to target another dir, then enter and hit y to run
pls write a shell command game and run
# hit y to run
pls download a cli game and run
# hit y to install a game from apt and run
pls uninstall the game and clean up
# hit y to uninstall the game 
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
