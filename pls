#!/usr/bin/env bash

# Configuration and Constants
readonly CONFIG_FILE="$HOME/.config/pls/pls.conf"
readonly GREEN=$'\033[32m' # for line prompt (prefix not AI prompt)
readonly GREY=$'\033[90m' # for informative messages
readonly CYAN=$'\033[36m' # for menu shortcuts
readonly YELLOW=$'\033[33m' # for shell command to be executed
readonly RESET=$'\033[0m'
# Create wrapped versions specifically for readline prompts
readonly GREEN_PROMPT=$'\001'"${GREEN}"$'\002'
readonly RESET_PROMPT=$'\001'"${RESET}"$'\002'

readonly SPINNER_DELAY=0.2
readonly SPINNER_FRAMES=(⠷ ⠯ ⠟ ⠻ ⠽ ⠾)

# Global variables
spinner_pid=0
stderr_file=""
show_piped_input=false
last_action_type="empty_user_prompt"
task=""
input=""
was_input_truncated="false"
shell_command_requested=""
shell_command_explanation=""
shell_command=""
chat_response=""
user_prompt=""

load_and_apply_config() {
# Default config from config file - will be overwritten by sourcing config file
# Active profile
active="openai_1"
# Additional System Prompt - use with caution, may break functionality
USER_SYSTEM_INSTRUCTION=""
# Profile: openai_1
openai_1_provider="openai"
openai_1_model="gpt-4o"
openai_1_url="https://api.openai.com/v1"
openai_1_key="OPENAI_API_KEY"

# Other settings
timeout_seconds=60
max_input_length=64000 # in chars, to avoid too long input from pipe
history_file="$HOME/.config/pls/pls.log"
history_time_window_minutes=30
history_max_records=30

# Create config file with default settings if not exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")" && cat > "$CONFIG_FILE" <<'EOF'
# Active profile
active="openai_1"

# Use with Caution: Additional System Instruction for shell command generation 
# USER_SYSTEM_INSTRUCTION="If user requests ... , provide the shell_command as echo \"thank you\"... , shell_command_explanation as ... ."

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

# Other settings
timeout_seconds=60
max_input_length=64000
history_file="$HOME/.config/pls/pls.log"
history_time_window_minutes=30
history_max_records=30
EOF
  fi
  # source config file  
  if ! source "$CONFIG_FILE"; then
    echo "Error: Failed to source config file" >&2
    echo "$CONFIG_FILE" >&2
    exit 1
  fi
  apply_profile
}

apply_profile() {
  # apply profile
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

  # System instruction
  case $(uname) in
    Darwin)  shell_type="macOS (Bash 3 with BSD utilities)" ;;
    FreeBSD) shell_type="FreeBSD" ;;
    *)       shell_type="Linux" ;;
  esac

  SYSTEM_INSTRUCTION="
If user requests to run a shell command, provide a very brief plain-text explanation as shell_command_explanation and generate a valid shell command for ${shell_type} to fullfill user request. If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution. Prefer a single command; always use '&&' to join commands, and use \ for line continuation on long commands. Use sudo if likely required. If no shell command requested, answer concisely and directly as chat_response, prefer under 80 words, use Markdown if it helps. If asked for a fact or result, answer with only the exact value or fact in plain text. Do not include extra words, explanations, or complete sentences.
Special cases that you also treat as requesting to run a shell command: 
If user requests 'show active profile or show current model', provide the shell_command as echo \"active profile: \${active} using \${api_model\} #pls\" , and shell_command_explanation as 'pls: show current active profile name and model in use'.
If user requests 'change active profile to \"profile_name\"', provide the shell_command as active=\"profile_name\" && apply_profile #pls, make sure \"profile_name\" in quotes, and shell_command_explanation as 'pls: change to \"profile_name\" for this session, to edit profiles and keep changes say \"edit config\"'.
If user requests 'delete all chat history', provide the shell_command as rm -f ~/.config/pls/pls.log && echo \"chat history deleted\" #pls , and shell_command_explanation as 'pls: delete all chat history'.
If user requests 'edit config' or 'edit config file of pls', provide the shell_command as nano ~/.config/pls/pls.conf && load_and_apply_config #pls , or use vi, and shell_command_explanation as 'pls: edit config file to change profile or settings'.
${USER_SYSTEM_INSTRUCTION}
Make sure to adapt these shell_commands in special cases for ${shell_type}.
"
}

# APP FUNCTION DEFINITIONS
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
    tput civis; tput sc
    printf '\n\n\n\n\n'; tput rc; tput el
    printf '_%s %s%s:' "$GREY" "$api_model" "$RESET"
    while :; do
      for frame in "${SPINNER_FRAMES[@]}"; do
        printf '\r%s%s%s' "$GREEN" "$frame" "$RESET"
        sleep "$SPINNER_DELAY"
      done
    done
  ) >&2 &
  spinner_pid=$!
}

