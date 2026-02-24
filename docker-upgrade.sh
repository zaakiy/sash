#!/usr/bin/env bash
# docker-upgrade.sh - Interactive Docker container upgrade tool
# Handles both standalone containers and docker-compose managed containers
# Cross-platform: Linux (bash) and macOS (bash 4+ or zsh)

# ============================================================
# SHELL DETECTION & RE-EXEC LAYER
# ============================================================

if [ -n "$BASH_VERSION" ]; then
    CURRENT_SHELL="bash"
    BASH_MAJOR="${BASH_VERSINFO[0]}"
elif [ -n "$ZSH_VERSION" ]; then
    CURRENT_SHELL="zsh"
    BASH_MAJOR=0
else
    CURRENT_SHELL="unknown"
    BASH_MAJOR=0
fi

# If we're in bash < 4 (stock macOS bash), re-exec under zsh
if [ "$CURRENT_SHELL" = "bash" ] && [ "$BASH_MAJOR" -lt 4 ]; then
    if command -v zsh >/dev/null 2>&1; then
        echo "Bash $BASH_VERSION detected (no associative array support)."
        echo "Re-launching under zsh..."
        exec zsh "$0" "$@"
    else
        echo "ERROR: Bash $BASH_VERSION is too old and zsh is not available."
        echo "Please install bash 4+ or zsh."
        exit 1
    fi
fi

# ============================================================
# ZSH COMPATIBILITY LAYER
# ============================================================
# When running under zsh, we need different syntax for:
#   1. Array index iteration  (bash: ${!arr[@]}  vs  zsh: ${(k)arr} )
#   2. Associative array declaration scope
#   3. Regex match captures   (bash: BASH_REMATCH  vs  zsh: match)
#   4. Redirect shorthand     (bash: &>/dev/null   vs  zsh: varies)
#
# Strategy: define helper functions that abstract the differences.
# ============================================================

if [ "$CURRENT_SHELL" = "zsh" ]; then
    emulate -L zsh
    setopt KSH_ARRAYS       # 0-indexed arrays
    setopt NO_NOMATCH       # Don't error on failed globs
    setopt PIPE_FAIL        # Catch pipe failures
    setopt REMATCH_PCRE     # Use PCRE for =~ matching

    # --- Get indices of an indexed array ---
    # bash:  ${!arr[@]}   →   0 1 2 3 ...
    # zsh:   ${(k)arr[@]} doesn't work with KSH_ARRAYS for indexed arrays
    # Solution: generate index sequence from length
    array_indices() {
        local arr_name=$1
        local len
        eval "len=\${#${arr_name}[@]}"
        local i=0
        while [ $i -lt $len ]; do
            echo $i
            i=$((i + 1))
        done
    }

    # --- Get length of an indexed array ---
    array_length() {
        local arr_name=$1
        eval "echo \${#${arr_name}[@]}"
    }

    # --- Regex match with capture groups ---
    # zsh with REMATCH_PCRE populates $MATCH and $match (array)
    # We normalize to BASH_REMATCH-style access
    regex_match() {
        local string="$1"
        local pattern="$2"
        if [[ "$string" =~ $pattern ]]; then
            # zsh puts captures in $match array (1-indexed natively,
            # but KSH_ARRAYS makes it 0-indexed)
            BASH_REMATCH=("$MATCH" "${match[@]}")
            return 0
        fi
        return 1
    }

else
    # --- Bash versions of the same helpers ---
    array_indices() {
        local arr_name=$1
        eval "echo \${!${arr_name}[@]}"
    }

    array_length() {
        local arr_name=$1
        eval "echo \${#${arr_name}[@]}"
    }

    regex_match() {
        local string="$1"
        local pattern="$2"
        if [[ "$string" =~ $pattern ]]; then
            return 0
        fi
        return 1
    }
fi

set -e  # Exit on error

# ============================================================
# PLATFORM DETECTION
# ============================================================
detect_platform() {
    PLATFORM_OS="$(uname -s)"
    PLATFORM_ARCH="$(uname -m)"

    case "$PLATFORM_OS" in
        Darwin*)  PLATFORM="macos"   ;;
        Linux*)   PLATFORM="linux"   ;;
        FreeBSD*) PLATFORM="freebsd" ;;
        *)        PLATFORM="unknown" ;;
    esac

    export PLATFORM PLATFORM_OS PLATFORM_ARCH
}

detect_platform

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================
# CROSS-PLATFORM WRAPPER FUNCTIONS
# ============================================================

portable_stat_mtime() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "0"
        return 1
    fi
    case "$PLATFORM" in
        macos|freebsd) stat -f %m "$file" 2>/dev/null ;;
        linux)         stat -c %Y "$file" 2>/dev/null ;;
        *)             stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || { echo "0"; return 1; } ;;
    esac
}

