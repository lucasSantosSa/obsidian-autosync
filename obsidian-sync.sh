#!/bin/bash
# obsidian-sync — Auto-sync an Obsidian vault to a git remote

usage() {
    cat <<EOF
Usage: $(basename "$0") <repo-url> [vault-dir]

  repo-url   Git remote URL of your Obsidian vault repo
  vault-dir  Local path for the vault (default: ~/Documents/Obsidian Vault)

If vault-dir does not exist, the repo will be cloned there first.
The script then watches for file changes and auto-commits/pushes to master.

Dependencies: git, inotifywait (inotify-tools)
EOF
    exit 1
}

REMOTE_URL="${1:-}"
VAULT_DIR="${2:-$HOME/Documents/Obsidian Vault}"
BRANCH="master"

[[ -z "$REMOTE_URL" ]] && usage

# Clone vault if it doesn't exist yet
if [[ ! -d "$VAULT_DIR/.git" ]]; then
    echo "Cloning $REMOTE_URL → $VAULT_DIR"
    git clone "$REMOTE_URL" "$VAULT_DIR"
fi

cd "$VAULT_DIR" || { echo "Cannot enter $VAULT_DIR"; exit 1; }

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
