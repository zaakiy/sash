# Super Awesome SHell commands

`sash` stands for **S**uper **A**wesome **SH**ell commands.

It does what it says on the tin.

‼️ Bit of a warning, I use zsh, so these functions may not have been tested in other shells.

Setup:

```bash
source ./sash.sh
```

## ⏳ Countdown Timer

A Bash function to display a live countdown in `HH:MM:SS` format.

### ✅ Usage

```bash
countdown <time>
countdown 90        # 90 seconds
countdown 1h30m     # 1 hour 30 minutes
countdown 1h30m19s  # 1 hour 30 minutes 19 seconds
countdown 5m45s     # 5 minutes 45 seconds
countdown 45s       # 45 seconds
```

## 🐳 Docker Container Upgrade

An interactive Docker container upgrade tool that handles both standalone containers and docker-compose managed projects.

### ✨ Features

- **Smart Update Detection**: Checks for available updates using `skopeo` without pulling images
- **Dual Container Support**: Handles both standalone containers and docker-compose projects
- **Configuration Preservation**: Automatically preserves volumes, ports, environment variables, and other settings
- **Intelligent Caching**: 5-minute cache to avoid repeated registry checks
- **Background Checks**: Starts checking for updates in the background while you browse
- **Interactive Menu**: Color-coded status indicators and easy selection interface
- **Docker Hub Authentication**: Prompts for login to avoid rate limiting

### 📋 Requirements

- `docker` or `docker-compose` / `docker compose`
- `skopeo` - For checking image updates without pulling
- `jq` - For parsing JSON responses

Install requirements:
```bash
# Ubuntu/Debian
sudo apt-get install skopeo jq

# Fedora/RHEL
sudo dnf install skopeo jq

# macOS
brew install skopeo jq
```

### ✅ Usage

```bash
docker-upgrade-containers
```

The tool will:
1. Scan all Docker containers (standalone and compose projects)
2. Start background checks for available updates
3. Display an interactive menu with update status
4. Allow you to select and upgrade containers/projects

### 🎯 Menu Options

- **Select container to upgrade**: Choose a container or compose project to upgrade
- **Check for updates**: Check for updates (uses 5-min cache if available)
- **Force check for updates**: Ignore cache and check registry directly
- **Reload update status from cache**: Refresh the display with cached results
- **Quit**: Exit the tool

### 🔄 Update Status Indicators

- `⬆ Available` - Update available (yellow)
- `✓ Current` - Up to date (green)
- `🔄 Just upgraded` - Recently upgraded (blue)
- `...` - Checking or unknown status

### 📦 Container Types

- **🐳 Standalone**: Individual Docker containers
- **📦 Compose**: Docker Compose projects (shows service count)

### ⚠️ Important Notes

- The tool preserves all container configurations during upgrades
- For compose projects, all services are recreated together
- Volumes are automatically preserved (check the volume list before confirming)
- Authentication with Docker Hub is recommended to avoid rate limiting
