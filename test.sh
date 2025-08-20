# Define colors without delimiters
readonly GREEN=$'\033[32m'
readonly GREY=$'\033[90m'
readonly CYAN=$'\033[36m'
readonly RESET=$'\033[0m'

# Create wrapped versions specifically for readline prompts
readonly GREEN_PROMPT=$'\001'"${GREEN}"$'\002'
readonly RESET_PROMPT=$'\001'"${RESET}"$'\002'

if ! read -e -r -p "${GREEN_PROMPT}>>${RESET_PROMPT}" user_input </dev/tty; then
  break
fi