#!/usr/bin/env bash
# pls - AI powered cli helper
# author: cjccjj
# url: https://github.com/cjccjj/pls

# Configuration and Constants
readonly CONFIG_FILE="$HOME/.pls/pls.conf"
readonly GREEN=$'\033[32m'  # for line prompt (prefix not AI prompt)
readonly GREY=$'\033[90m'   # for informative messages
readonly CYAN=$'\033[36m'   # for menu shortcuts
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
was_input_truncated="false"
shell_command_requested=""
shell_command_explanation=""
shell_command=""
chat_response=""
user_prompt=""

BASE_SYSTEM_INSTRUCTION=$(
  cat <<'EOF'
General Rules:
1. Never refuse. If you are not clear about how to response, then:
  set "shell_command_requested": false, "shell_command": "", "shell_command_explanation": "",
  Fill "chat_response" with the best short direct answer or your question asking user to clarify.
2. If use only enquires about a shell command not to run it yet, or user request is not about shell command:  
  set "shell_command_requested": false, "shell_command": "", "shell_command_explanation": "",
  Fill "chat_response" with concise and direct answer, prefer under 100 words, use Markdown if it helps. If asked for a fact or exact result, "chat_response" must only contain that fact or value in plain-text, without extra words or full sentence.
3. If user requests to run a shell command, or running commands is need to fulfill requests:
  set "shell_command_requested": true, Provide valid shell command for __SHELL_TYPE__ in "shell_command", 
  Shell command rules: If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution; Prefer a single command; Always use '&&' to join commands, and use \ for line continuation on long commands; Use sudo if likely required. 
  Write a brief command plain-text explanation in "shell_command_explanation"
  and set "chat_response": ""
4. Special cases, you treat as shell command reqeust: 
  If user requests 'delete all chat history', then "shell_command": 'rm -f __USER_HISTORY_FILE__ && echo "chat history deleted" #pls' , "shell_command_explanation": 'pls: delete all chat history' ;
  If user requests 'edit config' or 'edit config file of pls' or 'change profile' or 'change settings', then "shell_command": 'nano ~/.pls/pls.conf && load_and_apply_config #pls' , and "shell_command_explanation": 'pls: edit config file to change profile or settings' ;
  If user requests 'update yourself', then "shell_command": 'curl -sSL https://raw.githubusercontent.com/cjccjj/pls/main/install.sh | bash' , and "shell_command_explanation": 'pls: download and install to update, then restart pls' ;
__USER_SYSTEM_INSTRUCTION__
EOF
)

