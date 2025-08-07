#!/bin/bash

# Configuration
# base_url="https://open-bj.nopshop.com/openai/v1"
base_url="https://api.openai.com/v1"
model="gpt-4o"
timeout_seconds=60
max_input_length=64000
system_instruction_general="Respond only with the direct answer. Output exactly the answer content, in Markdown if helpful. Do not restate the question or add explanations. Exclude supportive phrases like \"The answer is\" or \"I think\" For single terms, phrases, or numbers, output only that exact text. Keep responses concise and under 1500 words."
system_instruction_bash="You are a Linux command-line assistant; always generate valid Bash commands based on user input, assume Ubuntu if not specified. Do not say hi or ask questions, output only the command itself with no extra text or formatting, never use \`\`\` or code blocks. Make sure to use \ for long lines, prefer a single command, join multiple commands with ; or &&. Use sudo when appropriate. If not possible or dangerous, respond exactly with \"Shell Command Unknown\"."

# History configuration
history_time_window_minutes=30  # Look back this many minutes
history_max_records=30          # Max records to return if over this number
history_file="/tmp/$USER/pls_history.log"

# Color and spinner configuration
green='\033[32m'
grey='\033[90m'
reset='\033[0m'
spinner_delay=0.2
spinner_frames=( ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷ )
spinner_pid=0
stderr_file="" # For storing curl's stderr file path

# Functions
print_usage_and_exit() {
  cat >&2 << EOF
pls/plss v0.2
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
EOF
  exit ${1:-0}
}
# Central cleanup function
cleanup() {
    # This function is reliably called on any script exit.
    # It ensures the spinner is stopped, cursor is restored, and temp files are removed.
    stop_spinner
    if [[ -n "$stderr_file" ]]; then
        rm -f "$stderr_file"
    fi
}
# Sanitize input
sanitize_input() {
  tr -d '\000-\010\013\014\016-\037\177' <<< "$1"
}

# Show spinner while processing
start_spinner() {
  (
    tput civis >&2
    echo -ne "\n\n\n\n\n\033[5A" >&2  # Move down 5 lines then back up
    # Print static part with placeholder for frame
    echo -ne "\r_ $model ${grey}($spinner_note)${reset}:" >&2
    while :; do 
      for frame in "${spinner_frames[@]}"; do
        # Move cursor to beginning and print frame
        echo -ne "\r${green}${frame}${reset}" >&2
        sleep "$spinner_delay"
      done
    done
  ) & 
  spinner_pid=$!
}

# Stop spinner
stop_spinner() {
  (( spinner_pid )) || return
  kill "$spinner_pid" 2>/dev/null
  wait "$spinner_pid" 2>/dev/null
  spinner_pid=0
  echo -ne "\r\033[2K" >&2
  tput cnorm >&2
}

# Add user message and assistant response to history
add_to_history() {
  local user_message="$1"
  local assistant_message="$2"
  local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  
  mkdir -p "/tmp/$USER"
  touch "$history_file"

  # Format message as JSON
  jq -n --arg role "user" --arg content "$user_message" \
    --arg time "$timestamp" \
    '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
  jq -n --arg role "assistant" --arg content "$assistant_message" \
    --arg time "$timestamp" \
    '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
}

# Read from history, excluding timestamps
read_from_history() {
  if [ ! -f "$history_file" ]; then
    echo "[]"
    return
  fi

  local now_epoch=$(date +%s)
  local cutoff=$(date -d "@$((now_epoch - history_time_window_minutes*60))" '+%Y-%m-%d %H:%M:%S')

  # Filter by timestamp and trim if needed
  jq -s --arg cutoff "$cutoff" --argjson max "$history_max_records" '
    map(select(.timestamp >= $cutoff))
    | if length > $max then .[-$max:] else . end
    | map({role, content})
  ' "$history_file"
}

