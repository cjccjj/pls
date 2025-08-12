#!/bin/bash

# Configuration and Constants
readonly CONFIG_FILE="$HOME/.config/pls/pls.conf"
readonly GREEN=$'\033[32m'
readonly GREY=$'\033[90m'
readonly RESET=$'\033[0m'
readonly SPINNER_DELAY=0.2
readonly SPINNER_FRAMES=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)

# Global variables
config_file="$CONFIG_FILE"
spinner_pid=0
stderr_file=""
show_pipe_input=false
task=""
input=""
was_truncated=0
shell_command_requested=""
shell_command_explanation=""
shell_command=""
chat_response=""
spinner_note=""
user_prompt=""

# System instruction
readonly SYSTEM_INSTRUCTION="
If user requests a shell command, provide a very brief plain-text explanation as shell_command_explanation and generate a valid shell command using $(uname) based on user input as shell_command. If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution. Prefer a single command; Use \ for line continuation on long commands. Use sudo if likely required. If no shell command requested, answer concisely and directly as chat_response, prefer under 60 words, use Markdown. If asked for a fact or result, answer with only the exact value or fact in plain text. Do not include extra words, explanations, or complete sentences.
"

# ======================
# FUNCTION DEFINITIONS
# ======================

print_usage_and_exit() {
  cat >&2 << EOF
pls v0.4
Usage:    pls [-t] [messages...]                  # Chat and generate shell commands if requested
                                                  # Continue chat until quit
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
EOF
  exit "${1:-0}"
}

initialize_config() {
  if [[ ! -f "$config_file" ]]; then
    mkdir -p "$(dirname "$config_file")" && cat > "$config_file" <<'EOF'
base_url="https://api.openai.com/v1"
model="gpt-5-mini"
timeout_seconds=60
max_input_length=64000

history_file="/tmp/$USER/pls_history.log"
history_time_window_minutes=30
history_max_records=30
EOF
  fi
  source "$config_file"
}

check_dependencies() {
  for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
      printf 'Error: Required command '\''%s'\'' is not installed.\n' "$cmd" >&2
      printf 'Please install it and try again.\n' >&2
      exit 1
    fi
  done
  [[ -z "$OPENAI_API_KEY" ]] && { printf 'OPENAI_API_KEY not set\n' >&2; exit 1; }
}

cleanup() {
  stop_spinner
  [[ -n "$stderr_file" ]] && rm -f "$stderr_file"
}

sanitize_input() {
  tr -d '\000-\010\013\014\016-\037\177' <<< "$1"
}

