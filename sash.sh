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
        echo "Examples: countdown 90      # 90 seconds"
        echo "          countdown 1h30m   # 1 hour 30 minutes"
        echo "          countdown 45s     # 45 seconds"
        return 1
    fi

    # Convert input to seconds
    local total_seconds
    total_seconds=$(echo "$1" | awk '
        BEGIN { s = 0 }
        match($0, /([0-9]+)h/, a) { s += a[1] * 3600 }
        match($0, /([0-9]+)m/, a) { s += a[1] * 60 }
        match($0, /([0-9]+)s/, a) { s += a[1] }
        /^[0-9]+$/ { s += $0 }
        END { print s }
    ')

    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || [ "$total_seconds" -le 0 ]; then
        echo "Invalid time format."
        return 1
    fi

    local end=$(( $(date +%s) + total_seconds ))
    while [ $end -ge $(date +%s) ]; do
        remaining=$(( end - $(date +%s) ))
        printf '%s\r' "$(date -u -d "@$remaining" +%H:%M:%S)"
        sleep 0.1
    done
    echo
}