# Display truncated input
display_truncated() {
  local input="$1"
  if (( ${#input} > 1000 )); then
    printf "%s" "${grey}${input:0:1000} #display truncated...${reset}"
  else
    printf "%s" "${grey}$input${reset}"
  fi
}

# Process command line arguments
process_inputs() {
  if [[ "$(basename "$0")" == "plss" ]]; then
    is_bash_mode=true
  fi

  case "$1" in
    -t) show_pipe_input=true; shift ;;
    -h) print_usage_and_exit ;;
    -?) print_usage_and_exit 1 ;;
  esac
  [[ "$1" =~ ^- ]] && print_usage_and_exit 1

  [ ! -t 0 ] && piped_input="$(cat)"

  arg_input="$*"

  [[ "$is_bash_mode" == "true" ]] && system_instruction="$system_instruction_bash"
  
  [[ -z "$arg_input" && -z "$piped_input" ]] && print_usage_and_exit 1

  task="$arg_input"
  input=$(sanitize_input "$piped_input")

  was_truncated=0
  if ((${#input} > max_input_length)); then
    was_truncated=1
    input="${input:0:max_input_length}"
  fi

  if $show_pipe_input && [[ -n "$input" ]]; then
    echo "in" >&2
    echo -e "$(display_truncated "$input")" >&2
  fi
}

# Build prompt from task, input, and system instruction
build_prompt() {
  if [[ -n "$task" && -n "$input" ]]; then
    user_prompt="Given the input: \"$input\", perform the task: \"$task\", and output the result only"
  elif [[ -n "$input" ]]; then
    user_prompt=$input
  else
    user_prompt=$task
  fi

  total_chars=${#user_prompt}
  spinner_note="input $total_chars"
  [[ $was_truncated -eq 1 ]] && spinner_note="$spinner_note truncated"

  user_prompt="$user_prompt; Follow all general rules."
}

# Call OpenAI API with prompt and history
call_api() {
  history_messages=$(read_from_history)

  json_payload=$(jq -n \
    --arg model "$model" \
    --arg sys "$system_instruction" \
    --argjson hist "$history_messages" \
    --arg prompt "$user_prompt" \
    '{
      model: $model,
      messages: (
      [{role: "system", content: $sys}] + 
      $hist + 
      [{role: "user", content: $prompt}])  
    }')

  # Use a temp file for stderr to make signal handling robust
  stderr_file=$(mktemp)
  
  start_spinner
  response=$(curl -s -w "\n%{http_code}" --max-time "$timeout_seconds" "$base_url/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$json_payload" 2>"$stderr_file"
  )
  stop_spinner

  http_code=${response##*$'\n'}
  http_body=${response%$'\n'*}
  curl_stderr=$(<"$stderr_file") # Read stderr from the temp file
  # The temp file is removed by the cleanup function on exit

  if (( http_code != 200 )); then
    echo "Request failed ($http_code):" >&2
    [[ -n "$http_body" ]] && echo "$http_body" >&2 || echo "$curl_stderr" >&2
    exit 1
  fi

  output=$(jq -r '.choices[0].message.content // ""' <<< "$http_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  add_to_history "$user_prompt" "$output"
}

# Handle response for chat and bash mode
handle_output() {
  if $is_bash_mode; then
    command="$output"
    if [[ "$command" == "Shell Command Unknown" ]]; then
      echo -e "${grey}Shell Command Unknown${reset}" >&2
      exit 0
    fi

    if [ -t 1 ]; then
      echo "$command"
    else
      { echo "$command" >&2; echo "$command"; }
    fi

    echo "$command" >> ~/.bash_history
    echo -e "${grey}Press ${reset}Y${grey} to run. Any other key cancels [then use ↑ to edit].${reset}" >&2
    read -n 1 -r response </dev/tty
    echo "" >&2

    if [[ "$response" =~ ^[Yy]$ ]]; then
      eval "$command" 1>&2
    else
      echo -e "${grey}Command execution cancelled.${reset}" >&2
      exit 0
    fi
  else  # General chat mode
    if [ -t 1 ]; then
      command -v glow >/dev/null 2>&1 && { echo "$output" | glow - -w "$(tput cols)"; }  || echo "$output"
    else
      echo -e "$(display_truncated "$output")" >&2
      echo "$output"
    fi
    [[ $was_truncated -eq 1 ]] && echo -e "${grey}(Truncated input - answer could be wrong or incomplete)${reset}" >&2
  fi
}

# Main script
# --- Sanity checks ---
for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    echo "Please install it and try again." >&2
    exit 1
  fi
done
# ---
trap cleanup EXIT

show_pipe_input=false
is_bash_mode=false
system_instruction="$system_instruction_general"
[[ -z "$OPENAI_API_KEY" ]] && { echo "OPENAI_API_KEY not set" >&2; exit 1; }
process_inputs "$@"
build_prompt
call_api
handle_output