start_spinner() {
  (
    tput civis >&2
    printf '\n\n\n\n\033[4A' >&2
    printf '\r\033[K\r_ %s %s(%s)%s:' "$model" "$GREY" "$spinner_note" "$RESET" >&2
    while :; do 
      for frame in "${SPINNER_FRAMES[@]}"; do
        printf '\r%s%s%s' "$GREEN" "$frame" "$RESET" >&2
        sleep "$SPINNER_DELAY"
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
  printf '\r\033[2K' >&2
  tput cnorm >&2
}

add_to_history() {
  local user_message="$1"
  local assistant_message="$2"
  local timestamp
  timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  
  mkdir -p "/tmp/$USER"
  touch "$history_file"

  jq -n --arg role "user" --arg content "$user_message" \
    --arg time "$timestamp" \
    '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
  jq -n --arg role "assistant" --arg content "$assistant_message" \
    --arg time "$timestamp" \
    '{timestamp: $time, role: $role, content: $content}' >> "$history_file"
}

read_from_history() {
  [[ -f "$history_file" ]] || { printf '[]'; return; }

  local now_epoch
  now_epoch=$(date +%s)
  local cutoff
  cutoff=$(date -d "@$((now_epoch - history_time_window_minutes*60))" '+%Y-%m-%d %H:%M:%S')

  jq -s --arg cutoff "$cutoff" --argjson max "$history_max_records" '
    map(select(.timestamp >= $cutoff))
    | if length > $max then .[-$max:] else . end
    | map({role, content})
  ' "$history_file"
}

display_truncated() {
  local input="$1"
  (( ${#input} > 1000 )) && 
    printf '%s%s%s' "$GREY" "${input:0:1000} #display truncated..." "$RESET" ||
    printf '%s%s%s' "$GREY" "$input" "$RESET"
}

process_inputs() {
  case "$1" in
    -t) show_pipe_input=true; shift ;;
    -h) print_usage_and_exit ;;
    -?) print_usage_and_exit 1 ;;
  esac
  [[ "$1" =~ ^- ]] && print_usage_and_exit 1

  [ ! -t 0 ] && piped_input="$(cat)"
  arg_input="$*"
  [[ -z "$arg_input" && -z "$piped_input" ]] && print_usage_and_exit 1

  task="$arg_input"
  input=$(sanitize_input "$piped_input")

  was_truncated=0
  if ((${#input} > max_input_length)); then
    was_truncated=1
    input="${input:0:max_input_length}"
  fi

  if $show_pipe_input && [[ -n "$input" ]]; then
    printf 'in\n' >&2
    printf '%s\n' "$(display_truncated "$input")" >&2
  fi
}

build_prompt() {
  if [[ -n "$task" && -n "$input" ]]; then
    user_prompt="Given the input: \"$input\", perform the task: \"$task\", and output the result only"
  elif [[ -n "$input" ]]; then
    user_prompt="$input"
  elif [[ -n "$task" ]]; then
    user_prompt="$task"
  else
    exit 1
  fi

  total_chars=${#user_prompt}
  spinner_note="input $total_chars"
  [[ $was_truncated -eq 1 ]] && spinner_note="$spinner_note truncated"
}

call_api() {
  local history_messages
  history_messages=$(read_from_history)
  local output_format
  output_format=$(jq -n '{
    type: "json_schema",
    name: "shell_helper",
    schema: {
        type: "object",
        properties: {
            shell_command_requested: {
                type: "boolean",
                description: "Whether the user requested or implied needing a shell command."
            },
            shell_command_explanation: {
                type: "string",
                description: "A very brief explanation of the shell command."
            },
            shell_command: {
                type: "string",
                description: "The shell command to accomplish the task, if applicable."
            },
            chat_response: {
                type: "string",
                description: "A clear and helpful general answer to the user request, if not about shell command"
            }
        },
        required: ["shell_command_requested","shell_command","shell_command_explanation","chat_response"],
        additionalProperties: false
    },
    strict: true
    }')

  local json_payload
  json_payload=$(jq -n \
    --arg model "$model" \
    --arg sys "$SYSTEM_INSTRUCTION" \
    --argjson hist "$history_messages" \
    --arg prompt "$user_prompt" \
    --argjson output_format "$output_format" \
    '{
        model: $model,
        input: (
        [{role: "developer", content: $sys}] + 
        $hist + 
        [{role: "user", content: $prompt}]),
        text: {
            format: $output_format
        }
    }')

  stderr_file=$(mktemp)
  start_spinner
  local response
  response=$(curl -s -w "\n%{http_code}" --max-time "$timeout_seconds" "$base_url/responses" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$json_payload" 2>"$stderr_file")
  stop_spinner

  local http_code
  http_code=${response##*$'\n'}
  local http_body
  http_body=${response%$'\n'*}
  local curl_stderr
  curl_stderr=$(<"$stderr_file")

  if (( http_code != 200 )); then
    printf 'Request failed (%s):\n' "$http_code" >&2
    [[ -n "$http_body" ]] && printf '%s\n' "$http_body" >&2 || printf '%s\n' "$curl_stderr" >&2
    exit 1
  else 
    local api_out_status
    api_out_status=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .status')
    if [[ "$api_out_status" != "completed" ]]; then
        printf 'Response failed (%s)\n' "$api_out_status" >&2
        [[ -n "$http_body" ]] && printf '%s\n' "$http_body" >&2
        exit 1
    fi
  fi

  shell_command_requested=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command_requested')
  shell_command_explanation=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command_explanation')
  shell_command=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command')
  chat_response=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .chat_response')
}

handle_shell_command() {
  add_to_history "$user_prompt" "suggested shell cmd:\"$shell_command\""
  printf '%s%s%s\n' "$GREY" "$shell_command_explanation" "$RESET" >&2

  if [[ -t 1 ]]; then
    while true; do
      printf '%scmd:%s>%s\n' "$GREY" "$GREEN" "$RESET" >&2
      printf '%s\n' "$shell_command"
      printf '%sPress %sY%s to run. %sE%s to edit. Other key cancels and chat.%s\n' "$GREY" "$RESET" "$GREY" "$RESET" "$GREY" "$RESET" >&2
      
      read -s -n 1 -r response </dev/tty
      case "$response" in
        [Yy])
          printf '\n' >&2
          eval "$shell_command" 1>&2
          echo "$shell_command" >> ~/.bash_history
          exit 0
          ;;
        [Ee])
          printf '\033[1A\033[2K' >&2
          printf '%sedit:%s>%s\n' "$GREY" "$GREEN" "$RESET" >&2
          read -e -r -i "$shell_command" shell_command </dev/tty
          ;;
        *)
          printf '\033[1A\033[2K' >&2
          printf '%sCommand cancelled.%s\n' "$GREY" "$RESET" >&2
          continuous_conversation
          exit 0
          ;;
      esac
    done
  else
    { printf '%s\n' "$shell_command" >&2; printf '%s\n' "$shell_command"; }
    exit 0
  fi
}

handle_chat_response() {
  add_to_history "$user_prompt" "$chat_response"

  if [[ -t 1 ]]; then
    if command -v glow >/dev/null 2>&1; then
      echo "$chat_response" | glow - -w "$(tput cols)"
    else
      printf '%s\n' "$chat_response"
    fi
  else
    printf '%s\n' "$(display_truncated "$chat_response")" >&2
    printf '%s\n' "$chat_response"
  fi
}

handle_output() {
  if [[ "$shell_command_requested" == "true" ]]; then
    handle_shell_command
  else
    handle_chat_response
  fi
  
  [[ $was_truncated -eq 1 ]] && 
    printf '%s(Truncated input - answer could be wrong or incomplete)%s\n' "$GREY" "$RESET" >&2
}

continuous_conversation() {
  while :; do
    printf '\n' >&2 
    printf '%sEmpty or %sq%s to quit, otherwise continue...%s\n' "$GREY" "$RESET" "$GREY" "$RESET" >&2
    printf '\033[2A' >&2
    
    if ! read -e -r -p "${GREEN}>>${RESET}" user_input </dev/tty; then
      break  # Exit on read error (e.g., Ctrl-D)
    fi

    # Exit if input is empty or q/Q
    if [[ -z "$user_input" || "$user_input" == "q" || "$user_input" == "Q" ]]; then
      break
    fi

    # Process next input
    task="$user_input"
    input=""
    was_truncated=0
    build_prompt
    call_api
    handle_output
  done
}

main() {
  initialize_config
  check_dependencies
  process_inputs "$@"
  build_prompt
  call_api
  handle_output

  # Enter continuous conversation mode if applicable
  if [[ -t 1 && "$shell_command_requested" != "true" ]]; then
    continuous_conversation
  fi
}

# ======================
# EXECUTION STARTS HERE
# ======================
trap cleanup EXIT
main "$@"