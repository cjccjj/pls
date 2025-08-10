## please - please AI helper
- A command-line helper that talks to OpenAI API, and generate shell commands that await your confirm to run 
- support input from pipe, from both and command chaining
- support a short term conversation history
- support inline shell command edit
- polite and very easy to use 

## Usage
```
please v0.3
Usage:    please [-t] [messages...]                  # Chat and generate shell commands if requested
Examples:        
          please how to cook rice                    # Chat
          please show total files                    # "find . -type f | wc -l" command show up and wait for run
          please delete all files from root          # "# rm -rf /*" dangerous command show up as comment
          
          echo how to cook rice | please             # Use pipe input
          echo rice | please how to cook             # Args + pipe (task from args, data from pipe)
          echo rice | please -t how to cook          # ... to show pipe input
          please name a dish | please how to cook       # Chain commands

          please -h                                  # Show this help
          ~/.config/please/please.conf                  # Edit this file to change settings
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
- install please
```
chmod +x ./please
sudo cp ./please /usr/local/bin/please
```
