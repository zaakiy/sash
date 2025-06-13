## sash.sh - A collection of shell functions for various tasks
##         - Super Awesome SHell

countdown() {
    if [ -z "$1" ]; then
        echo "Usage: countdown <time>"
        echo "Examples: countdown 90      # 90 seconds"
        echo "          countdown 1h30m   # 1 hour 30 minutes"
        echo "          countdown 45s     # 45 seconds"
        return 1
    fi

    local input="$1"
    local total_seconds=0

    # Extract hours
    local hours=$(echo "$input" | sed -E 's/.*([0-9]+)h.*/\1/')
    if echo "$input" | grep -q '[0-9]\+h'; then
        total_seconds=$((total_seconds + hours * 3600))
    fi

    # Extract minutes
    local minutes=$(echo "$input" | sed -E 's/.*([0-9]+)m.*/\1/')
    if echo "$input" | grep -q '[0-9]\+m'; then
        total_seconds=$((total_seconds + minutes * 60))
    fi

    # Extract seconds
    local seconds=$(echo "$input" | sed -E 's/.*([0-9]+)s.*/\1/')
    if echo "$input" | grep -q '[0-9]\+s'; then
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
