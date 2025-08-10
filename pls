#!/bin/bash

config_file="$HOME/.config/pls/pls.conf"

# create config file if first run
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

# load config
source "$config_file"

# System instruction
system_instruction="
If user requests a shell command, provide a very brief plain-text explanation as shell_command_explanation and generate a valid shell command using $(uname) based on user input as shell_command. If the command is risky like deletes data, shuts down system, kills critical services, cuts network then make sure to prefix it with '# ' to prevent execution. Prefer a single command; Use \ for line continuation on long commands. Use sudo if likely required. If no shell command requested, answer concisely and directly as other_response, prefer under 60 words, use Markdown. If asked for a fact or result, answer with only the exact value or fact in plain text. Do not include extra words, explanations, or complete sentences.
"
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
pls v0.3
Usage:    pls [-t] [messages...]                  # Chat and generate shell commands if requested
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

}

# Call OpenAI API with prompt and history
call_api() {
  history_messages=$(read_from_history)
  # openai structured output
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
            other_response: {
                type: "string",
                description: "A clear and helpful general answer to the user request, if not about shell command"
            }
        },
        required: ["shell_command_requested","shell_command","shell_command_explanation","other_response"],
        additionalProperties: false
    },
    strict: true
    }')

  json_payload=$(jq -n \
    --arg model "$model" \
    --arg sys "$system_instruction" \
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

  # Use a temp file for stderr to make signal handling robust
  stderr_file=$(mktemp)
  
  start_spinner
  response=$(curl -s -w "\n%{http_code}" --max-time "$timeout_seconds" "$base_url/responses" \
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
  else 
    api_out_status=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .status')
    if [ "$api_out_status" != "completed" ]; then
        echo "Response failed ($api_out_status)" >&2
        [[ -n "$http_body" ]] && echo "$http_body" >&2
        exit 1
    fi
  fi
  # jq 4 times is not optimal but to use read is just unreliable...
  shell_command_requested=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command_requested')
  shell_command_explanation=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command_explanation')
  shell_command=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .shell_command')
  other_response=$(echo "$http_body" | jq -r '.output[] | select(.type=="message") | .content[].text | fromjson | .other_response')
}

# Handle response for chat and bash mode
handle_output() {
  #echo "Shell: $shell_command_requested"
  if [ "$shell_command_requested" == "true" ]; then
      add_to_history "$user_prompt" "suggested shell cmd:\"$shell_command\""

      echo -e "${grey}$shell_command_explanation${reset}" >&2

      while true; do
        if [ -t 1 ]; then
            echo -e "${grey}cmd:${green}>${reset}" >&2
            echo "$shell_command"
        else
            { echo "$shell_command" >&2; echo "$shell_command"; }
        fi

        echo -e "${grey}Press ${reset}Y${grey} to run. ${reset}E${grey} to edit. Other key cancels.${reset}" >&2
        read -s -n 1 -r response </dev/tty

        case "$response" in
          [Yy])
            echo "$shell_command" >> ~/.bash_history
            eval "$shell_command" 1>&2
            exit 0
            ;;
          [Ee])
            echo -ne "\033[A\033[2K"
            echo -e "${grey}edit:${green}>${reset}" >&2
            read -e -i "$shell_command" -p "" shell_command </dev/tty
            ;;
          *)
            echo -e "${grey}Command execution cancelled.${reset}" >&2
            exit 0
            ;;
        esac
      done

  else # not about shell command, normal chat
      add_to_history "$user_prompt" "$other_response"

      if [ -t 1 ]; then
          command -v glow >/dev/null 2>&1 && { echo "$other_response" | glow - -w "$(tput cols)"; }  || echo "$other_response"
      else
          echo -e "$(display_truncated "$other_response")" >&2
          echo "$other_response"
      fi
  fi 
  [[ $was_truncated -eq 1 ]] && echo -e "${grey}(Truncated input - answer could be wrong or incomplete)${reset}" >&2
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

[[ -z "$OPENAI_API_KEY" ]] && { echo "OPENAI_API_KEY not set" >&2; exit 1; }
process_inputs "$@"
build_prompt
call_api
handle_output
