# Source countdown timer function
# Resolve symlinks to get the real script location
SCRIPT_PATH="${BASH_SOURCE[0]}"
echo "DEBUG: Initial BASH_SOURCE[0] = ${SCRIPT_PATH}"

# Resolve symlinks (works on both Linux and macOS)
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    # If readlink returns a relative path, make it absolute
    [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
    echo "DEBUG: Resolved symlink to: ${SCRIPT_PATH}"
done

SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
echo "DEBUG: Final SCRIPT_DIR = ${SCRIPT_DIR}"
echo "DEBUG: Looking for countdown.sh at: ${SCRIPT_DIR}/countdown.sh"
ls -la "${SCRIPT_DIR}/countdown.sh" 2>&1 || echo "DEBUG: File not found!"

source "${SCRIPT_DIR}/countdown.sh"
