#!/bin/bash

# Configuration and Constants
readonly CONFIG_FILE="$HOME/.config/pls/pls.conf"
readonly GREEN=$'\033[32m'
readonly GREY=$'\033[90m'
readonly CYAN=$'\033[36m'
readonly RESET=$'\033[0m'
readonly SPINNER_DELAY=0.2
readonly SPINNER_FRAMES=(⣷ ⣯ ⣟ ⡿ ⢿ ⣻ ⣽ ⣾)
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

# Global variables declare - will be overwritten by config file
base_url="https://api.openai.com/v1"
model="gpt-4o"
timeout_seconds=60
max_input_length=64000

history_file="$HOME/.config/pls/pls.log"
history_time_window_minutes=30
history_max_records=30

# System instruction
SYSTEM_INSTRUCTION="
If user requests a shell command, provide a very brief plain-text explanation as shell_command_explanation and generate a valid shell command using $(uname) based on user input as shell_command. If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution. Prefer a single command; always use '&&' to join commands, and use \ for line continuation on long commands. Use sudo if likely required. If no shell command requested, answer concisely and directly as chat_response, prefer under 60 words, use Markdown. If asked for a fact or result, answer with only the exact value or fact in plain text. Do not include extra words, explanations, or complete sentences.
"
GREETING="Say Hi, if user and assistant have talked about something, mention it, if not just say hi."

# ======================
# FUNCTION DEFINITIONS
# ======================

print_usage_and_exit() {
  cat >&2 << EOF
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
EOF
  exit "${1:-0}"
}