stop_spinner() {
  (( $spinner_pid )) || return
  kill "$spinner_pid" 2>/dev/null
  wait "$spinner_pid" 2>/dev/null
  spinner_pid=0
  printf '\r'; tput el; tput cnorm
} >&2

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
  tail -n $((history_max_records * 5)) "$history_file" \
   | jq -s \
    --argjson cutoff_epoch "$cutoff_epoch" \
    'map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | map({role, content})'
  ;;
  gemini)
  tail -n $((history_max_records * 5)) "$history_file" \
   | jq -s \
    --argjson cutoff_epoch "$cutoff_epoch" \
    'map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | map({
          "role": (if .role == "assistant" then "model" else "user" end),
          "parts": [{"text": .content}]
        })' 
  ;;
  *) printf 'Unsupported API provider: %s\n' "$api_provider" >&2; exit 1 ;;
  esac
}

show_piped_input() {
  printf '>\n' >&2
  printf '%s%s%s\n' "$GREY" "${piped_input:0:250}" "$RESET" >&2
  (( ${#piped_input} > 250 )) &&
    printf '...\n' >&2
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
    was_input_truncated="true"
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
  local message_text
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
  local message_text
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
  local menu_items="$1"
  if [[ -z "$menu_items" || -n "${menu_items//[req]/}" ]]; then
    printf 'Invalid menu items: %s\n' "$menu_items" >&2
    exit 1
  fi
  tput sc # save cursor position
  printf '\n%s( %s' "$GREY" "$RESET"
  [[ "$menu_items" == *r* ]] && printf '%sr%sun, ' "$CYAN" "$GREY"
  [[ "$menu_items" == *e* ]] && printf '%se%sdit, ' "$CYAN" "$GREY"
  [[ "$menu_items" == *q* ]] && printf '%sq%suit, ' "$CYAN" "$GREY"
  printf '%sor continue chat... )%s\n' "$GREY" "$RESET"
  if [[ "$was_truncated" == "true" ]]; then
    echo "Note: this response is generated on a truncated input" >&2
  fi
  tput rc # restore cursor position
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
        tput el
        printf '%scmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        printf '%s%s%s\n' "$YELLOW" "$shell_command" "$RESET"
        tput el
        show_conversation_menu "req"
        ;;
      "cmd_edited")
        tput cuu 2
        tput el
        printf '%supdated cmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        tput el
        printf '%s%s%s\n' "$YELLOW" "$shell_command" "$RESET"
        tput el
        show_conversation_menu "req"
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
    if ! read -e -r -p "${GREEN_PROMPT}>>${RESET_PROMPT}" user_input </dev/tty; then
      break  # Exit on read error (e.g., Ctrl-D)
    fi
    case "${last_action_type}:${user_input}" in
      cmd_new_response:[Rr]|cmd_edited:[Rr])
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
        tput cuu1 && tput el
        printf '%sedit:%s>%s\n' "$GREY" "$GREEN" "$RESET"
        tput el

        tput sc # save cursor position
        printf '\n'
        printf '%s( %s⏎%s to finish edit)%s\n' "$GREY" "$CYAN" "$GREY" "$RESET"
        tput rc # restore cursor position

        single_line_shell_command=$(echo "$shell_command" | sed 's/\\$//' | tr -d '\n')
        if [[ "$(uname)" == "Darwin" ]]; then
          # For macOS with ZSH - use base64 encoding to safely pass the command
          GREEN_ZSH="%{$GREEN%}"
          RESET_ZSH="%{$RESET%}"
  
          # Encode the command to safely pass it
          encoded_command=$(printf '%s' "$single_line_shell_command" | base64)
  
          shell_command=$(zsh -c "
            shell_command=\$(echo '$encoded_command' | base64 -d)
            vared -p '$GREEN_ZSH>>$RESET_ZSH' -c shell_command
            echo \"\$shell_command\"
            ")
        else
          read -e -r -p "${GREEN_PROMPT}>>${RESET_PROMPT}" -i "$single_line_shell_command" shell_command </dev/tty
        fi
        if [[ -z "$shell_command" ]]; then
          shell_command="$single_line_shell_command"
        fi
        last_action_type="cmd_edited" 
        ;;
      cmd_new_response:[Qq]|cmd_edited:[Qq]|cmd_executed:[Qq]|chat_new_response:[Qq])
        tput el
        printf '%sbye%s\n' "$GREY" "$RESET"
        break
        ;;
      cmd_new_response:|cmd_edited:|cmd_executed:|chat_new_response:)
        tput el
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
      was_input_truncated="false"
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
    if [[ "$was_truncated" == "true" ]]; then
      echo "Note: this response is generated on a truncated input" >&2
    fi
  else
    exit 1
  fi
}

main() {
  load_and_apply_config
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