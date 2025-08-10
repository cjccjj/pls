## pls - please AI helper
- A command-line helper that talks, and generate shell commands that await your confirm to run 
- supports piped input, command chaining, and maintains a short term conversation history
- polite and very easy to use 

## Usage
```
Usage:    pls [-t] [messages...]                  # Chat with AI (input via args, pipe, or both)
          plss <messages...>                      # Generate shell commands and confirm before running
Examples:        
          pls how to cook rice                    # Use args
          echo how to cook rice | pls             # Use pipe
          echo rice | pls how to cook             # Args + pipe (task from args, data from pipe)
          echo rice | pls -t how to cook          # ... to show pipe input
          pls name a dish | pls how to cook       # Chain commands (-t not needed)  
          plss show system time                   # Must use args to generate shell commands
          pls/plss -h                             # Show this help
```

## Examples
<img width="830" height="664" alt="image" src="https://github.com/user-attachments/assets/b5086fe7-7bde-4bf4-b978-2490a314c7d1" />


## Installation
- install curl and jq
- install glow (optional for Markdown render)
- install pls
```
chmod +x ./pls
sudo cp ./pls /usr/local/bin/pls
sudo ln -s ./pls /usr/local/bin/plss
echo "pls installed, run pls or plss"
```
