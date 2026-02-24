#!/bin/sh
# docker-upgrade.sh - Interactive Docker container upgrade tool (POSIX-compliant)
# Handles both standalone containers and docker-compose managed containers

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cache configuration
CACHE_DIR="/tmp/docker-upgrade-cache-$$"
CACHE_VALIDITY_SECONDS=300  # 5 minutes
mkdir -p "$CACHE_DIR"

# Data directory for our "arrays" (files-based approach)
DATA_DIR="/tmp/docker-upgrade-data-$$"
mkdir -p "$DATA_DIR"

# Cleanup on exit
cleanup() {
    rm -rf "$DATA_DIR"
    rm -rf "$CACHE_DIR"
}
trap cleanup EXIT INT TERM

# --- Utility: file-based list helpers ---
# Since POSIX sh has no arrays, we store items in numbered files.
# E.g., DATA_DIR/item.0, DATA_DIR/item.1, ...
# item_count is tracked in DATA_DIR/count

get_item_count() {
    if [ -f "$DATA_DIR/count" ]; then
        cat "$DATA_DIR/count"
    else
        echo 0
    fi
}

set_item_count() {
    echo "$1" > "$DATA_DIR/count"
}

set_field() {
    # set_field <index> <field> <value>
    echo "$3" > "$DATA_DIR/${2}.${1}"
}

get_field() {
    # get_field <index> <field>
    if [ -f "$DATA_DIR/${2}.${1}" ]; then
        cat "$DATA_DIR/${2}.${1}"
    else
        echo ""
    fi
}

# Compose project tracking (simple file-based set)
has_compose_project() {
    [ -f "$DATA_DIR/compose_project_seen.$1" ]
}

mark_compose_project() {
    echo "1" > "$DATA_DIR/compose_project_seen.$1"
}

clear_compose_projects() {
    rm -f "$DATA_DIR"/compose_project_seen.* 2>/dev/null || true
}

# --- Cache functions ---
get_cache_file() {
    _image="$1"
    _safe_name=$(printf '%s' "$_image" | sed 's/[^a-zA-Z0-9._-]/_/g')
    echo "$CACHE_DIR/$_safe_name.cache"
}

is_cache_valid() {
    _cache_file="$1"
    if [ ! -f "$_cache_file" ]; then
        return 1
    fi
    # Try GNU stat first, then BSD stat
    _cache_time=$(stat -c %Y "$_cache_file" 2>/dev/null || stat -f %m "$_cache_file" 2>/dev/null) || return 1
    _current_time=$(date +%s)
    _age=$((_current_time - _cache_time))
    if [ "$_age" -lt "$CACHE_VALIDITY_SECONDS" ]; then
        return 0
    else
        return 1
    fi
}

read_cache() {
    _cache_file="$1"
    if [ -f "$_cache_file" ]; then
        cat "$_cache_file"
    fi
}

write_cache() {
    _cache_file="$1"
    _result="$2"
    echo "$_result" > "$_cache_file"
}

# --- Docker auth check ---
check_docker_auth() {
    _registry="${1:-docker.io}"
    if docker system info 2>/dev/null | grep -q "Username:"; then
        return 0
    fi
    if timeout 10 skopeo inspect --command-timeout 10s "docker://${_registry}/library/alpine:latest" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

prompt_docker_login() {
    echo ""
    printf "${YELLOW}⚠️  Docker Registry Authentication${NC}\n"
    echo ""
    echo "To avoid rate limiting and timeouts, it's recommended to authenticate with Docker registries."
    echo ""
    echo "Docker Hub (docker.io) limits anonymous requests to 100 pulls per 6 hours."
    echo "Authenticated users get 200 pulls per 6 hours (free tier) or unlimited (paid)."
    echo ""
    printf "Would you like to log in to Docker Hub now? (y/n) "
    read -r REPLY
    case "$REPLY" in
        [Yy]|[Yy][Ee][Ss])
            echo ""
            printf "${BLUE}=== Logging in to Docker Hub ===${NC}\n"
            echo ""
            if docker login; then
                echo ""
                printf "${GREEN}✓ Successfully logged in to Docker Hub${NC}\n"
                return 0
            else
                echo ""
                printf "${RED}❌ Login failed${NC}\n"
                return 1
            fi
            ;;
        *)
            echo ""
            printf "${YELLOW}Continuing without authentication (may experience rate limiting)${NC}\n"
            return 1
            ;;
    esac
}

