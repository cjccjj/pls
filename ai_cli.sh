#!/bin/bash

# === Configuration ===
base_url="https://api.openai.com/v1"
model="gpt-4o"
timeout_sec=60
max_input_length=64000
system_instruction_general="Respond only with the direct answer. Output exactly the answer content, in Markdown if helpful. Do not restate the question or add explanations. Exclude supportive phrases like \"The answer is\" or \"I think\" For single terms, phrases, or numbers, output only that exact text. If uncertain, return nothing. Never ask questions or add extra words. Keep responses concise and under 1500 words."
# system_instruction_general="Respond only with the direct answer. Output exactly the answer content with no code blocks, markdown, or formatting. Do not restate the question or add explanations. Exclude supportive phrases like \"The answer is\" or \"I think\" For single terms, phrases, or numbers, output only that exact text. For lists, print each item on a new line. For tables, use plain text with lines and tabs. If uncertain, return nothing. Never ask questions or add extra words. Keep responses concise and under 1000 characters."
system_instruction_bash="You are a Linux command-line assistant; always generate valid Bash commands based on user input, assume Ubuntu if not specified. Output only the command itself with no extra text or formatting, never use \`\`\` or code blocks. Make sure to use \ for long lines, prefer a single command, join multiple commands with ; or &&. Use sudo when appropriate. If not possible or dangerous, respond exactly with \"Command Unknown\"."

# === Color and Spinner Configuration ===
green='\033[32m'
grey='\033[90m'
reset='\033[0m'
spinner_delay=0.2
spinner_frames=( ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷ )
spinner_pid=0

# === Function Definitions ===
sanitize_input() {
  tr -d '\000-\010\013\014\016-\037\177' <<< "$1"
}

start_spinner() {
  (
    tput civis >&2
    echo -ne "\n\n\n\n\n\033[5A" >&2 # move down 5 lines then back up 5 lines
    
    # Print the static part first (with a placeholder for the frame)
    echo -ne "\r_ $model ${grey}($spinner_note)${reset}:" >&2
    
    while :; do 
      for frame in "${spinner_frames[@]}"; do
        # Move cursor to beginning of line and just print the frame character
        echo -ne "\r${green}${frame}${reset}" >&2
        sleep "$spinner_delay"
      done
    done
  ) & 
  spinner_pid=$!
}

stop_spinner() {
  (( spinner_pid )) || return
  kill "$spinner_pid" 2>/dev/null
  wait "$spinner_pid" 2>/dev/null
  spinner_pid=0
  tput cnorm >&2
  tput cr >&2  
  echo -ne "${green}⣿${reset} ${grey}$model ($spinner_note)${reset}:" >&2
  echo "" >&2
}

show_help() {
  cat >&2 << EOF
pls/plss v0.1
Usage:    plss <messages...>                      # Generate shell commands and confirm before running
          pls [-t] [messages...]                  # Chat with AI (input via args, pipe, or both)
Examples:        
          plss show system time                   # Must use args
          pls how to cook rice                    # Use args
          echo how to cook rice | plss            # Use pipe
          echo rich | pls -t how to cook          # Args + pipe (task from args, data from pipe) 
          pls/plss -h                             # Show this help
EOF
  exit ${1:-0}
}

# Print first 100 chars
truncate_string() {
  local input="$1"
  if (( ${#input} > 1000 )); then
    printf "%s" "${grey}${input:0:1000} #display truncated...${reset}"
  else
    printf "%s" "${grey}$input${reset}"
  fi
}
# === Main Script ===
trap 'stop_spinner; exit' INT TERM EXIT

# Process command line arguments
show_pipe_input=false
bash_mode=false
system_instruction="$system_instruction_general"

# Validate and extract option
case "$1" in
  -t) show_pipe_input=true; shift ;;
  -b) bash_mode=true; shift ;;
  -h) show_help ;;
  -?) show_help 1 ;;
esac
# Reject second option like `-b -t`
[[ "$1" =~ ^- ]] && show_help 1
# Read piped input if any
[ ! -t 0 ] && piped_input="$(cat)"

