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
spinner_pid=0
stderr_file=""
show_piped_input=false
last_action_type="empty_user_prompt"
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
# Active profile
active="openai_1"

# Profile: openai_1
openai_1_provider="openai"
openai_1_model="gpt-4o"
openai_1_url="https://api.openai.com/v1"
openai_1_key="OPENAI_API_KEY"

# Other global settings
timeout_seconds=60
max_input_length=64000
history_file="$HOME/.config/pls/pls.log"
history_time_window_minutes=30
history_max_records=30

initialize_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")" && cat > "$CONFIG_FILE" <<'EOF'
# Active profile
active="openai_1"

# Profile: openai_1
openai_1_provider="openai"
openai_1_model="gpt-4o"
openai_1_url="https://api.openai.com/v1"
openai_1_key="OPENAI_API_KEY"

# Profile: openai_2
openai_2_provider="openai"
openai_2_model="gpt-5"
openai_2_url="https://api.openai.com/v1"
openai_2_key="OPENAI_API_KEY"

# Profile: gemini_1
gemini_1_provider="gemini"
gemini_1_model="gemini-2.5-flash"
gemini_1_url="https://generativelanguage.googleapis.com/v1beta"
gemini_1_key="GEMINI_API_KEY"

# Other global settings
timeout_seconds=60
max_input_length=64000
history_file="$HOME/.config/pls/pls.log"
history_time_window_minutes=30
history_max_records=30
EOF
  fi
  if ! source "$CONFIG_FILE"; then
    echo "Error: Failed to source config file" >&2
    echo "$CONFIG_FILE" >&2
    exit 1
  fi

  # check profile
  profile="$active"
  # Dynamically read profile fields
  eval "api_provider=\$${profile}_provider"
  eval "api_model=\$${profile}_model"
  eval "api_base_url=\$${profile}_url"
  eval "api_key_env=\$${profile}_key"

  # Validate provider
  if [[ "$api_provider" != "openai" && "$api_provider" != "gemini" ]]; then
    echo "Error: Provider '$api_provider' for profile '$profile' is not supported." >&2
    echo "$CONFIG_FILE" >&2
    exit 1
  else
    api_key="${!api_key_env}"
    if [[ -z "$api_key" ]]; then
      echo "Error: API key for '$profile' not set. Please export $api_key_env"
    exit 1
    fi
  fi
}

# System instruction
shell_type="Linux"
if [[ $(uname) == "Darwin" ]]; then 
  shell_type="macOS (Bash 3 with BSD utilities)"
elif [[ $(uname) == "Linux" ]]; then
  shell_type="Linux"
elif [[ $(uname) == "FreeBSD" ]]; then
  shell_type="FreeBSD"
else
  echo "Unsupported OS: $(uname)" >&2
  exit 1
fi
shell_type="macOS (Bash 3 with BSD utilities)"
SYSTEM_INSTRUCTION="
If user requests to run a shell command, provide a very brief plain-text explanation as shell_command_explanation and generate a valid shell command for ${shell_type} to fullfill user request. If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution. Prefer a single command; always use '&&' to join commands, and use \ for line continuation on long commands. Use sudo if likely required. If no shell command requested, answer concisely and directly as chat_response, prefer under 80 words, use Markdown. If asked for a fact or result, answer with only the exact value or fact in plain text. Do not include extra words, explanations, or complete sentences.
Special cases that you treat also as requesting to run a shell command: 
If user requests 'change active profile to \"profile_name\"', provide the shell_command as sed -i 's/^active=.*/active=\"profile_name\"/' ~/.config/pls/pls.conf , make sure \"profile_name\" in quotes, and shell_command_explanation as 'pls: run this to change active profile to \"profile_name\"'. 
If user requests 'show active profile', provide the shell_command as cat ~/.config/pls/pls.conf | grep \"active\" , and shell_command_explanation as 'pls: show current active profile name'.
If user requests 'delete all chat history', provide the shell_command as rm -f ~/.config/pls/pls.log , and shell_command_explanation as 'pls: delete all chat history'.
Make sure to adapt these shell_commands for ${shell_type}.
"
# echo "$SYSTEM_INSTRUCTION"
# ======================
# FUNCTION DEFINITIONS
# ======================
print_usage_and_exit() {
  cat >&2 << EOF
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
EOF
  exit "${1:-0}"
}