# --- Update check ---
check_update_available() {
    _image="$1"
    _timeout="${SKOPEO_TIMEOUT:-30}"
    _max_retries="${SKOPEO_RETRIES:-3}"

    _cache_file=$(get_cache_file "$_image")
    if is_cache_valid "$_cache_file"; then
        _cached_result=$(read_cache "$_cache_file")
        return "$_cached_result"
    fi

    _local_digest=$(docker inspect --type=image --format='{{index .RepoDigests 0}}' "$_image" 2>/dev/null | cut -d'@' -f2)
    if [ -z "$_local_digest" ]; then
        write_cache "$_cache_file" 2
        return 2
    fi

    _remote_digest=""
    _retry=0
    while [ "$_retry" -le "$_max_retries" ]; do
        if [ "$_retry" -gt 0 ]; then
            printf "(retry %s/%s) " "$_retry" "$_max_retries"
        fi
        _remote_digest=$(timeout "$_timeout" skopeo inspect --command-timeout "${_timeout}s" "docker://$_image" 2>/dev/null | jq -r '.Digest' 2>/dev/null) || true

        if [ -n "$_remote_digest" ] && [ "$_remote_digest" != "null" ]; then
            break
        fi
        _retry=$((_retry + 1))
    done

    if [ -z "$_remote_digest" ] || [ "$_remote_digest" = "null" ]; then
        write_cache "$_cache_file" 2
        return 2
    fi

    if [ "$_local_digest" != "$_remote_digest" ]; then
        write_cache "$_cache_file" 0
        return 0
    else
        write_cache "$_cache_file" 1
        return 1
    fi
}

check_update_async() {
    _image="$1"
    _cache_file=$(get_cache_file "$_image")
    if is_cache_valid "$_cache_file"; then
        return
    fi
    (SKOPEO_TIMEOUT=5 SKOPEO_RETRIES=1; export SKOPEO_TIMEOUT SKOPEO_RETRIES; check_update_available "$_image" >/dev/null 2>&1) &
}

# --- Container scanning ---
scan_containers() {
    # Save previous state into temp files
    _old_count=$(get_item_count)
    mkdir -p "$DATA_DIR/old"
    _oi=0
    while [ "$_oi" -lt "$_old_count" ]; do
        _oname=$(get_field "$_oi" "item")
        _oupdate=$(get_field "$_oi" "update")
        _oupgraded=$(get_field "$_oi" "upgraded")
        if [ -n "$_oname" ]; then
            echo "$_oupdate" > "$DATA_DIR/old/update.$_oname"
            echo "$_oupgraded" > "$DATA_DIR/old/upgraded.$_oname"
        fi
        _oi=$((_oi + 1))
    done

    # Clear data
    rm -f "$DATA_DIR"/item.* "$DATA_DIR"/type.* "$DATA_DIR"/update.* "$DATA_DIR"/upgraded.* "$DATA_DIR"/ucount.* 2>/dev/null || true
    clear_compose_projects
    set_item_count 0

    echo "Scanning containers..."

    ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")
    if [ -z "$ALL_CONTAINERS" ]; then
        return
    fi

    _idx=0
    echo "$ALL_CONTAINERS" | while IFS= read -r container; do
        # Re-read idx from file since we're in a subshell-safe pattern
        true
    done

    # Because piping into while creates a subshell in POSIX sh,
    # we use a temp file approach
    _idx=0
    _tmpcontainers="$DATA_DIR/tmpcontainers"
    echo "$ALL_CONTAINERS" > "$_tmpcontainers"

    while IFS= read -r container; do
        COMPOSE_PROJECT=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null) || COMPOSE_PROJECT=""

        if [ -n "$COMPOSE_PROJECT" ]; then
            if ! has_compose_project "$COMPOSE_PROJECT"; then
                mark_compose_project "$COMPOSE_PROJECT"

                set_field "$_idx" "item" "$COMPOSE_PROJECT"
                set_field "$_idx" "type" "compose:$COMPOSE_PROJECT"

                # Restore previous status
                if [ -f "$DATA_DIR/old/update.$COMPOSE_PROJECT" ]; then
                    set_field "$_idx" "update" "$(cat "$DATA_DIR/old/update.$COMPOSE_PROJECT")"
                else
                    set_field "$_idx" "update" "unknown"
                fi
                if [ -f "$DATA_DIR/old/upgraded.$COMPOSE_PROJECT" ]; then
                    set_field "$_idx" "upgraded" "$(cat "$DATA_DIR/old/upgraded.$COMPOSE_PROJECT")"
                else
                    set_field "$_idx" "upgraded" "no"
                fi

                # Store compose directory and file
                _cdir=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null) || _cdir=""
                _cfile=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container" 2>/dev/null) || _cfile=""
                set_field "$COMPOSE_PROJECT" "composedir" "$_cdir"
                set_field "$COMPOSE_PROJECT" "composefile" "$_cfile"

                _idx=$((_idx + 1))
                set_item_count "$_idx"
            fi
        else
            set_field "$_idx" "item" "$container"
            set_field "$_idx" "type" "standalone"

            if [ -f "$DATA_DIR/old/update.$container" ]; then
                set_field "$_idx" "update" "$(cat "$DATA_DIR/old/update.$container")"
            else
                set_field "$_idx" "update" "unknown"
            fi
            if [ -f "$DATA_DIR/old/upgraded.$container" ]; then
                set_field "$_idx" "upgraded" "$(cat "$DATA_DIR/old/upgraded.$container")"
            else
                set_field "$_idx" "upgraded" "no"
            fi

            _idx=$((_idx + 1))
            set_item_count "$_idx"
        fi
    done < "$_tmpcontainers"

    rm -rf "$DATA_DIR/old"
}