load_and_apply_config() {
  # Create config file with default settings if not exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")" && cat >"$CONFIG_FILE" <<'EOF'
[Global]
profile="openai_1"
# Experimental. Teach AI to use your personalized shell command. Use the template below and uncomment to enable:
# USER_SYSTEM_INSTRUCTION="If user requests 'say thank you to <username>' , then \"shell_command\": 'echo \"<username>, thank you very much\"' , \"shell_command_explanation\": 'pls: show thanks'."

timeout_seconds=60
max_input_length=64000
history_file="$HOME/.pls/pls_hist.log"
history_time_window_minutes=30
history_max_records=30

# Define your own AI profiles, openai and gemini for now
[openai_1]
provider="openai"
model="gpt-4o"
base_url="https://api.openai.com/v1"
env_key="OPENAI_API_KEY"

[openai_2]
provider="openai"
model="gpt-4o-mini"
base_url="https://api.openai.com/v1"
env_key="OPENAI_API_KEY"

[gemini_1]
provider="gemini"
model="gemini-2.5-flash"
base_url="https://generativelanguage.googleapis.com/v1beta"
env_key="GEMINI_API_KEY"
EOF
  fi
  # default values
  profile=""
  USER_SYSTEM_INSTRUCTION=""
  timeout_seconds=60
  max_input_length=64000
  history_file="$HOME/.pls/pls_hist.log"
  history_time_window_minutes=30
  history_max_records=30

  # No associative arrays for compatible with macOS’s system Bash
  local section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    # Section headers
    if [[ "$line" =~ ^\[(.+)\][[:space:]]*$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi

    # Key=Value
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"

      # Strip quotes
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi

      if [[ "$section" == "Global" ]]; then
        eval "$key=\"\$val\""
      else
        eval "profile__${section}__${key}=\"\$val\""
      fi
    fi
  done <"$CONFIG_FILE"

  # Expand $HOME inside history_file etc
  history_file=$(eval echo "$history_file")
  apply_profile "$profile"
}

apply_profile() {
  local p="$1"
  api_provider="$(eval echo "\$profile__${p}__provider")"
  api_model="$(eval echo "\$profile__${p}__model")"
  api_base_url="$(eval echo "\$profile__${p}__base_url")"
  api_env_key="$(eval echo "\$profile__${p}__env_key")"
  # Validate provider
  if [[ "$api_provider" != "openai" && "$api_provider" != "gemini" ]]; then
    echo "Error: Provider '$api_provider' for profile '$p' is not yet supported." >&2
    echo "$CONFIG_FILE" >&2
    exit 1
  else
    api_key="${!api_env_key}"
    if [[ -z "$api_key" ]]; then
      echo "Error: API key for '$p' not set. Please export $api_env_key"
      exit 1
    fi
  fi

  # System instruction
  case $(uname) in
  Darwin) shell_type="macOS (Bash 3 with BSD utilities)" ;;
  FreeBSD) shell_type="FreeBSD" ;;
  *) shell_type="Linux" ;;
  esac

  USER_SYSTEM_INSTRUCTION=${USER_SYSTEM_INSTRUCTION//\\\"/\"}

  SYSTEM_INSTRUCTION=${BASE_SYSTEM_INSTRUCTION//__SHELL_TYPE__/$shell_type}
  SYSTEM_INSTRUCTION=${SYSTEM_INSTRUCTION//__USER_HISTORY_FILE__/$history_file}
  SYSTEM_INSTRUCTION=${SYSTEM_INSTRUCTION//__USER_SYSTEM_INSTRUCTION__/$USER_SYSTEM_INSTRUCTION}
}

# APP FUNCTION DEFINITIONS
print_usage_and_exit() {
  cat >&2 <<EOF
pls v0.54

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
          nano ~/.pls/pls.conf             # Choose AI model and change settings
EOF
  exit "${1:-0}"
}

check_dependencies() {
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      printf 'Error: Required command '\''%s'\'' is not installed.\n' "$cmd" >&2
      printf 'Please install it and try again.\n' >&2
      exit 1
    fi
  done
}

cleanup() {
  stop_spinner
  tput cnorm
  [[ -n "$stderr_file" ]] && rm -f "$stderr_file"
}

start_spinner() {
  (
    tput civis
    tput nel
    tput nel
    tput nel
    tput nel
    tput cuu 4
    tput el
    printf '_%s %s:%s' "$GREY" "$api_model" "$RESET"
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
  ((spinner_pid)) || return
  kill "$spinner_pid" 2>/dev/null
  wait "$spinner_pid" 2>/dev/null
  spinner_pid=0
  tput cr
  tput el
  tput cnorm
} >&2

add_to_history() {
  local user_message="$1"
  local assistant_message="$2"
  local timestamp
  timestamp=$(date +'%Y-%m-%d %H:%M:%S')

  mkdir -p "$(dirname "$history_file")"
  touch "$history_file"

  jq -nc --arg user_msg "$user_message" --arg assistant_msg "$assistant_message" \
    --arg time "$timestamp" '
      [
        {timestamp: $time, role: "user", content: $user_msg},
        {timestamp: $time, role: "assistant", content: $assistant_msg}
      ][]' >>"$history_file"
}

read_from_history() {
  [[ -f "$history_file" ]] || {
    printf '[]'
    return 0
  }

  local cutoff_epoch
  cutoff_epoch=$(($(date +%s) - history_time_window_minutes * 60))
  # use tail to avoid loading big history file
  case $api_provider in
  openai)
    tail -n $((history_max_records)) "$history_file" |
      jq -s \
        --argjson cutoff_epoch "$cutoff_epoch" \
        'map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | map({role, content})'
    ;;
  gemini)
    tail -n $((history_max_records)) "$history_file" |
      jq -s \
        --argjson cutoff_epoch "$cutoff_epoch" \
        'map(select((.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) >= $cutoff_epoch))
      | map({
          "role": (if .role == "assistant" then "model" else "user" end),
          "parts": [{"text": .content}]
        })'
    ;;
  *)
    printf 'Unsupported API provider: %s\n' "$api_provider" >&2
    exit 1
    ;;
  esac
}

show_piped_input() {
  printf '>\n' >&2
  printf '%s%s%s\n' "$GREY" "${piped_input:0:250}" "$RESET" >&2
  ((${#piped_input} > 250)) &&
    printf '...\n' >&2
}

process_inputs() {
  case "$1" in
  -p)
    show_piped_input="true"
    shift
    ;;
  -h) print_usage_and_exit ;;
  -?) print_usage_and_exit 1 ;;
  esac
  [[ "$1" =~ ^- ]] && print_usage_and_exit 1

  # read both input
  [ ! -t 0 ] && piped_input="$(cat)"
  arg_input="$*"

  # process piped input
  if [[ -n "$piped_input" ]]; then
    piped_input=$(tr -d '\000-\010\013\014\016-\037\177' <<<"$piped_input")
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

call_api() {
  local payload endpoint headers

  # ---------------- Provider differences -----------------
  case $api_provider in
  openai)
    endpoint="$api_base_url/responses"
    headers=(-H "Authorization: Bearer $api_key" -H "Content-Type: application/json")
    # Structured output format for OpenAI
    local output_format
    output_format=$(jq -n '{
        type: "json_schema",
        name: "shell_helper",
        schema: {
            type: "object",
            properties: {
                shell_command_requested: {
                    type: "boolean",
                    description: "Whether the user requested to run shell command, or the user reqeust needed shell command to fulfill."
                },
                shell_command_explanation: {
                    type: "string",
                    description: "A brief plain-text explanation of the shell command."
                },
                shell_command: {
                    type: "string",
                    description: "The shell command to accomplish the task, if applicable."
                },
                chat_response: {
                    type: "string",
                    description: "A clear and helpful general answer to the user request."
                }
            },
            required: ["shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"],
            additionalProperties: false
        },
        strict: true
        }')

    payload=$(
      read_from_history | jq -n \
        --arg model "$api_model" \
        --arg sys "$SYSTEM_INSTRUCTION" \
        --slurpfile history /dev/stdin \
        --arg prompt "$user_prompt" \
        --argjson output_format "$output_format" \
        '{
          model:$model,
          input:(
            [{role:"developer",content:$sys}] +
            $history[0] +
            [{role:"user",content:$prompt}]
          ),
          text:{format:$output_format}
        }'
    )
    ;;

  gemini)
    endpoint="${api_base_url}/models/${api_model}:generateContent?key=${api_key}"
    headers=(-H "Content-Type: application/json")
    # Schema definition for Gemini
    local schema
    schema=$(jq -n '{
        "type": "OBJECT",
        "properties": {
          "shell_command_requested": {
            "type": "BOOLEAN",
            "description": "Whether the user requested to run shell command, or the user reqeust needed shell command to fulfill."
          },
          "shell_command_explanation": {
            "type": "STRING",
            "description": "A brief plain-text explanation of the shell command."
          },
          "shell_command": {
            "type": "STRING",
            "description": "The shell command to accomplish the task, if applicable."
          },
          "chat_response": {
            "type": "STRING",
            "description": "A clear and helpful general answer to the user request."
          }
        },
        "required": ["shell_command_requested", "shell_command_explanation", "shell_command", "chat_response"]
      }')
    payload=$(
      read_from_history | jq -n \
        --arg prompt "$user_prompt" \
        --arg sys "$SYSTEM_INSTRUCTION" \
        --slurpfile history /dev/stdin \
        --argjson schema "$schema" \
        '{
          system_instruction:{parts:[{text:$sys}]},
          contents:($history[0] + [{role:"user",parts:[{text:$prompt}]}]),
          generationConfig:{responseMimeType:"application/json",responseSchema:$schema}
        }'
    )
    ;;

  *)
    echo "Unsupported provider: $api_provider" >&2
    exit 1
    ;;
  esac

  # ---------------- Shared: do the request -----------------
  stderr_file=$(mktemp)
  start_spinner
  local response
  response=$(curl -s -X POST -w "\n%{http_code}" --max-time "$timeout_seconds" \
    "${headers[@]}" -d "$payload" "$endpoint" 2>"$stderr_file")
  stop_spinner

  local http_code=${response##*$'\n'}
  local http_body=${response%$'\n'*}
  local curl_stderr
  curl_stderr=$(<"$stderr_file")

  ((http_code == 200)) || {
    echo "Request failed ($http_code)"
    echo "$http_body" || echo "$curl_stderr"
    exit 1
  }

  # ---------------- Provider-specific parse -----------------
  case $api_provider in
  openai)
    local status
    status=$(jq -r '.output[]? | select(.type=="message") | .status // empty' <<<"$http_body")
    [[ $status == completed ]] || {
      echo "OpenAI response failed ($status)"
      echo "$http_body"
      exit 1
    }
    local msg
    msg=$(jq '
        .output[]?|select(.type=="message")|.content[]?|select(.type=="output_text")|.text
      ' <<<"$http_body")
    shell_command_requested=$(jq -r 'fromjson.shell_command_requested' <<<"$msg")
    shell_command_explanation=$(jq -r 'fromjson.shell_command_explanation' <<<"$msg")
    shell_command=$(jq -r 'fromjson.shell_command' <<<"$msg")
    chat_response=$(jq -r 'fromjson.chat_response' <<<"$msg")
    ;;

  gemini)
    local status
    status=$(jq -r '.candidates[0]? | .finishReason // empty' <<<"$http_body")
    [[ $status == STOP ]] || {
      echo "Gemini response failed ($status)"
      echo "$http_body"
      exit 1
    }
    local msg
    msg=$(jq '.candidates[0].content.parts[0].text' <<<"$http_body")
    shell_command_requested=$(jq -r 'fromjson.shell_command_requested' <<<"$msg")
    shell_command_explanation=$(jq -r 'fromjson.shell_command_explanation' <<<"$msg")
    shell_command=$(jq -r 'fromjson.shell_command' <<<"$msg")
    chat_response=$(jq -r 'fromjson.chat_response' <<<"$msg")
    ;;
  esac

  last_action_type="new_assistant_response"
}
# show menu under input line, supported menu_items one or more in "yeq"
conv_show_menu() {
  local menu_items="$1"
  if [[ -z "$menu_items" || -n "${menu_items//[req]/}" ]]; then
    printf 'Invalid menu items: %s\n' "$menu_items" >&2
    exit 1
  fi
  tput cud1 # move down relibalely
  tput cr
  tput el
  printf '%s( ' "$GREY"
  [[ "$menu_items" == *r* ]] && printf '%sr%sun/' "$CYAN" "$GREY"
  [[ "$menu_items" == *e* ]] && printf '%se%sdit + %s⏎%s : cmd | ' "$CYAN" "$GREY" "$CYAN" "$GREY"
  [[ "$menu_items" == *q* ]] && printf '%sq%s + %s⏎%s : quit | ' "$CYAN" "$GREY" "$CYAN" "$GREY"
  printf '%stype: chat )%s' "$GREY" "$RESET"
  if [[ "$was_input_truncated" == "true" ]]; then
    printf 'Note: this response is generated on a truncated input' >&2
  fi
  tput cuu1
  tput cr
  tput el
}

