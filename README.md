## pls - pls cli AI helper
- A command-line helper that talks to OpenAI API, and generate shell commands that await your confirm to run
- structured output ensures AI can chat and generate clean shell commands at same time 
- support input from pipe, from both and command chaining
- support a short term conversation history
- support inline shell command edit
- polite and very easy to use 

## Usage
```
pls v0.4
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
- install curl and jq if not installed already
- install glow (optional for Markdown render)
- set OPENAI_API_KEY in env 
- install pls
```
chmod +x ./pls
sudo cp ./pls /usr/local/bin/pls
```