initialize_config() {
  if [[ ! -f "$config_file" ]]; then
    mkdir -p "$(dirname "$config_file")" && cat > "$config_file" <<'EOF'
base_url="https://api.openai.com/v1"
model="gpt-4o"
timeout_seconds=60
max_input_length=64000

history_file="$HOME/.config/pls/pls.log"
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
    printf '\n\n\n\n\n\033[5A' >&2
    printf '\r\033[K\r_ %s %s(%s)%s:' "$GREY" "$model" "$spinner_note" "$RESET" >&2
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
  [[ -f "$history_file" ]] || { printf '[]'; return 0; }

  local cutoff_epoch
  cutoff_epoch=$(( $(date +%s) - history_time_window_minutes * 60 ))

  jq -s \
    --argjson cutoff_epoch "$cutoff_epoch" \
    --argjson max "$history_max_records" \
    '
      map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
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
  
  if [[ -z "$arg_input" && -z "$piped_input" ]]; then
    task="$GREETING"
  else
    task="$arg_input"
  fi

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
    user_prompt="Given the data: \"$input\", perform the task: \"$task\" using given data as input, and output the result only"
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

  # 4 jq looks cleaner, note there are new lines in value
  shell_command_requested=$(jq -r '
    .output[]
    | select(.type=="message")
    | .content[].text
    | if type=="string" then (fromjson | .shell_command_requested) else .shell_command_requested end
    | tostring
  ' <<<"$http_body")

  shell_command_explanation=$(jq -r '
    .output[]
    | select(.type=="message")
    | .content[].text
    | if type=="string" then (fromjson | .shell_command_explanation) else .shell_command_explanation end
  ' <<<"$http_body")

  shell_command=$(jq -r '
    .output[]
    | select(.type=="message")
    | .content[].text
    | if type=="string" then (fromjson | .shell_command) else .shell_command end
  ' <<<"$http_body")

  chat_response=$(jq -r '
    .output[]
    | select(.type=="message")
    | .content[].text
    | if type=="string" then (fromjson | .chat_response) else .chat_response end
  ' <<<"$http_body")
}

continuous_conversation() {
  local last_action_type="new_assistant_response"

  while true; do
    if [[ "$last_action_type" == "new_assistant_response" ]]; then
      if [[ "$shell_command_requested" == "true" ]]; then
        last_action_type="cmd_new_response"
      else
        last_action_type="chat_new_response"
      fi
    fi

    # add to history and print responses
    case "$last_action_type" in
      "cmd_new_response")
        add_to_history "$user_prompt" "suggested shell cmd:\"$shell_command\""
        printf '\n - %s%s%s\n\n' "$GREY" "$shell_command_explanation" "$RESET"
        printf '\033[2K'
        printf '%scmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '%s\n\033[2K\n' "$shell_command"
        # hint
        printf '\n'
        printf '%s( %sy%s to run, %se%s to edit, %sq%s to quit, or continue chat... )%s\n' "$GREY" "$CYAN" "$GREY" "$CYAN" "$GREY" "$CYAN" "$GREY" "$RESET"
        printf '\033[2A'
        ;;
      "cmd_edited")
        printf '\033[2A\033[2K'
        printf '%supdated cmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '%s\n\033[2K\n' "$shell_command"
        # hint
        printf '\n'
        printf '%s( %sy%s to run, %se%s to edit, %sq%s to quit, or continue chat... )%s\n' "$GREY" "$CYAN" "$GREY" "$CYAN" "$GREY" "$CYAN" "$GREY" "$RESET"
        printf '\033[2A'
        ;;
      "cmd_executed")
        # hint
        printf '\n'
        printf '%s( %se%s to bring cmd again, %sq%s to quit, or continue chat... )%s\n' "$GREY" "$CYAN" "$GREY" "$CYAN" "$GREY" "$RESET"
        printf '\033[2A'
        ;;
      "chat_new_response")
        add_to_history "$user_prompt" "$chat_response"
        if command -v glow >/dev/null 2>&1; then
          echo "$chat_response" | glow - -w "$(tput cols)"
        else
          printf '%s\n' "$chat_response"
        fi
        # hint
        printf '\n'
        printf '%s( %sq%s to quit, or continue chat... )%s\n' "$GREY" "$CYAN" "$GREY" "$RESET"
        printf '\033[2A'
        ;;
      *)
        printf 'Menu Error\n' >&2
        exit 1
        ;;
    esac

    # get user input
    if ! read -e -r -p "${GREEN}>>${RESET}" user_input </dev/tty; then
      break  # Exit on read error (e.g., Ctrl-D)
    fi
    case "${last_action_type}:${user_input}" in
      cmd_new_response:[Yy]|cmd_edited:[Yy])
        printf '\033[2K\n'
        echo "$shell_command" >> ~/.bash_history
        eval "$shell_command"
        if [ $? -eq 0 ]; then
          printf '%sCommand succeeded%s\n' "$GREY" "$RESET"
          add_to_history "Command succeeded: \"$shell_command\"" "Ok"
        else
          printf '%sCommand failed%s\n' "$GREY" "$RESET"
          add_to_history "Command failed: \"$shell_command\"" "Sorry"
        fi
        last_action_type="cmd_executed"
        ;;
      cmd_new_response:[Ee]|cmd_edited:[Ee]|cmd_executed:[Ee])
        printf '\033[1A\033[2K'
        printf '%sedit:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '\033[2K'
        
        printf '\n'
        printf '%s( %s⏎%s to finish edit)%s\n' "$GREY" "$CYAN" "$GREY" "$RESET"
        printf '\033[2A'

        single_line_shell_command=$(echo "$shell_command" | sed 's/\\$//' | tr '\n' ' ')
        if [[ "$(uname)" == "Darwin" ]]; then
            shell_command="$single_line_shell_command"
            vared -p "Command: " -c shell_command
        else
            read -e -r -i "$single_line_shell_command" shell_command </dev/tty
        fi
        if [[ -z "$shell_command" ]]; then
          printf '\033[2K\n\033[2K'
          printf '%sbye%s\n' "$GREY" "$RESET"
          break
        else 
          last_action_type="cmd_edited"
        fi
        ;;
      cmd_new_response:[Qq]|cmd_edited:[Qq]|cmd_executed:[Qq]|chat_new_response:[Qq])
        printf '\033[2K\n'
        printf '%sbye%s\n' "$GREY" "$RESET"
        break
        ;;
      cmd_new_response:|cmd_edited:|cmd_executed:|chat_new_response:)
        printf '\033[2K\n'
        printf '%sbye%s\n' "$GREY" "$RESET"
        break
        ;;
      cmd_new_response:?*|cmd_edited:?*|cmd_executed:?*|chat_new_response:?*)
        last_action_type="new_user_prompt"
        ;;
      *)
        printf 'Menu Error\n' >&2
        exit 1
    esac

    # new request to api
    if [[ "$last_action_type" == "new_user_prompt" ]]; then
      task="$user_input"
      input=""
      was_truncated=0
      build_prompt
      call_api
      last_action_type="new_assistant_response"
    fi
  done
}

main() {
  initialize_config
  check_dependencies
  process_inputs "$@"
  build_prompt
  call_api

  # Enter continuous conversation mode if applicable
  if [[ -t 1 ]]; then
    continuous_conversation
  else
    # If not a terminal, just output the response in plain text
    if [[ "$shell_command_requested" == "true" ]]; then
      printf '%s\n' "$shell_command"
    else
      printf '%s\n' "$chat_response"
    fi
  fi  
}

# ======================
# EXECUTION STARTS HERE
# ======================
trap cleanup EXIT
main "$@"