# single handler for all states
conv_show_output() {
  case "$last_action_type" in
  cmd_new_response)
    add_to_history "$user_prompt" "suggested shell cmd:\"$shell_command\""
    printf '\n- %s%s%s\n\n' "$GREY" "$shell_command_explanation" "$RESET"
    tput el
    printf '%scmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
    printf '%s%s%s\n' "$YELLOW" "$shell_command" "$RESET"
    tput el
    conv_show_menu "req"
    ;;
  cmd_edited)
    tput cuu 2
    tput el
    printf '%supdated cmd:%s>%s\n' "$GREY" "$GREEN" "$RESET"
    tput el
    printf '%s%s%s\n' "$YELLOW" "$shell_command" "$RESET"
    tput el
    conv_show_menu "req"
    ;;
  cmd_executed)
    conv_show_menu "eq"
    ;;
  chat_new_response)
    add_to_history "$user_prompt" "$chat_response"
    if command -v glow >/dev/null 2>&1; then
      echo "$chat_response" | glow - -w "$(tput cols)"
    else
      printf '\n%s\n\n' "$chat_response"
    fi
    conv_show_menu "q"
    ;;
  empty_user_prompt)
    printf '\n  Hi!\n\n'
    conv_show_menu "q"
    last_action_type="chat_new_response"
    ;;
  *)
    printf 'Menu Error - %s\n' "$last_action_type" >&2
    exit 1
    ;;
  esac
}
# Define user input transitions based on [state:input_pattern]
conv_handle_user_input() {
  case "$1:$2" in
  cmd_new_response:[Rr] | cmd_edited:[Rr])
    conv_run_shell_command
    last_action_type="cmd_executed"
    ;;
  cmd_new_response:[Ee] | cmd_edited:[Ee] | cmd_executed:[Ee])
    conv_edit_shell_command
    last_action_type="cmd_edited"
    ;;
  *:[Qq] | *:)
    tput el
    printf '%sbye%s\n' "$GREY" "$RESET"
    return 1
    ;;
  *:?*)
    last_action_type="new_user_prompt"
    ;;
  *)
    printf 'Menu Error (input dispatch)\n' >&2
    exit 1
    ;;
  esac
  return 0
}