portable_timeout() {
    local duration="$1"
    shift

    case "$PLATFORM" in
        linux)
            timeout "$duration" "$@"
            ;;
        macos|freebsd)
            if command -v gtimeout >/dev/null 2>&1; then
                gtimeout "$duration" "$@"
            elif command -v timeout >/dev/null 2>&1; then
                timeout "$duration" "$@"
            elif command -v perl >/dev/null 2>&1; then
                perl -e '
                    use POSIX ":sys_wait_h";
                    my $timeout = shift @ARGV;
                    my $pid = fork();
                    if ($pid == 0) { exec @ARGV or die "exec: $!"; }
                    eval {
                        local $SIG{ALRM} = sub { kill("TERM", $pid); die "alarm\n"; };
                        alarm $timeout;
                        waitpid($pid, 0);
                        alarm 0;
                    };
                    if ($@ && $@ eq "alarm\n") {
                        sleep 1;
                        kill("KILL", $pid) if kill(0, $pid);
                        exit 124;
                    }
                    exit ($? >> 8);
                ' "$duration" "$@"
            else
                echo -e "${YELLOW}⚠️  No timeout available — running without${NC}" >&2
                "$@"
            fi
            ;;
        *)
            if command -v timeout >/dev/null 2>&1; then
                timeout "$duration" "$@"
            else
                "$@"
            fi
            ;;
    esac
}

portable_wc_l() {
    wc -l | tr -d '[:space:]'
}

portable_epoch() {
    date +%s 2>/dev/null \
        || python3 -c 'import time; print(int(time.time()))' 2>/dev/null \
        || perl -e 'print time' 2>/dev/null \
        || { echo "0"; return 1; }
}

portable_sed_inplace() {
    local expression="$1"
    local file="$2"
    case "$PLATFORM" in
        macos|freebsd) sed -i '' "$expression" "$file" ;;
        linux)         sed -i "$expression" "$file" ;;
        *)             sed -i "$expression" "$file" 2>/dev/null || sed -i '' "$expression" "$file" ;;
    esac
}

portable_tput_clear_lines() {
    local count="$1"
    local i
    for ((i = 0; i < count; i++)); do
        tput cuu1 2>/dev/null && tput el 2>/dev/null || true
    done
}

# ============================================================
# DEPENDENCY CHECK
# ============================================================
check_platform_dependencies() {
    echo -e "${BLUE}=== Platform & Dependency Check ===${NC}"
    echo "  OS:    $PLATFORM ($PLATFORM_OS $PLATFORM_ARCH)"
    echo "  Shell: $CURRENT_SHELL ${ZSH_VERSION}${BASH_VERSION}"

    if [ "$PLATFORM" = "macos" ]; then
        local macos_ver
        macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
        echo "  macOS: $macos_ver"
    fi
    echo ""

    local has_missing=false

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} docker (REQUIRED)"
        has_missing=true
    else
        echo -e "  ${GREEN}✓${NC} docker"
    fi

    if ! command -v skopeo >/dev/null 2>&1; then
        echo -ne "  ${YELLOW}○${NC} skopeo (optional — needed for update checks)"
        case "$PLATFORM" in
            macos) echo "  →  brew install skopeo" ;;
            linux) echo "  →  sudo apt-get install skopeo" ;;
            *)     echo "" ;;
        esac
    else
        echo -e "  ${GREEN}✓${NC} skopeo"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -ne "  ${YELLOW}○${NC} jq (optional — needed for update checks)"
        case "$PLATFORM" in
            macos) echo "  →  brew install jq" ;;
            linux) echo "  →  sudo apt-get install jq" ;;
            *)     echo "" ;;
        esac
    else
        echo -e "  ${GREEN}✓${NC} jq"
    fi

    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        echo -ne "  ${YELLOW}○${NC} timeout (optional — perl fallback available)"
        if [ "$PLATFORM" = "macos" ]; then
            echo "  →  brew install coreutils"
        else
            echo ""
        fi
    else
        echo -e "  ${GREEN}✓${NC} timeout"
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker compose (plugin)"
    else
        echo -e "  ${YELLOW}○${NC} docker-compose (needed for compose projects)"
    fi

    echo ""

    if [ "$has_missing" = true ]; then
        echo -e "${RED}❌ Missing required dependencies. Exiting.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ All required dependencies satisfied${NC}"
    echo ""
}

check_platform_dependencies

# ============================================================
# CACHE CONFIGURATION
# ============================================================
CACHE_DIR="/tmp/docker-upgrade-cache-$$"
CACHE_VALIDITY_SECONDS=300
mkdir -p "$CACHE_DIR"

get_cache_file() {
    local image=$1
    local safe_name=$(echo "$image" | sed 's/[^a-zA-Z0-9._-]/_/g')
    echo "$CACHE_DIR/$safe_name.cache"
}

is_cache_valid() {
    local cache_file=$1

    if [ ! -f "$cache_file" ]; then
        return 1
    fi

    local cache_time
    cache_time=$(portable_stat_mtime "$cache_file")
    local current_time
    current_time=$(portable_epoch)
    local age=$((current_time - cache_time))

    if [ $age -lt $CACHE_VALIDITY_SECONDS ]; then
        return 0
    else
        return 1
    fi
}

read_cache() {
    local cache_file=$1
    if [ -f "$cache_file" ]; then
        cat "$cache_file"
    fi
}

write_cache() {
    local cache_file=$1
    local result=$2
    echo "$result" > "$cache_file"
}

# ============================================================
# MAIN SCRIPT START
# ============================================================
echo -e "${BLUE}=== Docker Container Upgrade Tool ===${NC}"
echo ""

ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")

if [ -z "$ALL_CONTAINERS" ]; then
    echo "No Docker containers found"
    exit 0
fi

