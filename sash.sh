# Countdown Timer Function
# ------------------------
# Usage: countdown <time>
#
# Displays a live countdown in HH:MM:SS format.
# Accepts total seconds (e.g., 90), or flexible time strings like:
#   countdown 1h30m     # 1 hour 30 minutes
#   countdown 5m45s     # 5 minutes 45 seconds
#   countdown 120       # 120 seconds
#
# If no argument is given or input is invalid, usage instructions are shown.
countdown() {
  if [ -z "$1" ]; then
    echo "Usage: countdown <time>"
    echo "Examples: countdown 90         # 90 seconds"
    echo "          countdown 1h30m      # 1 hour 30 minutes"
    echo "          countdown 1h30m19s   # 1 hour 30 minutes 19 seconds"
    echo "          countdown 5m45s      # 5 minutes 45 seconds"
    echo "          countdown 45s        # 45 seconds"
    return 1
  fi

  local input="$1"
  local total_seconds=0

  echo ""
  # Extract hours
  local hours=$(echo "$input" | grep -oE '[0-9]+h' | sed 's/h//')
  if echo "$input" | grep -q '[0-9]\+h'; then
    # echo $hours hours
    total_seconds=$((total_seconds + hours * 3600))
  fi

  # Extract minutes
  local minutes=$(echo "$input" | grep -oE '[0-9]+m' | sed 's/m//')
  if echo "$input" | grep -q '[0-9]\+m'; then
    # echo $minutes minutes
    total_seconds=$((total_seconds + minutes * 60))
  fi

  # Extract seconds
  local seconds=$(echo "$input" | grep -oE '[0-9]+s' | sed 's/s//')
  if echo "$input" | grep -q '[0-9]\+s'; then
    # echo $seconds seconds
    total_seconds=$((total_seconds + seconds))
  fi

  # Pure number input (seconds)
  if echo "$input" | grep -Eq '^[0-9]+$'; then
      total_seconds=$((total_seconds + input))
  fi

  if [ "$total_seconds" -le 0 ]; then
      echo "Invalid time format."
      return 1
  fi

  local end=$(( $(date +%s) + total_seconds ))
  while [ $end -ge $(date +%s) ]; do
      local remaining=$(( end - $(date +%s) ))
      local h=$(( remaining / 3600 ))
      local m=$(( (remaining % 3600) / 60 ))
      local s=$(( remaining % 60 ))
      printf "\r%02d:%02d:%02d" "$h" "$m" "$s"
      sleep 1
  done
  echo
}