arg_input="$*"
# Logic for -b (must have arg), -t or no flag (arg or pipe, at least one)
if [[ "$bash_mode" == "true" ]]; then 
  [[ -z "$arg_input" ]] && show_help 1
  system_instruction="$system_instruction_bash"
  task="$arg_input"
else
  [[ -z "$arg_input" && -z "$piped_input" ]] && show_help 1
  task="$arg_input"
  input=$(sanitize_input "$piped_input") #could be empty after santitize... 
fi

# Handle input truncation for AI (not for display) if needed
truncated=0
if ((${#input} > max_input_length)); then
  truncated=1
  input="${input:0:max_input_length}"
fi

# Show input if -t flag is used and there is piped input
if $show_pipe_input && [[ -n "$input" ]]; then
  # show_truncated_input "$input"
  echo "in" >&2
  echo -e "$(truncate_string "$input")" >&2
fi

# Check for API key
[[ -z "$OPENAI_API_KEY" ]] && { echo "OPENAI_API_KEY not set" >&2; exit 1; }

# Construct the user prompt
if [[ -n "$task" && -n "$input" ]]; then
  user_prompt="Given the input: \"$input\", perform the task: \"$task\", and output the result only."
elif [[ -n "$input" ]]; then
  user_prompt=$input
else
  user_prompt=$task
fi

# Set spinner note and finalize prompt
total_chars=${#user_prompt}
spinner_note="input $total_chars"
[[ $truncated -eq 1 ]] && spinner_note="$spinner_note truncated"

user_prompt="$user_prompt. Follow all general rules."

# Prepare and send API request
json_payload=$(jq -n \
  --arg model "$model" \
  --arg sys "$system_instruction" \
  --arg prompt "$user_prompt" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $sys},
      {role: "user", content: $prompt}
    ]
  }')

start_spinner
# echo $json_payload
curl_stderr=""
response=$(timeout "$timeout_sec" curl -s -w "\n%{http_code}" "$base_url/chat/completions" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$json_payload" 2> >(curl_stderr=$(cat))
)
stop_spinner

# Process response
http_code=${response##*$'\n'}
http_body=${response%$'\n'*}

if (( http_code != 200 )); then
  echo "Request failed ($http_code):" >&2
  # Print the JSON error body if available, otherwise print the curl error
  if [[ -n "$http_body" ]]; then
    echo "$http_body" >&2
  else
    echo "$curl_stderr" >&2
  fi
  exit 1
fi

# Output result
output=$(jq -r '.choices[0].message.content // ""' <<< "$http_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

if $bash_mode; then
  # In bash mode, display the command and wait for confirmation
  cmd="$output"
  
  # Check if the command is "Command Unknown"
  if [[ "$cmd" == "Command Unknown" ]]; then
    echo -e "${grey}Command Unknown${reset}" >&2
    exit 0
  fi

  if [ -t 1 ]; then # Terminal mode
    echo "$cmd"
  else # Non-terminal mode, redirect output to stderr
    { echo "$cmd" >&2; echo "$cmd"; }
  fi

  echo "$cmd" >> ~/.bash_history # Write to parent's history note .bashrc need to history -r before every prompt
  echo -e "${grey}Press ${reset}Y${grey} to run. Any other key cancels [then use ↑ to edit].${reset}" >&2
  read -n 1 -r response </dev/tty
  echo "" >&2  # Add a newline after the response
  
  if [[ "$response" =~ ^[Yy]$ ]]; then
    eval "$cmd" 1>&2
  else
    echo -e "${grey}Command execution cancelled.${reset}" >&2
    exit 0
  fi
else # Normal mode - just output the result, glow if is termial, copy to stderr if piped
  if [ -t 1 ]; then
    command -v glow >/dev/null 2>&1 && echo "$output" | glow || echo "$output"
  else
    echo -e "$(truncate_string "$output")" >&2
    echo "$output"

  fi

  [[ $truncated -eq 1 ]] && echo -e "${grey}(Truncated input - answer could be wrong or incomplete)${reset}" >&2
fi

trap - INT TERM EXIT