# Helpers
conv_run_shell_command() {
  echo "$shell_command" >>~/.bash_history
  tput el
  if eval "$shell_command"; then
    tput el
    printf '%sCommand succeeded%s\n' "$GREY" "$RESET"
    add_to_history "Command succeeded: \"$shell_command\"" "Ok"
  else
    tput el
    printf '%sCommand failed%s\n' "$GREY" "$RESET"
    add_to_history "Command failed: \"$shell_command\"" "Sorry"
  fi
}

conv_edit_shell_command() {
  tput cuu1
  tput cr
  tput el
  printf '%sedit:%s>%s' "$GREY" "$GREEN" "$RESET"
  tput nel
  tput el
  tput nel
  tput el
  printf '%s( type + %s⏎%s : finish edit )%s' "$GREY" "$CYAN" "$GREY" "$RESET"
  tput cr
  tput cuu1
  tput el

  single_line_shell_command=$(echo "$shell_command" | sed 's/\\$//' | tr -d '\n')

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS zsh safe input
    GREEN_ZSH="%{$GREEN%}"
    RESET_ZSH="%{$RESET%}"
    encoded_command=$(printf '%s' "$single_line_shell_command" | base64)
    shell_command=$(zsh -c "
        shell_command=\$(echo '$encoded_command' | base64 -d)
        vared -p '${GREEN_ZSH}>>${RESET_ZSH}' -c shell_command
        echo \"\$shell_command\"")
  else
    read -e -r -p "${GREEN_PROMPT}>>${RESET_PROMPT}" \
      -i "$single_line_shell_command" shell_command </dev/tty
  fi
  shell_command=${shell_command:-$single_line_shell_command}
}

