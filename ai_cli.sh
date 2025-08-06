#!/bin/bash

# === Configuration ===
base_url="https://open-bj.nopshop.com/openai/v1"
# base_url="https://api.openai.com/v1"
model="gpt-4o"
timeout_sec=60
max_input_length=64000
system_instruction_general="Respond only with the direct answer. Output exactly the answer content, in Markdown if helpful. Do not restate the question or add explanations. Exclude supportive phrases like \"The answer is\" or \"I think\" For single terms, phrases, or numbers, output only that exact text. If uncertain, return nothing. Never ask questions or add extra words. Keep responses concise and under 1500 words."
system_instruction_bash="You are a Linux command-line assistant; always generate valid Bash commands based on user input, assume Ubuntu if not specified. Output only the command itself with no extra text or formatting, never use \`\`\` or code blocks. Make sure to use \ for long lines, prefer a single command, join multiple commands with ; or &&. Use sudo when appropriate. If not possible or dangerous, respond exactly with \"Command Unknown\"."

# === History Configuration ===
history_time_window_min=30    # look back this many minutes
history_max_records=30        # max records to return if over this number
history_file="/tmp/$USER/pls_history.log"

# === Color and Spinner Configuration ===
green='\033[32m'
grey='\033[90m'
reset='\033[0m'
spinner_delay=0.2
spinner_frames=( ⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷ )
spinner_pid=0

# === Function Definitions ===
show_help() {
  cat >&2 << EOF
pls/plss v0.2
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

# simple sanitize input
sanitize_input() {
  tr -d '\000-\010\013\014\016-\037\177' <<< "$1"
}

# Show spinner while processing
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

# Function to add a user message and assistant response to history
add_history() {
    local user_msg="$1"
    local assistant_msg="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    mkdir -p "/tmp/$USER"
    touch "$history_file"

    # Escape and format the message as JSON (pretty printed multiline)
    jq -n --arg role "user" --arg content "$user_msg" \
        --arg time "$timestamp" \
        '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
    jq -n --arg role "assistant" --arg content "$assistant_msg" \
        --arg time "$timestamp" \
        '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
}

# Function to read from history, excluding timestamps
read_history() {
    if [ ! -f "$history_file" ]; then
        echo "[]"
        return
    fi

    local now_epoch=$(date +%s)
    local cutoff=$(date -d "@$((now_epoch - history_time_window_min*60))" '+%Y-%m-%d %H:%M:%S')

    # Filter by timestamp >= cutoff, then trim if too many
    jq -s --arg cutoff "$cutoff" --argjson max "$history_max_records" '
      map(select(.timestamp >= $cutoff))
      | if length > $max then .[-$max:] else . end
      | map({role, content})
    ' "$history_file"
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

# Process command line arguments
process_inputs() {
  case "$1" in
    -t) show_pipe_input=true; shift ;;
    -b) bash_mode=true; shift ;;
    -h) show_help ;;
    -?) show_help 1 ;;
  esac
  [[ "$1" =~ ^- ]] && show_help 1
  [ ! -t 0 ] && piped_input="$(cat)"
  arg_input="$*"

  if [[ "$bash_mode" == "true" ]]; then
    [[ -z "$arg_input" ]] && show_help 1
    system_instruction="$system_instruction_bash"
    task="$arg_input"
  else
    [[ -z "$arg_input" && -z "$piped_input" ]] && show_help 1
    task="$arg_input"
    input=$(sanitize_input "$piped_input")
  fi

  truncated=0
  if ((${#input} > max_input_length)); then
    truncated=1
    input="${input:0:max_input_length}"
  fi

  if $show_pipe_input && [[ -n "$input" ]]; then
    echo "in" >&2
    echo -e "$(truncate_string "$input")" >&2
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
  [[ $truncated -eq 1 ]] && spinner_note="$spinner_note truncated"

  user_prompt="$user_prompt; Follow all general rules."
}
# Call OpenAI API with prompt and history
call_api() {
  history_messages=$(read_history)

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

  start_spinner
  curl_stderr=""
  response=$(timeout "$timeout_sec" curl -s -w "\n%{http_code}" "$base_url/chat/completions" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$json_payload" 2> >(curl_stderr=$(cat))
  )
  stop_spinner

  http_code=${response##*$'\n'}
  http_body=${response%$'\n'*}

  if (( http_code != 200 )); then
    echo "Request failed ($http_code):" >&2
    [[ -n "$http_body" ]] && echo "$http_body" >&2 || echo "$curl_stderr" >&2
    exit 1
  fi

  output=$(jq -r '.choices[0].message.content // ""' <<< "$http_body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  add_history "$user_prompt" "$output"
}

# Handle response for chat and for bash mode execute commands
handle_output() {
  if $bash_mode; then
    cmd="$output"
    if [[ "$cmd" == "Command Unknown" ]]; then
      echo -e "${grey}Command Unknown${reset}" >&2
      exit 0
    fi

    if [ -t 1 ]; then
      echo "$cmd"
    else
      { echo "$cmd" >&2; echo "$cmd"; }
    fi

    echo "$cmd" >> ~/.bash_history
    echo -e "${grey}Press ${reset}Y${grey} to run. Any other key cancels [then use ↑ to edit].${reset}" >&2
    read -n 1 -r response </dev/tty
    echo "" >&2

    if [[ "$response" =~ ^[Yy]$ ]]; then
      eval "$cmd" 1>&2
    else
      echo -e "${grey}Command execution cancelled.${reset}" >&2
      exit 0
    fi
  else # genral chat mode
    if [ -t 1 ]; then
      command -v glow >/dev/null 2>&1 && echo "$output" | glow || echo "$output"
    else
      echo -e "$(truncate_string "$output")" >&2
      echo "$output"
    fi
    [[ $truncated -eq 1 ]] && echo -e "${grey}(Truncated input - answer could be wrong or incomplete)${reset}" >&2
  fi
}

# === Main Script ===
trap 'stop_spinner; exit' INT TERM EXIT
show_pipe_input=false
bash_mode=false
system_instruction="$system_instruction_general"
[[ -z "$OPENAI_API_KEY" ]] && { echo "OPENAI_API_KEY not set" >&2; exit 1; }
process_inputs "$@"
build_prompt
call_api
handle_output
trap - INT TERM EXIT
