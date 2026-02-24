# Docker Upgrade Containers Function
# -----------------------------------
# Usage: docker-upgrade-containers
#
# Interactive Docker container upgrade tool
# Handles both standalone containers and docker-compose managed containers

docker_upgrade_containers() {
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

  # Function to get cache file path for an image
  get_cache_file() {
      local image=$1
      # Create a safe filename from the image name
      local safe_name=$(echo "$image" | sed 's/[^a-zA-Z0-9._-]/_/g')
      echo "$CACHE_DIR/$safe_name.cache"
  }

  # Function to check if cache is valid (less than 5 minutes old)
  is_cache_valid() {
      local cache_file=$1

      if [ ! -f "$cache_file" ]; then
          return 1  # Cache doesn't exist
      fi

      local cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
      local current_time=$(date +%s)
      local age=$((current_time - cache_time))

      if [ $age -lt $CACHE_VALIDITY_SECONDS ]; then
          return 0  # Cache is valid
      else
          return 1  # Cache is expired
      fi
  }

  # Function to read cache result
  read_cache() {
      local cache_file=$1
      if [ -f "$cache_file" ]; then
          cat "$cache_file"
      fi
  }

  # Function to write cache result
  write_cache() {
      local cache_file=$1
      local result=$2
      echo "$result" > "$cache_file"
  }

  echo -e "${BLUE}=== Docker Container Upgrade Tool ===${NC}"
  echo ""

  # Get list of all containers
  ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")

  if [ -z "$ALL_CONTAINERS" ]; then
      echo "No Docker containers found"
      exit 0
  fi

  # Build arrays for containers and compose projects
  declare -a ITEM_ARRAY  # Can be container name or compose project
  declare -a ITEM_TYPE_ARRAY  # "standalone" or "compose:projectname"
  declare -a UPDATE_AVAILABLE_ARRAY
  declare -a UPDATE_COUNT_ARRAY  # Track "X/Y" format for compose projects (X=needs update, Y=total)
  declare -a RECENTLY_UPGRADED_ARRAY  # Track which items were recently upgraded
  declare -A COMPOSE_PROJECTS  # Track unique compose projects
  declare -A COMPOSE_DIRS  # Track compose directories
  declare -A COMPOSE_FILES  # Track compose files

  # Function to check Docker registry authentication
  check_docker_auth() {
      local registry=${1:-"docker.io"}

      # Try to get auth info from docker config
      if docker system info 2>/dev/null | grep -q "Username:"; then
          return 0  # Authenticated
      fi

      # Check if we can access the registry with skopeo
      if timeout 10 skopeo inspect --command-timeout 10s docker://${registry}/library/alpine:latest &>/dev/null; then
          return 0  # Can access (either authenticated or anonymous works)
      fi

      return 1  # Not authenticated or can't access
  }

  # Function to prompt for Docker registry login
  prompt_docker_login() {
      echo ""
      echo -e "${YELLOW}⚠️  Docker Registry Authentication${NC}"
      echo ""
      echo "To avoid rate limiting and timeouts, it's recommended to authenticate with Docker registries."
      echo ""
      echo "Docker Hub (docker.io) limits anonymous requests to 100 pulls per 6 hours."
      echo "Authenticated users get 200 pulls per 6 hours (free tier) or unlimited (paid)."
      echo ""
      read -p "Would you like to log in to Docker Hub now? (y/n) " -n 1 -r
      echo

      if [[ $REPLY =~ ^[Yy]$ ]]; then
          echo ""
          echo -e "${BLUE}=== Logging in to Docker Hub ===${NC}"
          echo ""

          # Try docker login first
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

  # Function to check if update is available using skopeo
  check_update_available() {
      local image=$1
      local timeout=${SKOPEO_TIMEOUT:-30}
      local max_retries=${SKOPEO_RETRIES:-3}

      # Check cache first
      local cache_file=$(get_cache_file "$image")
      if is_cache_valid "$cache_file"; then
          local cached_result=$(read_cache "$cache_file")
          return $cached_result
      fi

      # Get local image digest
      local local_digest=$(docker inspect --type=image --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null | cut -d'@' -f2)

      # If no local digest, might be a locally built image
      if [ -z "$local_digest" ]; then
          write_cache "$cache_file" 2
          return 2  # Unknown/can't check
      fi

      # Get remote digest using skopeo with timeout and retries
      local remote_digest=""
      local retry=0

      while [ $retry -le $max_retries ]; do
          if [ $retry -gt 0 ]; then
              echo -n "(retry $retry/$max_retries) "
          fi

          # Use timeout command to enforce time limit on skopeo
          # Give outer timeout extra buffer (timeout + 5 seconds) to let skopeo handle timeout gracefully
          remote_digest=$(timeout $((timeout)) skopeo inspect --command-timeout ${timeout}s docker://"$image" 2>/dev/null | jq -r '.Digest' 2>/dev/null)

          # Check if we got a valid result
          if [ -n "$remote_digest" ] && [ "$remote_digest" != "null" ]; then
              break
          fi

          retry=$((retry + 1))

          # Don't sleep after the last retry
          # if [ $retry -le $max_retries ]; then
          #     sleep 1
          # fi
      done

      if [ -z "$remote_digest" ] || [ "$remote_digest" == "null" ]; then
          write_cache "$cache_file" 2
          return 2  # Error checking remote (timeout or other error)
      fi

      if [ "$local_digest" != "$remote_digest" ]; then
          write_cache "$cache_file" 0
          return 0  # Update available
      else
          write_cache "$cache_file" 1
          return 1  # Up to date
      fi
  }

  # Function to check update for a single image in background
  check_update_async() {
      local image=$1

      # Check if cache is already valid
      local cache_file=$(get_cache_file "$image")
      if is_cache_valid "$cache_file"; then
          return  # Cache is still valid, no need to check
      fi

      # Run check in background with short timeout (output suppressed)
      # Background checks use 5 second timeout - they run early and cache results
      (SKOPEO_TIMEOUT=5 SKOPEO_RETRIES=1 check_update_available "$image" &>/dev/null) &
  }

  # Function to scan containers (can be called to refresh the list)
  scan_containers() {
      # Save previous state
      declare -A OLD_UPDATE_STATUS
      declare -A OLD_UPGRADED_STATUS

      for i in "${!ITEM_ARRAY[@]}"; do
          OLD_UPDATE_STATUS["${ITEM_ARRAY[$i]}"]="${UPDATE_AVAILABLE_ARRAY[$i]}"
          OLD_UPGRADED_STATUS["${ITEM_ARRAY[$i]}"]="${RECENTLY_UPGRADED_ARRAY[$i]}"
      done

      # Clear existing arrays
      ITEM_ARRAY=()
      ITEM_TYPE_ARRAY=()
      UPDATE_AVAILABLE_ARRAY=()
      UPDATE_COUNT_ARRAY=()
      RECENTLY_UPGRADED_ARRAY=()
      COMPOSE_PROJECTS=()

      echo "Scanning containers..."

      # Get updated list of containers
      ALL_CONTAINERS=$(docker ps -a --format "{{.Names}}")

      # Collect standalone containers and group compose projects
      while IFS= read -r container; do
          COMPOSE_PROJECT=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || echo "")

          if [ -n "$COMPOSE_PROJECT" ]; then
              # This is a compose-managed container
              if [ -z "${COMPOSE_PROJECTS[$COMPOSE_PROJECT]}" ]; then
                  # First time seeing this project - add it
                  COMPOSE_PROJECTS[$COMPOSE_PROJECT]=1
                  ITEM_ARRAY+=("$COMPOSE_PROJECT")
                  ITEM_TYPE_ARRAY+=("compose:$COMPOSE_PROJECT")

                  # Restore previous status if available
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

                  # Store compose directory and files
                  COMPOSE_DIRS[$COMPOSE_PROJECT]=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container")
                  COMPOSE_FILES[$COMPOSE_PROJECT]=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container")
              fi
          else
              # Standalone container
              ITEM_ARRAY+=("$container")
              ITEM_TYPE_ARRAY+=("standalone")

              # Restore previous status if available
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

  # Initial scan
  scan_containers

  # Function to start async update checks for all containers
  start_async_checks() {
      # Only start if skopeo and jq are available
      if ! command -v skopeo &> /dev/null || ! command -v jq &> /dev/null; then
          return
      fi

      # Start async checks for all images
      for i in "${!ITEM_ARRAY[@]}"; do
          ITEM="${ITEM_ARRAY[$i]}"
          ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

          if [[ "$ITEM_TYPE" == "compose:"* ]]; then
              # Check all images in the compose project
              PROJECT_NAME="${ITEM_TYPE#compose:}"
              IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

              while IFS= read -r image; do
                  check_update_async "$image"
              done <<< "$IMAGES"
          else
              # Standalone container
              CONTAINER="$ITEM"
              IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
              if [ -n "$IMAGE" ]; then
                  check_update_async "$IMAGE"
              fi
          fi
      done
  }

  # Start async checks in the background immediately (non-blocking)
  # This happens before showing the menu, so checks run while user is deciding
  if command -v skopeo &> /dev/null && command -v jq &> /dev/null; then
      echo "Starting background update checks..."
      start_async_checks
      echo ""
  fi

  # Function to display the table
  display_table() {
      echo "Available containers to upgrade:"
      echo ""

      # Print header
      printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
          "No." "Name" "Image" "Status" "Type" "Update"

      # Print separator
      printf "%-4s  %-35s  %-50s  %-12s  %-35s  %-20s\n" \
          "----" "-----------------------------------" "--------------------------------------------------" "------------" "-----------------------------------" "--------------------"

      for i in "${!ITEM_ARRAY[@]}"; do
          ITEM="${ITEM_ARRAY[$i]}"
          ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

          if [[ "$ITEM_TYPE" == "compose:"* ]]; then
              # Compose project - get info from first container in project
              PROJECT_NAME="${ITEM_TYPE#compose:}"

              # Find containers in this project
              CONTAINER_COUNT=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Names}}" | wc -l)

              # Get first container for status
              FIRST_CONTAINER=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Names}}" | head -n 1)

              if [ -n "$FIRST_CONTAINER" ]; then
                  STATUS=$(docker inspect --format='{{.State.Status}}' "$FIRST_CONTAINER")

                  # Get all unique images in this project
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
              # Standalone container
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

          # Format update column with extra spacing
          UPDATE_STATUS="${UPDATE_AVAILABLE_ARRAY[$i]}"
          UPGRADED_STATUS="${RECENTLY_UPGRADED_ARRAY[$i]}"
          UPDATE_COUNT="${UPDATE_COUNT_ARRAY[$i]}"

          # Check if recently upgraded
          if [ "$UPGRADED_STATUS" == "yes" ]; then
              UPDATE_STR="  🔄 Just upgraded"
              UPDATE_COLOR="${BLUE}"
          elif [ "$UPDATE_STATUS" == "yes" ]; then
              if [ -n "$UPDATE_COUNT" ]; then
                  UPDATE_STR="  ⬆ $UPDATE_COUNT need update"
              else
                  UPDATE_STR="  ⬆ Available"
              fi
              UPDATE_COLOR="${YELLOW}"
          elif [ "$UPDATE_STATUS" == "no" ]; then
              if [ -n "$UPDATE_COUNT" ]; then
                  # Parse X/Y format and show Y (total) or (Y-X) for up to date count
                  if [[ "$UPDATE_COUNT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
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

          # Print row with colors - separate printf calls to handle color codes properly
          NUM_COL="$((i+1))"
          printf "%-4s  " "$NUM_COL"
          printf "${TYPE_COLOR}%-35s${NC}  " "$DISPLAY_NAME"
          printf "%-50s  " "$DISPLAY_IMAGE"
          printf "%-12s  " "$STATUS"
          printf "${TYPE_COLOR}%-35s${NC}  " "$TYPE_STR"
          printf "${UPDATE_COLOR}%-20s${NC}\n" "$UPDATE_STR"
      done
  }

  # Function to reload update status from cache (silent version)
  reload_cache_status() {
      for i in "${!ITEM_ARRAY[@]}"; do
          ITEM="${ITEM_ARRAY[$i]}"
          ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

          if [[ "$ITEM_TYPE" == "compose:"* ]]; then
              # Check all images in the compose project
              PROJECT_NAME="${ITEM_TYPE#compose:}"
              IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

              HAS_UPDATE=false
              HAS_CACHED_DATA=false
              UPDATE_COUNT=0
              TOTAL_COUNT=0

              while IFS= read -r image; do
                  cache_file=$(get_cache_file "$image")
                  TOTAL_COUNT=$((TOTAL_COUNT + 1))

                  if is_cache_valid "$cache_file"; then
                      HAS_CACHED_DATA=true
                      cached_result=$(read_cache "$cache_file")
                      if [ "$cached_result" == "0" ]; then
                          HAS_UPDATE=true
                          UPDATE_COUNT=$((UPDATE_COUNT + 1))
                      fi
                  fi
              done <<< "$IMAGES"

              # Store the count
              UPDATE_COUNT_ARRAY[$i]="$UPDATE_COUNT/$TOTAL_COUNT"

              if [ "$HAS_CACHED_DATA" = true ]; then
                  if [ "$HAS_UPDATE" = true ]; then
                      UPDATE_AVAILABLE_ARRAY[$i]="yes"
                  else
                      UPDATE_AVAILABLE_ARRAY[$i]="no"
                  fi
              fi
          else
              # Standalone container
              CONTAINER="$ITEM"
              IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)

              if [ -n "$IMAGE" ]; then
                  cache_file=$(get_cache_file "$IMAGE")
                  if is_cache_valid "$cache_file"; then
                      cached_result=$(read_cache "$cache_file")
                      if [ "$cached_result" == "0" ]; then
                          UPDATE_AVAILABLE_ARRAY[$i]="yes"
                          UPDATE_COUNT_ARRAY[$i]="1/1"
                      elif [ "$cached_result" == "1" ]; then
                          UPDATE_AVAILABLE_ARRAY[$i]="no"
                          UPDATE_COUNT_ARRAY[$i]="0/1"
                      elif [ "$cached_result" == "2" ]; then
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

  # Main loop - allows multiple operations
  while true; do
      echo ""

      # Reload cache status before displaying (to pick up async check results)
      reload_cache_status

      # Display the table
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
      read -p "Select option: " CHECK_OPTION

      if [[ "$CHECK_OPTION" == "q" ]] || [[ "$CHECK_OPTION" == "Q" ]]; then
          echo "Exiting..."
          exit 0
      fi

      if [[ "$CHECK_OPTION" == "4" ]]; then
          # Reload update status from cache
          echo ""
          echo "Reloading update status from cache..."
          echo ""

          for i in "${!ITEM_ARRAY[@]}"; do
              ITEM="${ITEM_ARRAY[$i]}"
              ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

              if [[ "$ITEM_TYPE" == "compose:"* ]]; then
                  # Check all images in the compose project
                  PROJECT_NAME="${ITEM_TYPE#compose:}"
                  IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

                  HAS_UPDATE=false
                  HAS_CACHED_DATA=false
                  while IFS= read -r image; do
                      cache_file=$(get_cache_file "$image")
                      if is_cache_valid "$cache_file"; then
                          HAS_CACHED_DATA=true
                          cached_result=$(read_cache "$cache_file")
                          if [ "$cached_result" == "0" ]; then
                              HAS_UPDATE=true
                          fi
                      fi
                  done <<< "$IMAGES"

                  if [ "$HAS_CACHED_DATA" = true ]; then
                      if [ "$HAS_UPDATE" = true ]; then
                          UPDATE_AVAILABLE_ARRAY[$i]="yes"
                      else
                          UPDATE_AVAILABLE_ARRAY[$i]="no"
                      fi
                  else
                      UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                  fi
              else
                  # Standalone container
                  CONTAINER="$ITEM"
                  IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)

                  if [ -n "$IMAGE" ]; then
                      cache_file=$(get_cache_file "$IMAGE")
                      if is_cache_valid "$cache_file"; then
                          cached_result=$(read_cache "$cache_file")
                          if [ "$cached_result" == "0" ]; then
                              UPDATE_AVAILABLE_ARRAY[$i]="yes"
                          elif [ "$cached_result" == "1" ]; then
                              UPDATE_AVAILABLE_ARRAY[$i]="no"
                          else
                              UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                          fi
                      else
                          UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                      fi
                  else
                      UPDATE_AVAILABLE_ARRAY[$i]="unknown"
                  fi
              fi

              # Clear the "just upgraded" status when reloading from cache
              RECENTLY_UPGRADED_ARRAY[$i]="no"
          done

          echo -e "${GREEN}✓ Update status reloaded from cache${NC}"
          echo ""
          continue
      fi

      if [[ "$CHECK_OPTION" == "2" ]] || [[ "$CHECK_OPTION" == "3" ]]; then
          # Determine if we should ignore cache
          IGNORE_CACHE=false
          if [[ "$CHECK_OPTION" == "3" ]]; then
              IGNORE_CACHE=true
              echo ""
              echo -e "${YELLOW}Force checking (ignoring cache)...${NC}"
          fi

          # Check if skopeo is installed
          if ! command -v skopeo &> /dev/null; then
              echo ""
              echo -e "${RED}❌ Error: skopeo is not installed${NC}"
              echo ""
              echo "skopeo is required to check for updates without pulling images."
              echo ""
              echo "To install skopeo, run:"
              echo -e "${GREEN}  sudo apt-get install skopeo${NC}"
              echo ""
              echo "Or on other systems:"
              echo "  - Fedora/RHEL: sudo dnf install skopeo"
              echo "  - macOS: brew install skopeo"
              echo ""
              read -p "Press Enter to return to main menu..."
              continue
          fi

          # Check if jq is installed
          if ! command -v jq &> /dev/null; then
              echo ""
              echo -e "${RED}❌ Error: jq is not installed${NC}"
              echo ""
              echo "jq is required to parse skopeo output."
              echo ""
              echo "To install jq, run:"
              echo -e "${GREEN}  sudo apt-get install jq${NC}"
              echo ""
              read -p "Press Enter to return to main menu..."
              continue
          fi

          # Check Docker authentication status
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

          for i in "${!ITEM_ARRAY[@]}"; do
              ITEM="${ITEM_ARRAY[$i]}"
              ITEM_TYPE="${ITEM_TYPE_ARRAY[$i]}"

              echo -n "[$((i+1))/${#ITEM_ARRAY[@]}] Checking $ITEM... "

              if [[ "$ITEM_TYPE" == "compose:"* ]]; then
                  # Check all images in the compose project
                  PROJECT_NAME="${ITEM_TYPE#compose:}"
                  IMAGES=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "{{.Image}}" | sort -u)

                  # Count unique images
                  IMAGE_COUNT=$(echo "$IMAGES" | wc -l)
                  echo ""
                  echo "  Checking $IMAGE_COUNT images for $PROJECT_NAME:"

                  HAS_UPDATE=false
                  UPDATE_COUNT=0
                  TOTAL_COUNT=0
                  IMG_NUM=0
                  while IFS= read -r image; do
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

                  # Store the count
                  UPDATE_COUNT_ARRAY[$i]="$UPDATE_COUNT/$TOTAL_COUNT"

                  echo -n "[$((i+1))/${#ITEM_ARRAY[@]}] $ITEM overall: "
                  if [ "$HAS_UPDATE" = true ]; then
                      UPDATE_AVAILABLE_ARRAY[$i]="yes"
                      echo -e "${YELLOW}UPDATE AVAILABLE${NC}"
                  else
                      UPDATE_AVAILABLE_ARRAY[$i]="no"
                      echo -e "${GREEN}UP TO DATE${NC}"
                  fi

                  # Clear the "just upgraded" status after checking
                  RECENTLY_UPGRADED_ARRAY[$i]="no"
              else
                  # Standalone container
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

                  # Clear the "just upgraded" status after checking
                  RECENTLY_UPGRADED_ARRAY[$i]="no"
              fi

              sleep 0.1
          done

          # Clear the progress messages and redraw final table
          echo ""
          echo "Update check complete! Refreshing table..."
          sleep 1

          # Clear from "Checking for updates..." message onward
          lines_to_clear=$((${#ITEM_ARRAY[@]} + 5))
          for ((i=0; i<lines_to_clear; i++)); do
              tput cuu1
              tput el
          done

          echo ""
          continue
      fi

      if [[ "$CHECK_OPTION" == "1" ]]; then
          echo ""
          read -p "Select number to upgrade (or 'q' to cancel): " SELECTION

          # Handle quit
          if [[ "$SELECTION" == "q" ]] || [[ "$SELECTION" == "Q" ]]; then
              continue
          fi

          # Validate selection
          if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#ITEM_ARRAY[@]}" ]; then
              echo -e "${RED}Error: Invalid selection${NC}"
              read -p "Press Enter to continue..."
              continue
          fi

          # Get selected item
          SELECTED_ITEM="${ITEM_ARRAY[$((SELECTION-1))]}"
          SELECTED_TYPE="${ITEM_TYPE_ARRAY[$((SELECTION-1))]}"
          SELECTED_INDEX=$((SELECTION-1))

          echo ""
          echo -e "${BLUE}=== Upgrading: $SELECTED_ITEM ===${NC}"
          echo ""

          # Check if this is a compose-managed project
          if [[ "$SELECTED_TYPE" == "compose:"* ]]; then
              PROJECT_NAME="${SELECTED_TYPE#compose:}"
              echo -e "Type: 📦 ${CYAN}Docker Compose${NC}"

              COMPOSE_DIR="${COMPOSE_DIRS[$PROJECT_NAME]}"
              COMPOSE_FILE="${COMPOSE_FILES[$PROJECT_NAME]}"

              echo "Project: $PROJECT_NAME"
              echo "Directory: $COMPOSE_DIR"
              echo "Config files: $COMPOSE_FILE"

              # List all services in this project
              echo ""
              echo "Services in this project:"
              docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format "  - {{.Names}} ({{.Image}})"
              echo ""

              # Verify compose directory exists
              if [ -z "$COMPOSE_DIR" ] || [ ! -d "$COMPOSE_DIR" ]; then
                  echo -e "${RED}⚠️  Cannot find compose directory automatically${NC}"
                  read -p "Enter the compose directory path: " COMPOSE_DIR

                  if [ ! -d "$COMPOSE_DIR" ]; then
                      echo -e "${RED}❌ Directory not found: $COMPOSE_DIR${NC}"
                      read -p "Press Enter to continue..."
                      continue
                  fi
              fi

              # Check for compose file
              if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
                  COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
                  if [ ! -f "$COMPOSE_FILE" ]; then
                      COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yaml"
                      if [ ! -f "$COMPOSE_FILE" ]; then
                          echo -e "${RED}❌ No docker-compose.yml found in $COMPOSE_DIR${NC}"
                          read -p "Press Enter to continue..."
                          continue
                      fi
                  fi
              fi

              echo -e "${GREEN}✓ Found compose file: $COMPOSE_FILE${NC}"
              echo ""

              # Detect docker-compose command
              if command -v docker-compose &> /dev/null; then
                  COMPOSE_CMD="docker-compose"
              elif docker compose version &> /dev/null; then
                  COMPOSE_CMD="docker compose"
              else
                  echo -e "${RED}❌ Neither 'docker-compose' nor 'docker compose' found${NC}"
                  read -p "Press Enter to continue..."
                  continue
              fi

              echo "Using command: $COMPOSE_CMD"
              echo ""

              # Confirm before proceeding
              read -p "Pull images and recreate ALL services in this project? (y/n) " -n 1 -r
              echo
              if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                  echo "Cancelled."
                  read -p "Press Enter to continue..."
                  continue
              fi

              # Execute docker-compose upgrade
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

              # Mark as recently upgraded
              RECENTLY_UPGRADED_ARRAY[$SELECTED_INDEX]="yes"
              UPDATE_AVAILABLE_ARRAY[$SELECTED_INDEX]="unknown"

              # Rescan containers to refresh the list
              scan_containers

              echo ""
              continue

          else
              # Standalone container upgrade
              CONTAINER_NAME="$SELECTED_ITEM"
              echo -e "Type: 🐳 ${PURPLE}Standalone${NC}"
              echo ""

              # Get the image name
              IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME")
              echo "Image: $IMAGE"
              echo ""

              # Get port mappings
              PORTS=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $conf}}-p {{.HostIP}}{{if .HostIP}}:{{end}}{{.HostPort}}:{{$p}} {{end}}{{end}}{{end}}' "$CONTAINER_NAME")

              # Get volume mounts
              VOLUMES=$(docker inspect --format='{{range .Mounts}}-v {{.Source}}:{{.Destination}}{{if .Mode}}:{{.Mode}}{{end}} {{end}}' "$CONTAINER_NAME")

              # Get environment variables
              ENV_VARS=$(docker inspect --format='{{range .Config.Env}}-e "{{.}}" {{end}}' "$CONTAINER_NAME")

              # Get restart policy
              RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")
              if [ "$RESTART" != "no" ] && [ -n "$RESTART" ]; then
                  RESTART_FLAG="--restart=$RESTART"
              else
                  RESTART_FLAG=""
              fi

              # Get network mode
              NETWORK=$(docker inspect --format='{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
              if [ "$NETWORK" != "default" ] && [ -n "$NETWORK" ]; then
                  NETWORK_FLAG="--network=$NETWORK"
              else
                  NETWORK_FLAG=""
              fi

              # Get additional flags
              PRIVILEGED=$(docker inspect --format='{{.HostConfig.Privileged}}' "$CONTAINER_NAME")
              if [ "$PRIVILEGED" = "true" ]; then
                  PRIVILEGED_FLAG="--privileged"
              else
                  PRIVILEGED_FLAG=""
              fi

              # Build the complete run command
              RUN_CMD="docker run -d --name $CONTAINER_NAME $RESTART_FLAG $NETWORK_FLAG $PRIVILEGED_FLAG $PORTS $VOLUMES $ENV_VARS $IMAGE"

              echo -e "${BLUE}=== Current configuration ===${NC}"
              echo "$RUN_CMD"
              echo ""

              # Show volumes being preserved
              echo -e "${BLUE}=== Volumes to preserve ===${NC}"
              if [ -z "$VOLUMES" ]; then
                  echo -e "${RED}  (none - WARNING: container may not persist data!)${NC}"
              else
                  docker inspect --format='{{range .Mounts}}  {{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$CONTAINER_NAME"
              fi
              echo ""

              # Confirm before proceeding
              echo -e "${GREEN}=== Confirm before proceeding ===${NC}"
              read -p "Pull latest image and recreate container? (y/n) " -n 1 -r
              echo
              if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                  echo "Cancelled."
                  read -p "Press Enter to continue..."
                  continue
              fi

              # Pull the latest image
              echo ""
              echo -e "${BLUE}=== Pulling latest image ===${NC}"
              docker pull "$IMAGE"

              # Stop and remove the old container
              echo ""
              echo -e "${BLUE}=== Stopping container ===${NC}"
              docker stop "$CONTAINER_NAME"

              echo -e "${BLUE}=== Removing old container ===${NC}"
              docker rm "$CONTAINER_NAME"

              # Create the new container
              echo ""
              echo -e "${BLUE}=== Creating new container ===${NC}"
              eval $RUN_CMD

              echo ""
              echo -e "${GREEN}=== Upgrade complete! ===${NC}"
              docker ps --filter name="$CONTAINER_NAME"

              # Mark as recently upgraded
              RECENTLY_UPGRADED_ARRAY[$SELECTED_INDEX]="yes"
              UPDATE_AVAILABLE_ARRAY[$SELECTED_INDEX]="unknown"

              # Rescan containers to refresh the list
              scan_containers

              echo ""
              continue
          fi
      fi

      # Invalid option
      echo -e "${RED}Invalid option${NC}"
  done

}

