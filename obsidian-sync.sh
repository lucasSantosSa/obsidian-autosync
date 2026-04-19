#!/bin/bash
# obsidian-sync — Auto-sync an Obsidian vault to a git remote

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || cd "$(dirname "$0")" && pwd)/$(basename "$0")"
OS="$(uname -s)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--install] <repo-url> [vault-dir]

  repo-url   Git remote URL of your Obsidian vault repo
  vault-dir  Local path for the vault (default: ~/Documents/Obsidian Vault)

  --install  Install as a persistent background service (systemd on Linux, launchd on macOS)

If vault-dir does not exist, the repo will be cloned there first.
The script then watches for file changes and auto-commits/pushes to master.

Dependencies:
  Linux : git, inotifywait (inotify-tools)
  macOS : git, fswatch (brew install fswatch)
EOF
    exit 1
}

check_deps() {
    if [[ "$OS" == "Darwin" ]]; then
        if ! command -v fswatch &>/dev/null; then
            echo "Error: fswatch not found. Install it with: brew install fswatch"
            exit 1
        fi
    else
        if ! command -v inotifywait &>/dev/null; then
            echo "Error: inotifywait not found. Install it with: sudo apt install inotify-tools"
            exit 1
        fi
    fi
}

install_service() {
    local remote_url="$1"
    local vault_dir="$2"

    if [[ "$OS" == "Darwin" ]]; then
        local plist="$HOME/Library/LaunchAgents/com.obsidian-sync.plist"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.obsidian-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_PATH}</string>
        <string>${remote_url}</string>
        <string>${vault_dir}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/obsidian-sync.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/obsidian-sync.error.log</string>
</dict>
</plist>
EOF
        launchctl unload "$plist" 2>/dev/null
        launchctl load "$plist"
        echo "Service installed and started."
        echo "  Logs   : tail -f /tmp/obsidian-sync.log"
        echo "  Stop   : launchctl unload ~/Library/LaunchAgents/com.obsidian-sync.plist"
    else
        local service_file="$HOME/.config/systemd/user/obsidian-sync.service"
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$service_file" <<EOF
[Unit]
Description=Obsidian Vault Auto-Sync
After=network.target

[Service]
ExecStart=${SCRIPT_PATH} ${remote_url} "${vault_dir}"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now obsidian-sync
        echo "Service installed and started."
        echo "  Status : systemctl --user status obsidian-sync"
        echo "  Logs   : journalctl --user -u obsidian-sync -f"
        echo "  Stop   : systemctl --user stop obsidian-sync"
        echo "  Disable: systemctl --user disable obsidian-sync"
    fi
}

watch_vault() {
    if [[ "$OS" == "Darwin" ]]; then
        fswatch -r -o "$1"
    else
        while inotifywait -r -e modify,create,delete,move "$1" >/dev/null 2>&1; do
            echo "event"
        done
    fi
}

# Parse --install flag
INSTALL=false
if [[ "${1:-}" == "--install" ]]; then
    INSTALL=true
    shift
fi

REMOTE_URL="${1:-}"
VAULT_DIR="${2:-$HOME/Documents/Obsidian Vault}"
BRANCH="master"

[[ -z "$REMOTE_URL" ]] && usage

if $INSTALL; then
    install_service "$REMOTE_URL" "$VAULT_DIR"
    exit 0
fi

check_deps

# Clone vault if it doesn't exist yet
if [[ ! -d "$VAULT_DIR/.git" ]]; then
    echo "Cloning $REMOTE_URL → $VAULT_DIR"
    git clone "$REMOTE_URL" "$VAULT_DIR"
fi

cd "$VAULT_DIR" || { echo "Cannot enter $VAULT_DIR"; exit 1; }

# Resolve to absolute path so the watcher works after cd
VAULT_DIR="$(pwd)"

safe_pull() {
    # Abort any stale rebase state before pulling
    if [[ -d ".git/rebase-merge" ]] || [[ -d ".git/rebase-apply" ]]; then
        echo "Stale rebase state found — aborting..."
        git rebase --abort 2>/dev/null || true
    fi
    git pull --rebase origin "$BRANCH"
}

echo "Starting sync for: $VAULT_DIR"
safe_pull

watch_vault "$VAULT_DIR" | while read -r _; do
    sleep 5
    git add .
    if ! git diff-index --quiet HEAD --; then
        echo "Changes detected — committing..."
        git commit -m "Auto-sync: $(date '+%Y-%m-%d %H:%M:%S')"
        git push origin "$BRANCH"
    fi
    safe_pull
done