# --- Async checks ---
start_async_checks() {
    if ! command -v skopeo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        return
    fi
    _count=$(get_item_count)
    _i=0
    while [ "$_i" -lt "$_count" ]; do
        _item=$(get_field "$_i" "item")
        _itype=$(get_field "$_i" "type")

        case "$_itype" in
            compose:*)
                _project="${_itype#compose:}"
                _images=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Image}}" | sort -u)
                echo "$_images" | while IFS= read -r _img; do
                    if [ -n "$_img" ]; then
                        check_update_async "$_img"
                    fi
                done
                ;;
            *)
                _img=$(docker inspect --format='{{.Config.Image}}' "$_item" 2>/dev/null) || _img=""
                if [ -n "$_img" ]; then
                    check_update_async "$_img"
                fi
                ;;
        esac
        _i=$((_i + 1))
    done
}

# --- Reload cache status ---
reload_cache_status() {
    _count=$(get_item_count)
    _i=0
    while [ "$_i" -lt "$_count" ]; do
        _item=$(get_field "$_i" "item")
        _itype=$(get_field "$_i" "type")

        case "$_itype" in
            compose:*)
                _project="${_itype#compose:}"
                _images=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Image}}" | sort -u)

                _has_update=false
                _has_cached=false
                _up_count=0
                _total_count=0

                echo "$_images" | while IFS= read -r _img; do
                    if [ -n "$_img" ]; then
                        _cf=$(get_cache_file "$_img")
                        _total_count=$((_total_count + 1))
                        if is_cache_valid "$_cf"; then
                            _has_cached=true
                            _cr=$(read_cache "$_cf")
                            if [ "$_cr" = "0" ]; then
                                _has_update=true
                                _up_count=$((_up_count + 1))
                            fi
                        fi
                        # Write intermediate results to file
                        echo "$_has_update" > "$DATA_DIR/tmp_has_update"
                        echo "$_has_cached" > "$DATA_DIR/tmp_has_cached"
                        echo "$_up_count" > "$DATA_DIR/tmp_up_count"
                        echo "$_total_count" > "$DATA_DIR/tmp_total_count"
                    fi
                done

                # Read results from temp files (handles subshell issue)
                if [ -f "$DATA_DIR/tmp_has_update" ]; then
                    _has_update=$(cat "$DATA_DIR/tmp_has_update")
                    _has_cached=$(cat "$DATA_DIR/tmp_has_cached")
                    _up_count=$(cat "$DATA_DIR/tmp_up_count")
                    _total_count=$(cat "$DATA_DIR/tmp_total_count")
                    rm -f "$DATA_DIR"/tmp_has_update "$DATA_DIR"/tmp_has_cached "$DATA_DIR"/tmp_up_count "$DATA_DIR"/tmp_total_count
                fi

                set_field "$_i" "ucount" "${_up_count}/${_total_count}"

                if [ "$_has_cached" = "true" ]; then
                    if [ "$_has_update" = "true" ]; then
                        set_field "$_i" "update" "yes"
                    else
                        set_field "$_i" "update" "no"
                    fi
                fi
                ;;
            *)
                _container="$_item"
                _img=$(docker inspect --format='{{.Config.Image}}' "$_container" 2>/dev/null) || _img=""
                if [ -n "$_img" ]; then
                    _cf=$(get_cache_file "$_img")
                    if is_cache_valid "$_cf"; then
                        _cr=$(read_cache "$_cf")
                        if [ "$_cr" = "0" ]; then
                            set_field "$_i" "update" "yes"
                            set_field "$_i" "ucount" "1/1"
                        elif [ "$_cr" = "1" ]; then
                            set_field "$_i" "update" "no"
                            set_field "$_i" "ucount" "0/1"
                        elif [ "$_cr" = "2" ]; then
                            set_field "$_i" "update" "unknown"
                            set_field "$_i" "ucount" "?/1"
                        fi
                    else
                        set_field "$_i" "ucount" "?/1"
                    fi
                else
                    set_field "$_i" "ucount" "?/1"
                fi
                ;;
        esac
        _i=$((_i + 1))
    done
}