check_dependencies() {
  for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
      printf 'Error: Required command '\''%s'\'' is not installed.\n' "$cmd" >&2
      printf 'Please install it and try again.\n' >&2
      exit 1
    fi
  done
}

cleanup() {
  stop_spinner
  [[ -n "$stderr_file" ]] && rm -f "$stderr_file"
}

start_spinner() {
  (
    tput civis >&2
    printf '\n\n\n\n\n\033[5A' >&2
    printf '\r\033[K\r_ %s %s(%s)%s:' "$GREY" "$api_model" "$spinner_note" "$RESET" >&2
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
  
  case $api_provider in
  openai)
  jq -s \
    --argjson cutoff_epoch "$cutoff_epoch" \
    --argjson max "$history_max_records" \
    '
      map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | if length > $max then .[-$max:] else . end
      | map({role, content})
    ' "$history_file"
  ;;
  gemini)
  jq -s \
    --argjson cutoff_epoch "$cutoff_epoch" \
    --argjson max "$history_max_records" \
    '
      map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | if length > $max then .[-$max:] else . end
      | map({
          "role": (if .role == "assistant" then "model" else "user" end),
          "parts": [{"text": .content}]
        })
    ' "$history_file"
  ;;
  *) printf 'Unsupported API provider: %s\n' "$api_provider" >&2; exit 1 ;;
  esac
}

