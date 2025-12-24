#!/bin/bash
# Wrapper script for ansible-pull with automatic recovery from incomplete runs

set -e

REPO_URL="https://github.com/oduvan/webquiz-ansible.git"
MARKER_FILE="/var/lib/ansible-pull-running"
CACHE_DIR="/root/.ansible/pull/$(hostname)"
LOG_FILE="/mnt/data/ansible-pull.log"

# Truncate log file at start of each run (keep only current run's output)
: > "$LOG_FILE"

echo "Starting Ansible Pull at $(date '+%Y-%m-%d %H:%M:%S')"

# Get branch from config
BRANCH=$(/usr/local/bin/get-branch.sh)

# Check if previous run was incomplete (marker file exists)
FORCE=""
if [ -f "$MARKER_FILE" ]; then
    echo "Previous run was incomplete, forcing re-run..."
    FORCE="--force"
fi

# Clean corrupted git cache if detected
if [ -d "$CACHE_DIR/.git" ] && ! git -C "$CACHE_DIR" fsck --quick 2>/dev/null; then
    echo "Corrupted git cache detected, removing..."
    rm -rf "$CACHE_DIR"
fi

# Create marker file before starting
touch "$MARKER_FILE"

# Run ansible-pull
if /usr/bin/ansible-pull -U "$REPO_URL" -C "$BRANCH" --only-if-changed --clean $FORCE site.yml; then
    # Success - remove marker file
    rm -f "$MARKER_FILE"
    echo "Ansible-pull completed successfully"
    exit 0
else
    # Failed - keep marker file for next run
    echo "Ansible-pull failed, marker file kept for retry"
    exit 1
fi
