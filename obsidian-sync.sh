#!/bin/bash
# obsidian-sync — Auto-sync an Obsidian vault to a git remote

SCRIPT_PATH="$(realpath "$0")"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--install] <repo-url> [vault-dir]

  repo-url   Git remote URL of your Obsidian vault repo
  vault-dir  Local path for the vault (default: ~/Documents/Obsidian Vault)

  --install  Install as a persistent systemd user service (survives terminal close)

If vault-dir does not exist, the repo will be cloned there first.
The script then watches for file changes and auto-commits/pushes to master.

Dependencies: git, inotifywait (inotify-tools)
EOF
    exit 1
}

install_service() {
    local remote_url="$1"
    local vault_dir="$2"
    local service_name="obsidian-sync"
    local service_file="$HOME/.config/systemd/user/${service_name}.service"

    mkdir -p "$HOME/.config/systemd/user"

    cat > "$service_file" <<EOF
[Unit]
Description=Obsidian Vault Auto-Sync
After=network.target

[Service]
ExecStart=${SCRIPT_PATH} ${remote_url} ${vault_dir}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$service_name"
    echo "Service installed and started."
    echo "  Status : systemctl --user status $service_name"
    echo "  Logs   : journalctl --user -u $service_name -f"
    echo "  Stop   : systemctl --user stop $service_name"
    echo "  Disable: systemctl --user disable $service_name"
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

# Clone vault if it doesn't exist yet
if [[ ! -d "$VAULT_DIR/.git" ]]; then
    echo "Cloning $REMOTE_URL → $VAULT_DIR"
    git clone "$REMOTE_URL" "$VAULT_DIR"
fi

cd "$VAULT_DIR" || { echo "Cannot enter $VAULT_DIR"; exit 1; }

# Resolve to absolute path so inotifywait works after cd
VAULT_DIR="$(pwd)"

echo "Starting sync for: $VAULT_DIR"
git pull origin "$BRANCH"

while inotifywait -r -e modify,create,delete,move "$VAULT_DIR"; do
    sleep 5
    git add .
    if ! git diff-index --quiet HEAD --; then
        echo "Changes detected — committing..."
        git commit -m "Auto-sync: $(date '+%Y-%m-%d %H:%M:%S')"
        git push origin "$BRANCH"
    fi
    git pull origin "$BRANCH"
done