declare -a ITEM_ARRAY
declare -a ITEM_TYPE_ARRAY
declare -a UPDATE_AVAILABLE_ARRAY
declare -a UPDATE_COUNT_ARRAY
declare -a RECENTLY_UPGRADED_ARRAY
declare -A COMPOSE_PROJECTS
declare -A COMPOSE_DIRS
declare -A COMPOSE_FILES

check_docker_auth() {
    local registry=${1:-"docker.io"}

    if docker system info 2>/dev/null | grep -q "Username:"; then
        return 0
    fi

    if portable_timeout 10 skopeo inspect --command-timeout 10s "docker://${registry}/library/alpine:latest" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

prompt_docker_login() {
    echo ""
    echo -e "${YELLOW}⚠️  Docker Registry Authentication${NC}"
    echo ""
    echo "To avoid rate limiting and timeouts, it's recommended to authenticate with Docker registries."
    echo ""
    echo "Docker Hub (docker.io) limits anonymous requests to 100 pulls per 6 hours."
    echo "Authenticated users get 200 pulls per 6 hours (free tier) or unlimited (paid)."
    echo ""
    read "REPLY?Would you like to log in to Docker Hub now? (y/n) "

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${BLUE}=== Logging in to Docker Hub ===${NC}"
        echo ""

        if docker login; then
            echo ""
            echo -e "${GREEN}✓ Successfully logged in to Docker Hub${NC}"
            return 0
        else
            echo ""
            echo -e "${RED}❌ Login failed${NC}"
            return 1
        fi
    else
        echo ""
        echo -e "${YELLOW}Continuing without authentication (may experience rate limiting)${NC}"
        return 1
    fi
}

check_update_available() {
    local image=$1
    local tmout=${SKOPEO_TIMEOUT:-30}
    local max_retries=${SKOPEO_RETRIES:-3}

    local cache_file=$(get_cache_file "$image")
    if is_cache_valid "$cache_file"; then
        local cached_result=$(read_cache "$cache_file")
        return $cached_result
    fi

    local local_digest=$(docker inspect --type=image --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | cut -d'@' -f2)

    if [ -z "$local_digest" ]; then
        write_cache "$cache_file" 2
        return 2
    fi

    local remote_digest=""
    local retry=0

    while [ $retry -le $max_retries ]; do
        if [ $retry -gt 0 ]; then
            echo -n "(retry $retry/$max_retries) "
        fi

        remote_digest=$(portable_timeout $((tmout)) skopeo inspect --command-timeout ${tmout}s docker://"$image" 2>/dev/null | jq -r '.Digest' 2>/dev/null)

        if [ -n "$remote_digest" ] && [ "$remote_digest" != "null" ]; then
            break
        fi

        retry=$((retry + 1))
    done

    if [ -z "$remote_digest" ] || [ "$remote_digest" = "null" ]; then
        write_cache "$cache_file" 2
        return 2
    fi

    if [ "$local_digest" != "$remote_digest" ]; then
        write_cache "$cache_file" 0
        return 0
    else
        write_cache "$cache_file" 1
        return 1
    fi
}

check_update_async() {
    local image=$1

    local cache_file=$(get_cache_file "$image")
    if is_cache_valid "$cache_file"; then
        return
    fi

    (SKOPEO_TIMEOUT=5 SKOPEO_RETRIES=1 check_update_available "$image" >/dev/null 2>&1) &
}

# ============================================================
# scan_containers — uses array_indices() helper
# ============================================================
scan_containers() {
    declare -A OLD_UPDATE_STATUS
    declare -A OLD_UPGRADED_STATUS

    local i
    for i in $(array_indices ITEM_ARRAY); do
        OLD_UPDATE_STATUS["${ITEM_ARRAY[$i]}"]="${UPDATE_AVAILABLE_ARRAY[$i]}"
        OLD_UPGRADED_STATUS["${ITEM_ARRAY[$i]}"]="${RECENTLY_UPGRADED_ARRAY[$i]}"
    done

    ITEM_ARRAY=()
    ITEM_TYPE_ARRAY=()
    UPDATE_AVAILABLE_ARRAY=()
    UPDATE_COUNT_ARRAY=()
    RECENTLY_UPGRADED_ARRAY=()
    COMPOSE_PROJECTS=()

    echo "Scanning containers..."

    ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")

    while IFS= read -r container; do
        COMPOSE_PROJECT=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || echo "")

        if [ -n "$COMPOSE_PROJECT" ]; then
            if [ -z "${COMPOSE_PROJECTS[$COMPOSE_PROJECT]}" ]; then
                COMPOSE_PROJECTS[$COMPOSE_PROJECT]=1
                ITEM_ARRAY+=("$COMPOSE_PROJECT")
                ITEM_TYPE_ARRAY+=("compose:$COMPOSE_PROJECT")

                if [ -n "${OLD_UPDATE_STATUS[$COMPOSE_PROJECT]}" ]; then
                    UPDATE_AVAILABLE_ARRAY+=("${OLD_UPDATE_STATUS[$COMPOSE_PROJECT]}")
                else
                    UPDATE_AVAILABLE_ARRAY+=("unknown")
                fi

                if [ -n "${OLD_UPGRADED_STATUS[$COMPOSE_PROJECT]}" ]; then
                    RECENTLY_UPGRADED_ARRAY+=("${OLD_UPGRADED_STATUS[$COMPOSE_PROJECT]}")
                else
                    RECENTLY_UPGRADED_ARRAY+=("no")
                fi

                COMPOSE_DIRS[$COMPOSE_PROJECT]=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container")
                COMPOSE_FILES[$COMPOSE_PROJECT]=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container")
            fi
        else
            ITEM_ARRAY+=("$container")
            ITEM_TYPE_ARRAY+=("standalone")

            if [ -n "${OLD_UPDATE_STATUS[$container]}" ]; then
                UPDATE_AVAILABLE_ARRAY+=("${OLD_UPDATE_STATUS[$container]}")
            else
                UPDATE_AVAILABLE_ARRAY+=("unknown")
            fi

            if [ -n "${OLD_UPGRADED_STATUS[$container]}" ]; then
                RECENTLY_UPGRADED_ARRAY+=("${OLD_UPGRADED_STATUS[$container]}")
            else
                RECENTLY_UPGRADED_ARRAY+=("no")
            fi
        fi
    done <<< "$ALL_CONTAINERS"
}

scan_containers

# ============================================================
# start_async_checks — uses array_indices()
# ============================================================
start_async_checks() {
    if ! command -v skopeo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        return
    fi

    local i
    for i in $(array_indices ITEM_ARRAY); do
        ITEM="${ITEM_ARRAY[$i]}"
        ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

        if [[ "$ITEM_TYPE" == "compose:"* ]]; then
            PROJECT_NAME="${ITEM_TYPE#compose:}"
            IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

            while IFS= read -r image; do
                if [ -n "$image" ]; then
                    check_update_async "$image"
                fi
            done <<< "$IMAGES"
        else
            CONTAINER="$ITEM"
            IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
            if [ -n "$IMAGE" ]; then
                check_update_async "$IMAGE"
            fi
        fi
    done
}

if command -v skopeo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "Starting background update checks..."
    start_async_checks
    echo ""
fi

# ============================================================
# display_table — uses array_indices(), array_length(), regex_match()
# ============================================================
display_table() {
    echo "Available containers to upgrade:"
    echo ""

    printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
        "No." "Name" "Image" "Status" "Type" "Update"

    printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
        "----" "-----------------------------------" "--------------------------------------------------" "------------" "-----------------------------------" "--------------------"

    local i
    for i in $(array_indices ITEM_ARRAY); do
        ITEM="${ITEM_ARRAY[$i]}"
        ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

        if [[ "$ITEM_TYPE" == "compose:"* ]]; then
            PROJECT_NAME="${ITEM_TYPE#compose:}"

            CONTAINER_COUNT=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Names}}" | portable_wc_l)

            FIRST_CONTAINER=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Names}}" | head -n 1)

            if [ -n "$FIRST_CONTAINER" ]; then
                STATUS=$(docker inspect --format='{{.State.Status}}' "$FIRST_CONTAINER")

                IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u | head -n 2 | tr '\n' ', ' | sed 's/,$//')

                DISPLAY_NAME="$PROJECT_NAME"
                if [ ${#DISPLAY_NAME} -gt 33 ]; then
                    DISPLAY_NAME="${DISPLAY_NAME:0:30}..."
                fi

                DISPLAY_IMAGE="$IMAGES"
                if [ $CONTAINER_COUNT -gt 2 ]; then
                    DISPLAY_IMAGE="$DISPLAY_IMAGE..."
                fi
                if [ ${#DISPLAY_IMAGE} -gt 48 ]; then
                    DISPLAY_IMAGE="${DISPLAY_IMAGE:0:45}..."
                fi

                TYPE_STR="📦 Compose ($CONTAINER_COUNT services)"
                if [ ${#TYPE_STR} -gt 33 ]; then
                    TYPE_STR="📦 Compose ($CONTAINER_COUNT svc)"
                fi
                TYPE_COLOR="${CYAN}"
            else
                continue
            fi
        else
            CONTAINER="$ITEM"
            IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")
            STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER")

            DISPLAY_NAME="$CONTAINER"
            if [ ${#DISPLAY_NAME} -gt 33 ]; then
                DISPLAY_NAME="${DISPLAY_NAME:0:30}..."
            fi

            DISPLAY_IMAGE="$IMAGE"
            if [ ${#DISPLAY_IMAGE} -gt 48 ]; then
                DISPLAY_IMAGE="${DISPLAY_IMAGE:0:45}..."
            fi

            TYPE_STR="🐳 Standalone"
            TYPE_COLOR="${PURPLE}"
        fi

        UPDATE_STATUS="${UPDATE_AVAILABLE_ARRAY[$i]}"
        UPGRADED_STATUS="${RECENTLY_UPGRADED_ARRAY[$i]}"
        UPDATE_COUNT="${UPDATE_COUNT_ARRAY[$i]}"

        if [ "$UPGRADED_STATUS" = "yes" ]; then
            UPDATE_STR="  🔄 Just upgraded"
            UPDATE_COLOR="${BLUE}"
        elif [ "$UPDATE_STATUS" = "yes" ]; then
            if [ -n "$UPDATE_COUNT" ]; then
                UPDATE_STR="  ⬆ $UPDATE_COUNT need update"
            else
                UPDATE_STR="  ⬆ Available"
            fi
            UPDATE_COLOR="${YELLOW}"
        elif [ "$UPDATE_STATUS" = "no" ]; then
            if [ -n "$UPDATE_COUNT" ]; then
                # ★ Uses regex_match() helper instead of bare [[ =~ ]]
                if regex_match "$UPDATE_COUNT" '^([0-9]+)/([0-9]+)$'; then
                    NEEDS_UPDATE="${BASH_REMATCH[1]}"
                    TOTAL="${BASH_REMATCH[2]}"
                    UP_TO_DATE=$((TOTAL - NEEDS_UPDATE))
                    UPDATE_STR="  ✓ $UP_TO_DATE/$TOTAL up to date"
                else
                    UPDATE_STR="  ✓ $UPDATE_COUNT up to date"
                fi
            else
                UPDATE_STR="  ✓ Current"
            fi
            UPDATE_COLOR="${GREEN}"
        else
            if [ -n "$UPDATE_COUNT" ]; then
                UPDATE_STR="  ... $UPDATE_COUNT"
            else
                UPDATE_STR="  ..."
            fi
            UPDATE_COLOR="${NC}"
        fi

        NUM_COL="$((i+1))"
        printf "%-4s  " "$NUM_COL"
        printf "${TYPE_COLOR}%-35s${NC}  " "$DISPLAY_NAME"
        printf "%-50s  " "$DISPLAY_IMAGE"
        printf "%-12s  " "$STATUS"
        printf "${TYPE_COLOR}%-35s${NC}  " "$TYPE_STR"
        printf "${UPDATE_COLOR}%-20s${NC}\n" "$UPDATE_STR"
    done
}

# ============================================================
# reload_cache_status — uses array_indices()
# ============================================================
reload_cache_status() {
    local i
    for i in $(array_indices ITEM_ARRAY); do
        ITEM="${ITEM_ARRAY[$i]}"
        ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

        if [[ "$ITEM_TYPE" == "compose:"* ]]; then
            PROJECT_NAME="${ITEM_TYPE#compose:}"
            IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

            HAS_UPDATE=false
            HAS_CACHED_DATA=false
            UPDATE_COUNT=0
            TOTAL_COUNT=0

            while IFS= read -r image; do
                if [ -z "$image" ]; then continue; fi
                cache_file=$(get_cache_file "$image")
                TOTAL_COUNT=$((TOTAL_COUNT + 1))

                if is_cache_valid "$cache_file"; then
                    HAS_CACHED_DATA=true
                    cached_result=$(read_cache "$cache_file")
                    if [ "$cached_result" = "0" ]; then
                        HAS_UPDATE=true
                        UPDATE_COUNT=$((UPDATE_COUNT + 1))
                    fi
                fi
            done <<< "$IMAGES"

            UPDATE_COUNT_ARRAY[$i]="$UPDATE_COUNT/$TOTAL_COUNT"

            if [ "$HAS_CACHED_DATA" = true ]; then
                if [ "$HAS_UPDATE" = true ]; then
                    UPDATE_AVAILABLE_ARRAY[$i]="yes"
                else
                    UPDATE_AVAILABLE_ARRAY[$i]="no"
                fi
            fi
        else
            CONTAINER="$ITEM"
            IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)

            if [ -n "$IMAGE" ]; then
                cache_file=$(get_cache_file "$IMAGE")
                if is_cache_valid "$cache_file"; then
                    cached_result=$(read_cache "$cache_file")
                    if [ "$cached_result" = "0" ]; then
                        UPDATE_AVAILABLE_ARRAY[$i]="yes"
                        UPDATE_COUNT_ARRAY[$i]="1/1"
                    elif [ "$cached_result" = "1" ]; then
                        UPDATE_AVAILABLE_ARRAY[$i]="no"
                        UPDATE_COUNT_ARRAY[$i]="0/1"
                    elif [ "$cached_result" = "2" ]; then
                        UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                        UPDATE_COUNT_ARRAY[$i]="?/1"
                    fi
                else
                    UPDATE_COUNT_ARRAY[$i]="?/1"
                fi
            else
                UPDATE_COUNT_ARRAY[$i]="?/1"
            fi
        fi
    done
}

# ============================================================
# portable_read_prompt - handles read -p/-n differences
# ============================================================
# bash:  read -p "prompt" -n 1 -r REPLY
# zsh:   read "REPLY?prompt" -k 1
portable_read_prompt() {
    local prompt="$1"
    local single_char="${2:-false}"

    if [ "$CURRENT_SHELL" = "zsh" ]; then
        if [ "$single_char" = "true" ]; then
            read -k 1 "REPLY?${prompt}"
            echo  # newline after single char
        else
            read "REPLY?${prompt}"
        fi
    else
        if [ "$single_char" = "true" ]; then
            read -p "$prompt" -n 1 -r REPLY
            echo
        else
            read -p "$prompt" -r REPLY
        fi
    fi
}

# ============================================================
# MAIN LOOP
# ============================================================
while true; do
    echo ""

    reload_cache_status
    display_table

    echo ""
    echo "Options:"
    echo "  1) Select container to upgrade"
    CACHE_MINS=$(awk "BEGIN {val=$CACHE_VALIDITY_SECONDS/60; if (val == int(val)) printf \"%d\", val; else printf \"%.1f\", val}")
    echo "  2) Check for updates (uses ${CACHE_MINS} min cache if available)"
    echo "  3) Force check for updates (ignores cache)"
    echo "  4) Reload update status from cache"
    echo "  q) Quit"
    echo ""
    portable_read_prompt "Select option: "
    CHECK_OPTION="$REPLY"

    if [ "$CHECK_OPTION" = "q" ] || [ "$CHECK_OPTION" = "Q" ]; then
        echo "Exiting..."
        exit 0
    fi

    if [ "$CHECK_OPTION" = "4" ]; then
        echo ""
        echo "Reloading update status from cache..."
        echo ""

        local_i=0
        for local_i in $(array_indices ITEM_ARRAY); do
            ITEM="${ITEM_ARRAY[$local_i]}"
            ITEM_TYPE="${ITEM_TYPE_ARRAY[$local_i]}"

            if [[ "$ITEM_TYPE" == "compose:"* ]]; then
                PROJECT_NAME="${ITEM_TYPE#compose:}"
                IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

                HAS_UPDATE=false
                HAS_CACHED_DATA=false
                while IFS= read -r image; do
                    if [ -z "$image" ]; then continue; fi
                    cache_file=$(get_cache_file "$image")
                    if is_cache_valid "$cache_file"; then
                        HAS_CACHED_DATA=true
                        cached_result=$(read_cache "$cache_file")
                        if [ "$cached_result" = "0" ]; then
                            HAS_UPDATE=true
                        fi
                    fi
                done <<< "$IMAGES"

                if [ "$HAS_CACHED_DATA" = true ]; then
                    if [ "$HAS_UPDATE" = true ]; then
                        UPDATE_AVAILABLE_ARRAY[$local_i]="yes"
                    else
                        UPDATE_AVAILABLE_ARRAY[$local_i]="no"
                    fi
                else
                    UPDATE_AVAILABLE_ARRAY[$local_i]="unknown"
                fi
            else
                CONTAINER="$ITEM"
                IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)

                if [ -n "$IMAGE" ]; then
                    cache_file=$(get_cache_file "$IMAGE")
                    if is_cache_valid "$cache_file"; then
                        cached_result=$(read_cache "$cache_file")
                        if [ "$cached_result" = "0" ]; then
                            UPDATE_AVAILABLE_ARRAY[$local_i]="yes"
                        elif [ "$cached_result" = "1" ]; then
                            UPDATE_AVAILABLE_ARRAY[$local_i]="no"
                        else
                            UPDATE_AVAILABLE_ARRAY[$local_i]="unknown"
                        fi
                    else
                        UPDATE_AVAILABLE_ARRAY[$local_i]="unknown"
                    fi
                else
                    UPDATE_AVAILABLE_ARRAY[$local_i]="unknown"
                fi
            fi

            RECENTLY_UPGRADED_ARRAY[$local_i]="no"
        done

        echo -e "${GREEN}✓ Update status reloaded from cache${NC}"
        echo ""
        continue
    fi

    if [ "$CHECK_OPTION" = "2" ] || [ "$CHECK_OPTION" = "3" ]; then
        IGNORE_CACHE=false
        if [ "$CHECK_OPTION" = "3" ]; then
            IGNORE_CACHE=true
            echo ""
            echo -e "${YELLOW}Force checking (ignoring cache)...${NC}"
        fi

        if ! command -v skopeo >/dev/null 2>&1; then
            echo ""
            echo -e "${RED}❌ Error: skopeo is not installed${NC}"
            echo ""
            echo "skopeo is required to check for updates without pulling images."
            echo ""
            echo "To install skopeo:"
            case "$PLATFORM" in
                macos)
                    echo -e "${GREEN}  brew install skopeo${NC}"
                    ;;
                linux)
                    echo -e "${GREEN}  sudo apt-get install skopeo${NC}"
                    echo ""
                    echo "Or on other distros:"
                    echo "  - Fedora/RHEL: sudo dnf install skopeo"
                    ;;
                *)
                    echo -e "${GREEN}  sudo apt-get install skopeo${NC}"
                    echo "  - macOS: brew install skopeo"
                    echo "  - Fedora/RHEL: sudo dnf install skopeo"
                    ;;
            esac
            echo ""
            portable_read_prompt "Press Enter to return to main menu..."
            continue
        fi

        if ! command -v jq >/dev/null 2>&1; then
            echo ""
            echo -e "${RED}❌ Error: jq is not installed${NC}"
            echo ""
            echo "jq is required to parse skopeo output."
            echo ""
            echo "To install jq:"
            case "$PLATFORM" in
                macos) echo -e "${GREEN}  brew install jq${NC}" ;;
                linux) echo -e "${GREEN}  sudo apt-get install jq${NC}" ;;
                *)     echo -e "${GREEN}  sudo apt-get install jq${NC}" ;;
            esac
            echo ""
            portable_read_prompt "Press Enter to return to main menu..."
            continue
        fi

        echo ""
        echo "Checking Docker registry authentication..."
        if ! check_docker_auth; then
            echo -e "${YELLOW}⚠️  Not authenticated with Docker Hub${NC}"
            prompt_docker_login
        else
            echo -e "${GREEN}✓ Authenticated with Docker Hub${NC}"
        fi

        echo ""
        echo "Checking for updates..."
        echo ""

        ITEM_COUNT=$(array_length ITEM_ARRAY)
        for i in $(array_indices ITEM_ARRAY); do
            ITEM="${ITEM_ARRAY[$i]}"
            ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

            echo -n "[$((i+1))/${ITEM_COUNT}] Checking $ITEM... "

            if [[ "$ITEM_TYPE" == "compose:"* ]]; then
                PROJECT_NAME="${ITEM_TYPE#compose:}"
                IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

                IMAGE_COUNT=$(echo "$IMAGES" | portable_wc_l)
                echo ""
                echo "  Checking $IMAGE_COUNT images for $PROJECT_NAME:"

                HAS_UPDATE=false
                UPDATE_COUNT=0
                TOTAL_COUNT=0
                IMG_NUM=0
                while IFS= read -r image; do
                    if [ -z "$image" ]; then continue; fi
                    IMG_NUM=$((IMG_NUM + 1))
                    TOTAL_COUNT=$((TOTAL_COUNT + 1))
                    echo -n "    [$IMG_NUM/$IMAGE_COUNT] $image... "

                    if check_update_available "$image"; then
                        HAS_UPDATE=true
                        UPDATE_COUNT=$((UPDATE_COUNT + 1))
                        echo -e "${YELLOW}UPDATE AVAILABLE${NC}"
                    elif [ $? -eq 1 ]; then
                        echo -e "${GREEN}UP TO DATE${NC}"
                    else
                        echo "UNABLE TO CHECK"
                    fi
                done <<< "$IMAGES"

                UPDATE_COUNT_ARRAY[$i]="$UPDATE_COUNT/$TOTAL_COUNT"

                echo -n "[$((i+1))/${ITEM_COUNT}] $ITEM overall: "
                if [ "$HAS_UPDATE" = true ]; then
                    UPDATE_AVAILABLE_ARRAY[$i]="yes"
                    echo -e "${YELLOW}UPDATE AVAILABLE${NC}"
                else
                    UPDATE_AVAILABLE_ARRAY[$i]="no"
                    echo -e "${GREEN}UP TO DATE${NC}"
                fi

                RECENTLY_UPGRADED_ARRAY[$i]="no"
            else
                CONTAINER="$ITEM"
                IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER")

                if check_update_available "$IMAGE"; then
                    UPDATE_AVAILABLE_ARRAY[$i]="yes"
                    echo -e "${YELLOW}UPDATE AVAILABLE${NC}"
                elif [ $? -eq 1 ]; then
                    UPDATE_AVAILABLE_ARRAY[$i]="no"
                    echo -e "${GREEN}UP TO DATE${NC}"
                else
                    UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                    echo "UNABLE TO CHECK"
                fi

                RECENTLY_UPGRADED_ARRAY[$i]="no"
            fi

            sleep 0.1
        done

        echo ""
        echo "Update check complete! Refreshing table..."
        sleep 1

        lines_to_clear=$((ITEM_COUNT + 5))
        portable_tput_clear_lines $lines_to_clear

        echo ""
        continue
    fi

    if [ "$CHECK_OPTION" = "1" ]; then
        echo ""
        portable_read_prompt "Select number to upgrade (or 'q' to cancel): "
        SELECTION="$REPLY"

        if [ "$SELECTION" = "q" ] || [ "$SELECTION" = "Q" ]; then
            continue
        fi

        ITEM_COUNT=$(array_length ITEM_ARRAY)
        if ! echo "$SELECTION" | grep -qE '^[0-9]+$' || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$ITEM_COUNT" ]; then
            echo -e "${RED}Error: Invalid selection${NC}"
            portable_read_prompt "Press Enter to continue..."
            continue
        fi

        SELECTED_ITEM="${ITEM_ARRAY[$((SELECTION-1))]}"
        SELECTED_TYPE="${ITEM_TYPE_ARRAY[$((SELECTION-1))]}"
        SELECTED_INDEX=$((SELECTION-1))

        echo ""
        echo -e "${BLUE}=== Upgrading: $SELECTED_ITEM ===${NC}"
        echo ""

        if [[ "$SELECTED_TYPE" == "compose:"* ]]; then
            PROJECT_NAME="${SELECTED_TYPE#compose:}"
            echo -e "Type: 📦 ${CYAN}Docker Compose${NC}"

            COMPOSE_DIR="${COMPOSE_DIRS[$PROJECT_NAME]}"
            COMPOSE_FILE="${COMPOSE_FILES[$PROJECT_NAME]}"

            echo "Project: $PROJECT_NAME"
            echo "Directory: $COMPOSE_DIR"
            echo "Config files: $COMPOSE_FILE"

            echo ""
            echo "Services in this project:"
            docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "  - {{.Names}} ({{.Image}})"
            echo ""

            if [ -z "$COMPOSE_DIR" ] || [ ! -d "$COMPOSE_DIR" ]; then
                echo -e "${RED}⚠️  Cannot find compose directory automatically${NC}"
                portable_read_prompt "Enter the compose directory path: "
                COMPOSE_DIR="$REPLY"

                if [ ! -d "$COMPOSE_DIR" ]; then
                    echo -e "${RED}❌ Directory not found: $COMPOSE_DIR${NC}"
                    portable_read_prompt "Press Enter to continue..."
                    continue
                fi
            fi

            if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
                COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
                if [ ! -f "$COMPOSE_FILE" ]; then
                    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yaml"
                    if [ ! -f "$COMPOSE_FILE" ]; then
                        echo -e "${RED}❌ No docker-compose.yml found in $COMPOSE_DIR${NC}"
                        portable_read_prompt "Press Enter to continue..."
                        continue
                    fi
                fi
            fi

            echo -e "${GREEN}✓ Found compose file: $COMPOSE_FILE${NC}"
            echo ""

            if command -v docker-compose >/dev/null 2>&1; then
                COMPOSE_CMD="docker-compose"
            elif docker compose version >/dev/null 2>&1; then
                COMPOSE_CMD="docker compose"
            else
                echo -e "${RED}❌ Neither 'docker-compose' nor 'docker compose' found${NC}"
                portable_read_prompt "Press Enter to continue..."
                continue
            fi

            echo "Using command: $COMPOSE_CMD"
            echo ""

            portable_read_prompt "Pull images and recreate ALL services in this project? (y/n) " true
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Cancelled."
                portable_read_prompt "Press Enter to continue..."
                continue
            fi

            echo ""
            echo -e "${BLUE}=== Pulling latest images ===${NC}"
            cd "$COMPOSE_DIR"
            $COMPOSE_CMD pull

            echo ""
            echo -e "${BLUE}=== Recreating all services ===${NC}"
            $COMPOSE_CMD up -d --force-recreate

            echo ""
            echo -e "${GREEN}=== Upgrade complete! ===${NC}"
            docker ps --filter "label=com.docker.compose.project=$PROJECT_NAME"

            RECENTLY_UPGRADED_ARRAY[$SELECTED_INDEX]="yes"
            UPDATE_AVAILABLE_ARRAY[$SELECTED_INDEX]="unknown"

            scan_containers

            echo ""
            continue

        else
            CONTAINER_NAME="$SELECTED_ITEM"
            echo -e "Type: 🐳 ${PURPLE}Standalone${NC}"
            echo ""

            IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME")
            echo "Image: $IMAGE"
            echo ""

            PORTS=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $conf}}-p {{.HostIP}}{{if .HostIP}}:{{end}}{{.HostPort}}:{{$p}} {{end}}{{end}}{{end}}' "$CONTAINER_NAME")

            VOLUMES=$(docker inspect --format='{{range .Mounts}}-v {{.Source}}:{{.Destination}}{{if .Mode}}:{{.Mode}}{{end}} {{end}}' "$CONTAINER_NAME")

            ENV_VARS=$(docker inspect --format='{{range .Config.Env}}-e "{{.}}" {{end}}' "$CONTAINER_NAME")

            RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")
            if [ "$RESTART" != "no" ] && [ -n "$RESTART" ]; then
                RESTART_FLAG="--restart=$RESTART"
            else
                RESTART_FLAG=""
            fi

            NETWORK=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
            if [ "$NETWORK" != "default" ] && [ -n "$NETWORK" ]; then
                NETWORK_FLAG="--network=$NETWORK"
            else
                NETWORK_FLAG=""
            fi

            PRIVILEGED=$(docker inspect --format='{{.HostConfig.Privileged}}' "$CONTAINER_NAME")
            if [ "$PRIVILEGED" = "true" ]; then
                PRIVILEGED_FLAG="--privileged"
            else
                PRIVILEGED_FLAG=""
            fi

            RUN_CMD="docker run -d --name $CONTAINER_NAME $RESTART_FLAG $NETWORK_FLAG $PRIVILEGED_FLAG $PORTS $VOLUMES $ENV_VARS $IMAGE"

            echo -e "${BLUE}=== Current configuration ===${NC}"
            echo "$RUN_CMD"
            echo ""

            echo -e "${BLUE}=== Volumes to preserve ===${NC}"
            if [ -z "$VOLUMES" ]; then
                echo -e "${RED}  (none - WARNING: container may not persist data!)${NC}"
            else
                docker inspect --format='{{range .Mounts}}  {{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$CONTAINER_NAME"
            fi
            echo ""

            echo -e "${GREEN}=== Confirm before proceeding ===${NC}"
            portable_read_prompt "Pull latest image and recreate container? (y/n) " true
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Cancelled."
                portable_read_prompt "Press Enter to continue..."
                continue
            fi

            echo ""
            echo -e "${BLUE}=== Pulling latest image ===${NC}"
            docker pull "$IMAGE"

            echo ""
            echo -e "${BLUE}=== Stopping container ===${NC}"
            docker stop "$CONTAINER_NAME"

            echo -e "${BLUE}=== Removing old container ===${NC}"
            docker rm "$CONTAINER_NAME"

            echo ""
            echo -e "${BLUE}=== Creating new container ===${NC}"
            eval $RUN_CMD

            echo ""
            echo -e "${GREEN}=== Upgrade complete! ===${NC}"
            docker ps --filter name="$CONTAINER_NAME"

            RECENTLY_UPGRADED_ARRAY[$SELECTED_INDEX]="yes"
            UPDATE_AVAILABLE_ARRAY[$SELECTED_INDEX]="unknown"

            scan_containers

            echo ""
            continue
        fi
    fi

    echo -e "${RED}Invalid option${NC}"
done