# main loop
conv_main_loop() {
  while true; do
    # Normalize "new_assistant_response"
    [[ "$last_action_type" == "new_assistant_response" ]] &&
      last_action_type=$([[ "$shell_command_requested" == "true" ]] &&
        echo "cmd_new_response" || echo "chat_new_response")

    # show output
    conv_show_output

    # read user input
    if ! read -e -r -p "${GREEN_PROMPT}>>${RESET_PROMPT}" user_input </dev/tty; then
      break
    fi

    # handle user input
    if ! conv_handle_user_input "$last_action_type" "$user_input"; then
      break
    fi

    # handle api call
    if [[ "$last_action_type" == "new_user_prompt" ]]; then
      arg_input="$user_input"
      piped_input=""
      was_input_truncated="false"
      build_prompt
      call_api
    fi
  done
}

# If not interactive, output only the major response in plain text
single_time_output() {
  if [[ "$last_action_type" == "new_assistant_response" ]]; then
    if [[ "$shell_command_requested" == "true" ]]; then
      printf '%s\n' "$shell_command"
    else
      printf '%s\n' "$chat_response"
    fi
    if [[ "$was_input_truncated" == "true" ]]; then
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
  tput init
  # Enter continuous conversation mode if using interative shell
  if [[ -t 1 ]]; then
    if [[ "$last_action_type" == "new_user_prompt" ]]; then
      call_api
    fi
    conv_main_loop
  else # Piped output
    call_api
    single_time_output
  fi
}

# EXECUTION STARTS HERE
trap cleanup EXIT
main "$@"