# --- Display table ---
display_table() {
    echo "Available containers to upgrade:"
    echo ""

    printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
        "No." "Name" "Image" "Status" "Type" "Update"
    printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
        "----" "-----------------------------------" "--------------------------------------------------" "------------" "-----------------------------------" "--------------------"

    _count=$(get_item_count)
    _i=0
    while [ "$_i" -lt "$_count" ]; do
        _item=$(get_field "$_i" "item")
        _itype=$(get_field "$_i" "type")
        _update_status=$(get_field "$_i" "update")
        _upgraded_status=$(get_field "$_i" "upgraded")
        _update_count=$(get_field "$_i" "ucount")

        _display_name=""
        _display_image=""
        _status=""
        _type_str=""
        _type_color=""

        case "$_itype" in
            compose:*)
                _project="${_itype#compose:}"
                _ccount=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Names}}" | wc -l | tr -d ' ')
                _first=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Names}}" | head -n 1)

                if [ -n "$_first" ]; then
                    _status=$(docker inspect --format='{{.State.Status}}' "$_first" 2>/dev/null) || _status="unknown"
                    _imgs=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Image}}" | sort -u | head -n 2 | tr '\n' ',' | sed 's/,$//')

                    _display_name="$_project"
                    if [ ${#_display_name} -gt 33 ]; then
                        _display_name="$(echo "$_display_name" | cut -c1-30)..."
                    fi

                    _display_image="$_imgs"
                    if [ "$_ccount" -gt 2 ]; then
                        _display_image="${_display_image}..."
                    fi
                    if [ ${#_display_image} -gt 48 ]; then
                        _display_image="$(echo "$_display_image" | cut -c1-45)..."
                    fi

                    _type_str="Compose ($_ccount services)"
                    _type_color="$CYAN"
                else
                    _i=$((_i + 1))
                    continue
                fi
                ;;
            *)
                _container="$_item"
                _img=$(docker inspect --format='{{.Config.Image}}' "$_container" 2>/dev/null) || _img="unknown"
                _status=$(docker inspect --format='{{.State.Status}}' "$_container" 2>/dev/null) || _status="unknown"

                _display_name="$_container"
                if [ ${#_display_name} -gt 33 ]; then
                    _display_name="$(echo "$_display_name" | cut -c1-30)..."
                fi

                _display_image="$_img"
                if [ ${#_display_image} -gt 48 ]; then
                    _display_image="$(echo "$_display_image" | cut -c1-45)..."
                fi

                _type_str="Standalone"
                _type_color="$PURPLE"
                ;;
        esac

        # Format update column
        _update_str=""
        _update_color=""

        if [ "$_upgraded_status" = "yes" ]; then
            _update_str="  Just upgraded"
            _update_color="$BLUE"
        elif [ "$_update_status" = "yes" ]; then
            if [ -n "$_update_count" ]; then
                _update_str="  ^ $_update_count need update"
            else
                _update_str="  ^ Available"
            fi
            _update_color="$YELLOW"
        elif [ "$_update_status" = "no" ]; then
            if [ -n "$_update_count" ]; then
                # Parse X/Y
                _needs=$(echo "$_update_count" | cut -d'/' -f1)
                _total=$(echo "$_update_count" | cut -d'/' -f2)
                if echo "$_needs" | grep -qE '^[0-9]+$' && echo "$_total" | grep -qE '^[0-9]+$'; then
                    _uptodate=$((_total - _needs))
                    _update_str="  OK ${_uptodate}/${_total} up to date"
                else
                    _update_str="  OK $_update_count up to date"
                fi
            else
                _update_str="  OK Current"
            fi
            _update_color="$GREEN"
        else
            if [ -n "$_update_count" ]; then
                _update_str="  ... $_update_count"
            else
                _update_str="  ..."
            fi
            _update_color="$NC"
        fi

        _num=$((_i + 1))
        printf "%-4s  " "$_num"
        printf "${_type_color}%-35s${NC}  " "$_display_name"
        printf "%-50s  " "$_display_image"
        printf "%-12s  " "$_status"
        printf "${_type_color}%-35s${NC}  " "$_type_str"
        printf "${_update_color}%-20s${NC}\n" "$_update_str"

        _i=$((_i + 1))
    done
}

# ========== MAIN ==========

printf "${BLUE}=== Docker Container Upgrade Tool ===${NC}\n"
echo ""

ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")
if [ -z "$ALL_CONTAINERS" ]; then
    echo "No Docker containers found"
    exit 0
fi

# Initial scan
scan_containers

# Start async checks
if command -v skopeo >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "Starting background update checks..."
    start_async_checks
    echo ""
fi

# Main loop
while true; do
    echo ""
    reload_cache_status
    display_table

    echo ""
    echo "Options:"
    echo "  1) Select container to upgrade"
    _cache_mins=$(awk "BEGIN {val=$CACHE_VALIDITY_SECONDS/60; if (val == int(val)) printf \"%d\", val; else printf \"%.1f\", val}")
    echo "  2) Check for updates (uses ${_cache_mins} min cache if available)"
    echo "  3) Force check for updates (ignores cache)"
    echo "  4) Reload update status from cache"
    echo "  q) Quit"
    echo ""
    printf "Select option: "
    read -r CHECK_OPTION

    case "$CHECK_OPTION" in
        q|Q)
            echo "Exiting..."
            exit 0
            ;;

        4)
            echo ""
            echo "Reloading update status from cache..."
            echo ""

            _count=$(get_item_count)
            _i=0
            while [ "$_i" -lt "$_count" ]; do
                _item=$(get_field "$_i" "item")
                _itype=$(get_field "$_i" "type")

                case "$_itype" in
                    compose:*)
                        _project="${_itype#compose:}"
                        _images=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Image}}" | sort -u)

                        _has_update=false
                        _has_cached=false

                        # Use temp file for subshell results
                        echo "false" > "$DATA_DIR/tmp_hu"
                        echo "false" > "$DATA_DIR/tmp_hc"

                        echo "$_images" | while IFS= read -r _img; do
                            if [ -n "$_img" ]; then
                                _cf=$(get_cache_file "$_img")
                                if is_cache_valid "$_cf"; then
                                    echo "true" > "$DATA_DIR/tmp_hc"
                                    _cr=$(read_cache "$_cf")
                                    if [ "$_cr" = "0" ]; then
                                        echo "true" > "$DATA_DIR/tmp_hu"
                                    fi
                                fi
                            fi
                        done

                        _has_update=$(cat "$DATA_DIR/tmp_hu")
                        _has_cached=$(cat "$DATA_DIR/tmp_hc")
                        rm -f "$DATA_DIR/tmp_hu" "$DATA_DIR/tmp_hc"

                        if [ "$_has_cached" = "true" ]; then
                            if [ "$_has_update" = "true" ]; then
                                set_field "$_i" "update" "yes"
                            else
                                set_field "$_i" "update" "no"
                            fi
                        else
                            set_field "$_i" "update" "unknown"
                        fi
                        ;;
                    *)
                        _container="$_item"
                        _img=$(docker inspect --format='{{.Config.Image}}' "$_container" 2>/dev/null) || _img=""
                        if [ -n "$_img" ]; then
                            _cf=$(get_cache_file "$_img")
                            if is_cache_valid "$_cf"; then
                                _cr=$(read_cache "$_cf")
                                if [ "$_cr" = "0" ]; then
                                    set_field "$_i" "update" "yes"
                                elif [ "$_cr" = "1" ]; then
                                    set_field "$_i" "update" "no"
                                else
                                    set_field "$_i" "update" "unknown"
                                fi
                            else
                                set_field "$_i" "update" "unknown"
                            fi
                        else
                            set_field "$_i" "update" "unknown"
                        fi
                        ;;
                esac

                set_field "$_i" "upgraded" "no"
                _i=$((_i + 1))
            done

            printf "${GREEN}✓ Update status reloaded from cache${NC}\n"
            echo ""
            continue
            ;;

        2|3)
            IGNORE_CACHE=false
            if [ "$CHECK_OPTION" = "3" ]; then
                IGNORE_CACHE=true
                echo ""
                printf "${YELLOW}Force checking (ignoring cache)...${NC}\n"
            fi

            if ! command -v skopeo >/dev/null 2>&1; then
                echo ""
                printf "${RED}Error: skopeo is not installed${NC}\n"
                echo ""
                echo "skopeo is required to check for updates without pulling images."
                echo ""
                echo "To install skopeo, run:"
                printf "${GREEN}  sudo apt-get install skopeo${NC}\n"
                echo ""
                echo "Or on other systems:"
                echo "  - Fedora/RHEL: sudo dnf install skopeo"
                echo "  - macOS: brew install skopeo"
                echo ""
                printf "Press Enter to return to main menu..."
                read -r _dummy
                continue
            fi

            if ! command -v jq >/dev/null 2>&1; then
                echo ""
                printf "${RED}Error: jq is not installed${NC}\n"
                echo ""
                echo "jq is required to parse skopeo output."
                echo ""
                printf "Press Enter to return to main menu..."
                read -r _dummy
                continue
            fi

            echo ""
            echo "Checking Docker registry authentication..."
            if ! check_docker_auth; then
                printf "${YELLOW}⚠️  Not authenticated with Docker Hub${NC}\n"
                prompt_docker_login
            else
                printf "${GREEN}✓ Authenticated with Docker Hub${NC}\n"
            fi

            echo ""
            echo "Checking for updates..."
            echo ""

            _count=$(get_item_count)
            _i=0
            while [ "$_i" -lt "$_count" ]; do
                _item=$(get_field "$_i" "item")
                _itype=$(get_field "$_i" "type")

                printf "[$((_i + 1))/${_count}] Checking %s... " "$_item"

                case "$_itype" in
                    compose:*)
                        _project="${_itype#compose:}"
                        _images=$(docker ps -a --filter "label=com.docker.compose.project=$_project" --format "{{.Image}}" | sort -u)
                        _image_count=$(echo "$_images" | wc -l | tr -d ' ')

                        echo ""
                        echo "  Checking $_image_count images for $_project:"

                        _has_update=false
                        _up_cnt=0
                        _tot_cnt=0
                        _img_num=0

                        # Use temp files for subshell
                        echo "false" > "$DATA_DIR/tmp_hu2"
                        echo "0" > "$DATA_DIR/tmp_uc2"
                        echo "0" > "$DATA_DIR/tmp_tc2"
                        echo "0" > "$DATA_DIR/tmp_in2"

                        # Process images without subshell using temp file
                        _imgfile="$DATA_DIR/tmp_imglist"
                        echo "$_images" > "$_imgfile"
                        while IFS= read -r _img; do
                            if [ -z "$_img" ]; then continue; fi
                            _img_num=$(cat "$DATA_DIR/tmp_in2")
                            _img_num=$((_img_num + 1))
                            echo "$_img_num" > "$DATA_DIR/tmp_in2"

                            _tot_cnt=$(cat "$DATA_DIR/tmp_tc2")
                            _tot_cnt=$((_tot_cnt + 1))
                            echo "$_tot_cnt" > "$DATA_DIR/tmp_tc2"

                            printf "    [%s/%s] %s... " "$_img_num" "$_image_count" "$_img"

                            if check_update_available "$_img"; then
                                echo "true" > "$DATA_DIR/tmp_hu2"
                                _up_cnt=$(cat "$DATA_DIR/tmp_uc2")
                                _up_cnt=$((_up_cnt + 1))
                                echo "$_up_cnt" > "$DATA_DIR/tmp_uc2"
                                printf "${YELLOW}UPDATE AVAILABLE${NC}\n"
                            elif [ $? -eq 1 ]; then
                                printf "${GREEN}UP TO DATE${NC}\n"
                            else
                                echo "UNABLE TO CHECK"
                            fi
                        done < "$_imgfile"

                        _has_update=$(cat "$DATA_DIR/tmp_hu2")
                        _up_cnt=$(cat "$DATA_DIR/tmp_uc2")
                        _tot_cnt=$(cat "$DATA_DIR/tmp_tc2")
                        rm -f "$DATA_DIR"/tmp_hu2 "$DATA_DIR"/tmp_uc2 "$DATA_DIR"/tmp_tc2 "$DATA_DIR"/tmp_in2 "$_imgfile"

                        set_field "$_i" "ucount" "${_up_cnt}/${_tot_cnt}"

                        printf "[$((_i + 1))/${_count}] %s overall: " "$_item"
                        if [ "$_has_update" = "true" ]; then
                            set_field "$_i" "update" "yes"
                            printf "${YELLOW}UPDATE AVAILABLE${NC}\n"
                        else
                            set_field "$_i" "update" "no"
                            printf "${GREEN}UP TO DATE${NC}\n"
                        fi
                        set_field "$_i" "upgraded" "no"
                        ;;
                    *)
                        _container="$_item"
                        _img=$(docker inspect --format='{{.Config.Image}}' "$_container" 2>/dev/null) || _img=""

                        if check_update_available "$_img"; then
                            set_field "$_i" "update" "yes"
                            printf "${YELLOW}UPDATE AVAILABLE${NC}\n"
                        elif [ $? -eq 1 ]; then
                            set_field "$_i" "update" "no"
                            printf "${GREEN}UP TO DATE${NC}\n"
                        else
                            set_field "$_i" "update" "unknown"
                            echo "UNABLE TO CHECK"
                        fi
                        set_field "$_i" "upgraded" "no"
                        ;;
                esac

                sleep 1 2>/dev/null || true
                _i=$((_i + 1))
            done

            echo ""
            echo "Update check complete!"
            echo ""
            continue
            ;;

        1)
            echo ""
            printf "Select number to upgrade (or 'q' to cancel): "
            read -r SELECTION

            case "$SELECTION" in
                q|Q) continue ;;
            esac

            # Validate selection is numeric
            if ! echo "$SELECTION" | grep -qE '^[0-9]+$'; then
                printf "${RED}Error: Invalid selection${NC}\n"
                printf "Press Enter to continue..."
                read -r _dummy
                continue
            fi

            _count=$(get_item_count)
            if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$_count" ]; then
                printf "${RED}Error: Invalid selection${NC}\n"
                printf "Press Enter to continue..."
                read -r _dummy
                continue
            fi

            SELECTED_INDEX=$((SELECTION - 1))
            SELECTED_ITEM=$(get_field "$SELECTED_INDEX" "item")
            SELECTED_TYPE=$(get_field "$SELECTED_INDEX" "type")

            echo ""
            printf "${BLUE}=== Upgrading: %s ===${NC}\n" "$SELECTED_ITEM"
            echo ""

            case "$SELECTED_TYPE" in
                compose:*)
                    PROJECT_NAME="${SELECTED_TYPE#compose:}"
                    printf "Type: ${CYAN}Docker Compose${NC}\n"

                    COMPOSE_DIR=$(get_field "$PROJECT_NAME" "composedir")
                    COMPOSE_FILE=$(get_field "$PROJECT_NAME" "composefile")

                    echo "Project: $PROJECT_NAME"
                    echo "Directory: $COMPOSE_DIR"
                    echo "Config files: $COMPOSE_FILE"

                    echo ""
                    echo "Services in this project:"
                    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "  - {{.Names}} ({{.Image}})"
                    echo ""

                    if [ -z "$COMPOSE_DIR" ] || [ ! -d "$COMPOSE_DIR" ]; then
                        printf "${RED}Cannot find compose directory automatically${NC}\n"
                        printf "Enter the compose directory path: "
                        read -r COMPOSE_DIR

                        if [ ! -d "$COMPOSE_DIR" ]; then
                            printf "${RED}Directory not found: %s${NC}\n" "$COMPOSE_DIR"
                            printf "Press Enter to continue..."
                            read -r _dummy
                            continue
                        fi
                    fi

                    if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
                        COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
                        if [ ! -f "$COMPOSE_FILE" ]; then
                            COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yaml"
                            if [ ! -f "$COMPOSE_FILE" ]; then
                                printf "${RED}No docker-compose.yml found in %s${NC}\n" "$COMPOSE_DIR"
                                printf "Press Enter to continue..."
                                read -r _dummy
                                continue
                            fi
                        fi
                    fi

                    printf "${GREEN}✓ Found compose file: %s${NC}\n" "$COMPOSE_FILE"
                    echo ""

                    if command -v docker-compose >/dev/null 2>&1; then
                        COMPOSE_CMD="docker-compose"
                    elif docker compose version >/dev/null 2>&1; then
                        COMPOSE_CMD="docker compose"
                    else
                        printf "${RED}Neither 'docker-compose' nor 'docker compose' found${NC}\n"
                        printf "Press Enter to continue..."
                        read -r _dummy
                        continue
                    fi

                    echo "Using command: $COMPOSE_CMD"
                    echo ""

                    printf "Pull images and recreate ALL services in this project? (y/n) "
                    read -r REPLY
                    case "$REPLY" in
                        [Yy]|[Yy][Ee][Ss]) ;;
                        *)
                            echo "Cancelled."
                            printf "Press Enter to continue..."
                            read -r _dummy
                            continue
                            ;;
                    esac

                    echo ""
                    printf "${BLUE}=== Pulling latest images ===${NC}\n"
                    cd "$COMPOSE_DIR"
                    $COMPOSE_CMD pull

                    echo ""
                    printf "${BLUE}=== Recreating all services ===${NC}\n"
                    $COMPOSE_CMD up -d --force-recreate

                    echo ""
                    printf "${GREEN}=== Upgrade complete! ===${NC}\n"
                    docker ps --filter "label=com.docker.compose.project=$PROJECT_NAME"

                    set_field "$SELECTED_INDEX" "upgraded" "yes"
                    set_field "$SELECTED_INDEX" "update" "unknown"

                    scan_containers
                    echo ""
                    continue
                    ;;

                *)
                    CONTAINER_NAME="$SELECTED_ITEM"
                    printf "Type: ${PURPLE}Standalone${NC}\n"
                    echo ""

                    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME")
                    echo "Image: $IMAGE"
                    echo ""

                    PORTS=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $conf}}-p {{.HostIP}}{{if .HostIP}}:{{end}}{{.HostPort}}:{{$p}} {{end}}{{end}}{{end}}' "$CONTAINER_NAME")
                    VOLUMES=$(docker inspect --format='{{range .Mounts}}-v {{.Source}}:{{.Destination}}{{if .Mode}}:{{.Mode}}{{end}} {{end}}' "$CONTAINER_NAME")
                    ENV_VARS=$(docker inspect --format='{{range .Config.Env}}-e "{{.}}" {{end}}' "$CONTAINER_NAME")

                    RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")
                    RESTART_FLAG=""
                    if [ "$RESTART" != "no" ] && [ -n "$RESTART" ]; then
                        RESTART_FLAG="--restart=$RESTART"
                    fi

                    NETWORK=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
                    NETWORK_FLAG=""
                    if [ "$NETWORK" != "default" ] && [ -n "$NETWORK" ]; then
                        NETWORK_FLAG="--network=$NETWORK"
                    fi

                    PRIVILEGED=$(docker inspect --format='{{.HostConfig.Privileged}}' "$CONTAINER_NAME")
                    PRIVILEGED_FLAG=""
                    if [ "$PRIVILEGED" = "true" ]; then
                        PRIVILEGED_FLAG="--privileged"
                    fi

                    RUN_CMD="docker run -d --name $CONTAINER_NAME $RESTART_FLAG $NETWORK_FLAG $PRIVILEGED_FLAG $PORTS $VOLUMES $ENV_VARS $IMAGE"

                    printf "${BLUE}=== Current configuration ===${NC}\n"
                    echo "$RUN_CMD"
                    echo ""

                    printf "${BLUE}=== Volumes to preserve ===${NC}\n"
                    if [ -z "$VOLUMES" ]; then
                        printf "${RED}  (none - WARNING: container may not persist data!)${NC}\n"
                    else
                        docker inspect --format='{{range .Mounts}}  {{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$CONTAINER_NAME"
                    fi
                    echo ""

                    printf "${GREEN}=== Confirm before proceeding ===${NC}\n"
                    printf "Pull latest image and recreate container? (y/n) "
                    read -r REPLY
                    case "$REPLY" in
                        [Yy]|[Yy][Ee][Ss]) ;;
                        *)
                            echo "Cancelled."
                            printf "Press Enter to continue..."
                            read -r _dummy
                            continue
                            ;;
                    esac

                    echo ""
                    printf "${BLUE}=== Pulling latest image ===${NC}\n"
                    docker pull "$IMAGE"

                    echo ""
                    printf "${BLUE}=== Stopping container ===${NC}\n"
                    docker stop "$CONTAINER_NAME"

                    printf "${BLUE}=== Removing old container ===${NC}\n"
                    docker rm "$CONTAINER_NAME"

                    echo ""
                    printf "${BLUE}=== Creating new container ===${NC}\n"
                    eval $RUN_CMD

                    echo ""
                    printf "${GREEN}=== Upgrade complete! ===${NC}\n"
                    docker ps --filter name="$CONTAINER_NAME"

                    set_field "$SELECTED_INDEX" "upgraded" "yes"
                    set_field "$SELECTED_INDEX" "update" "unknown"

                    scan_containers
                    echo ""
                    continue
                    ;;
            esac
            ;;

        *)
            printf "${RED}Invalid option${NC}\n"
            ;;
    esac
done