show_piped_input() {
  printf '\n%s> %s' "$GREY" "$RESET" >&2
  (( ${#piped_input} > 1000 )) && 
    printf '%s%s%s\n' "$GREY" "${piped_input:0:1000} #display truncated..." "$RESET" ||
    printf '%s%s%s\n' "$GREY" "$piped_input" "$RESET"
}

process_inputs() {
  case "$1" in
    -p) show_piped_input="true"; shift ;;
    -h) print_usage_and_exit ;;
    -?) print_usage_and_exit 1 ;;
  esac
  [[ "$1" =~ ^- ]] && print_usage_and_exit 1

  # read both input
  [ ! -t 0 ] && piped_input="$(cat)"
  arg_input="$*"
  
  # process piped input
  if [[ -n "$piped_input" ]]; then
    piped_input=$(tr -d '\000-\010\013\014\016-\037\177' <<< "$piped_input")  
    if ((${#piped_input} > max_input_length)); then
    piped_input="${piped_input:0:max_input_length}"
    was_truncated=1
    fi
    [[ "$show_piped_input" == "true" ]] && show_piped_input    
  fi
}

build_prompt() {
  if [[ -z "$piped_input" && -z "$arg_input" ]]; then
    last_action_type="empty_user_prompt"
    return
  fi

  if [[ -n "$piped_input" && -n "$arg_input" ]]; then
    user_prompt="Given the data: \"$piped_input\", perform the task: \"$arg_input\" using given data as input, and output the result only"
  elif [[ -n "$piped_input" ]]; then
    user_prompt="$piped_input"
  elif [[ -n "$arg_input" ]]; then
    user_prompt="$arg_input"
  fi
  last_action_type="new_user_prompt"
  total_chars=${#user_prompt}
  spinner_note="input $total_chars"
  [[ $was_truncated -eq 1 ]] && spinner_note="$spinner_note truncated"
}

call_gemini_api() {
  local history_messages
  history_messages=$(read_from_history)

  # Define the JSON schema for the structured output.
  local json_schema_payload
  json_schema_payload=$(jq -n '{
    "type": "OBJECT",
    "properties": {
      "shell_command_requested": {
        "type": "BOOLEAN",
        "description": "Whether the user requested or implied needing a shell command."
      },
      "shell_command_explanation": {
        "type": "STRING",
        "description": "A very brief explanation of the shell command."
      },
      "shell_command": {
        "type": "STRING",
        "description": "The shell command to accomplish the task, if applicable."
      },
      "chat_response": {
        "type": "STRING",
        "description": "A clear and helpful general answer to the user request, if not about shell command"
      }
    },
    "required": ["shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"]
  }')

  # to enforce the structured output.
  local json_payload
  json_payload=$(jq -n \
    --arg prompt "$user_prompt" \
    --arg sys "$SYSTEM_INSTRUCTION" \
    --argjson history "$history_messages" \
    --argjson schema "$json_schema_payload" \
  '{
    "system_instruction": {
      "parts": [
        { "text": $sys }
      ]
    },
    "contents": ($history + [
      {
        "role": "user",
        "parts": [
          { "text": $prompt }
        ]
      }
    ]),
    "generationConfig": {
      "responseMimeType": "application/json",
      "responseSchema": $schema
    }
  }')

  stderr_file=$(mktemp)
  start_spinner  # Make the API call using curl.
  local response
  response=$(curl -s -X POST -w "\n%{http_code}" --max-time "$timeout_seconds" \
    -H "Content-Type: application/json" \
    -d "${json_payload}" \
    "${api_base_url}/models/${api_model}:generateContent?key=${api_key}" 2>"$stderr_file")

  stop_spinner
  # Check for API errors and provide descriptive output.
  curl_stderr=$(<"$stderr_file")
  if echo "$response" | grep -q '"error"'; then
    echo "API Error:" >&2
    echo "$response" | jq . >&2
    echo "$curl_stderr" >&2
    return 1
  fi

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
    api_out_status=$(jq -r '.candidates[0]? | .finishReason // empty' <<<"$http_body")
    if [[ "$api_out_status" != "STOP" ]]; then
        printf 'Response failed (%s)\n' "$api_out_status" >&2
        [[ -n "$http_body" ]] && printf '%s\n' "$http_body" >&2
        exit 1
    fi
  fi

  # parse response
  message_text=$(jq '.candidates[0].content.parts[0].text' <<<"$http_body")

  shell_command_requested=$(jq -r 'fromjson | .shell_command_requested' <<< "$message_text")
  shell_command_explanation=$(jq -r 'fromjson | .shell_command_explanation' <<< "$message_text")
  shell_command=$(jq -r 'fromjson | .shell_command' <<< "$message_text")
  chat_response=$(jq -r 'fromjson | .chat_response' <<< "$message_text")
  
  last_action_type="new_assistant_response"
}

# prepare request, send to API and parse response
call_openai_api() {
  local history_messages
  history_messages=$(read_from_history)
  # see  https://platform.openai.com/docs/guides/structured-outputs
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
    --arg model "$api_model" \
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
  response=$(curl -s -X POST -w "\n%{http_code}" --max-time "$timeout_seconds" "$api_base_url/responses" \
    -H "Authorization: Bearer $api_key" \
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
    api_out_status=$(jq -r '.output[]? | select(.type=="message") | .status // empty' <<<"$http_body")
    if [[ "$api_out_status" != "completed" ]]; then
        printf 'Response failed (%s)\n' "$api_out_status" >&2
        exit 1
    fi
  fi
  
  # parse response
  message_text=$(jq '
    .output[]
    | select(.type=="message")
    | .content[]
    | select(.type=="output_text")
    | .text
  ' <<<"$http_body")

  shell_command_requested=$(jq -r 'fromjson | .shell_command_requested' <<< "$message_text")
  shell_command_explanation=$(jq -r 'fromjson | .shell_command_explanation' <<< "$message_text")
  shell_command=$(jq -r 'fromjson | .shell_command' <<< "$message_text")
  chat_response=$(jq -r 'fromjson | .chat_response' <<< "$message_text")

  last_action_type="new_assistant_response"
}

call_api() {
  case $api_provider in
    openai) call_openai_api ;;
    gemini) call_gemini_api ;;
    *) printf 'Unsupported API provider: %s\n' "$api_provider" >&2; exit 1 ;;
  esac
}

# show menu under input line, supported menu_items one or more in "yeq"
show_conversation_menu() {
  menu_items="$1"
  if [[ -z "$menu_items" || -n "${menu_items//[yeq]/}" ]]; then
    printf 'Invalid menu items: %s\n' "$menu_items" >&2
    exit 1
  fi
  printf '\n%s( %s' "$GREY" "$RESET"
  [[ "$menu_items" == *y* ]] && printf '%sy%s to run, ' "$CYAN" "$GREY"
  [[ "$menu_items" == *e* ]] && printf '%se%s to edit, ' "$CYAN" "$GREY"
  [[ "$menu_items" == *q* ]] && printf '%sq%s to quit, ' "$CYAN" "$GREY"
  printf '%sor continue chat... )%s\n\033[2A' "$GREY" "$RESET"
}

continuous_conversation() {
  while true; do
    if [[ "$last_action_type" == "new_assistant_response" ]]; then
      if [[ "$shell_command_requested" == "true" ]]; then
        last_action_type="cmd_new_response"
      else
        last_action_type="chat_new_response"
      fi
    fi

    # add to history and show responses according to its type
    case "$last_action_type" in
      "cmd_new_response")
        add_to_history "$user_prompt" "suggested shell cmd:\"$shell_command\""
        printf '\n - %s%s%s\n\n' "$GREY" "$shell_command_explanation" "$RESET"
        printf '\033[2K'
        printf '%scmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '%s\n\033[2K\n' "$shell_command"
        show_conversation_menu "yeq"
        ;;
      "cmd_edited")
        printf '\033[2A\033[2K'
        printf '%supdated cmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '\033[2K'
        printf '%s\n' "$shell_command"
        printf '\033[2K\n'
        show_conversation_menu "yeq"
        ;;
      "cmd_executed")
        show_conversation_menu "eq"
        ;;
      "chat_new_response")
        add_to_history "$user_prompt" "$chat_response"
        if command -v glow >/dev/null 2>&1; then
          echo "$chat_response" | glow - -w "$(tput cols)"
        else
          printf '\n%s\n\n' "$chat_response"
        fi
        show_conversation_menu "q"
        ;;
      "empty_user_prompt")
        printf '\n  Hi!\n\n' # AI said hi
        # hint
        show_conversation_menu "q"
        last_action_type="chat_new_response" # becasue AI said hi
        ;;

      *)
        printf 'Menu Error - %s\n' "$last_action_type" >&2
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
          shell_command=$(zsh -c "shell_command='$single_line_shell_command'; vared -p '${GREEN}>>${RESET}' -c shell_command; echo \$shell_command")
        else
          read -e -r -p "${GREEN}>>${RESET}" -i "$single_line_shell_command" shell_command </dev/tty

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
      arg_input="$user_input"
      piped_input=""
      was_truncated=0
      build_prompt
      call_api
    fi
  done
}

# If not a terminal, just output the response in plain text
single_time_output() {
  if [[ "$last_action_type" == "new_assistant_response" ]]; then
    if [[ "$shell_command_requested" == "true" ]]; then
      printf '%s\n' "$shell_command"
    else
      printf '%s\n' "$chat_response"
    fi
  else
    exit 1
  fi
}

main() {
  initialize_config
  check_dependencies
  process_inputs "$@"
  build_prompt
  # Enter continuous conversation mode if using interative shell
  if [[ -t 1 ]]; then
    if [[ "$last_action_type" == "new_user_prompt" ]]; then
      call_api
    fi
    continuous_conversation
  else # Piped output
    call_api
    single_time_output
  fi  
}

# EXECUTION STARTS HERE
trap cleanup EXIT
main "$@"