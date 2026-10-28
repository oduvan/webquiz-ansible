#!/bin/bash
# Wrapper script for ansible-pull with automatic recovery from incomplete runs

set -e

REPO_URL="https://github.com/oduvan/webquiz-ansible.git"
MARKER_FILE="/var/lib/ansible-pull-running"
# Must match StandardOutput/StandardError in ansible-pull.service.
LOG_FILE="/mnt/data/ansible-pull.log"
CACHE_DIR="/root/.ansible/pull/$(hostname)"

# Get branch from config
BRANCH=$(/usr/local/bin/get-branch.sh)

# Start a fresh log for this run, keeping the previous one alongside it.
#
# The unit sends stdout and stderr here in append mode, so the file has to be
# emptied here rather than by systemd. Truncate in place instead of renaming:
# systemd opened this file before this script started, and a rename would take
# the open descriptor with it, sending this run's output into the old file.
cp "$LOG_FILE" "$LOG_FILE.prev" 2>/dev/null || true
: > "$LOG_FILE" 2>/dev/null || true

echo "=== ansible-pull run started $(date -u +'%Y-%m-%d %H:%M:%SZ') ==="
echo "=== branch: $BRANCH ==="

# Clean corrupted git cache if detected
if [ -d "$CACHE_DIR/.git" ] && ! git -C "$CACHE_DIR" fsck --quick 2>/dev/null; then
    echo "Corrupted git cache detected, removing..."
    rm -rf "$CACHE_DIR"
fi

# Check if previous run was incomplete (marker file exists)
FORCE=""
if [ -f "$MARKER_FILE" ]; then
    echo "Previous run was incomplete, forcing re-run..."
    FORCE="--force"
fi

# Create marker file before starting
touch "$MARKER_FILE"

# Run ansible-pull
if /usr/bin/ansible-pull -U "$REPO_URL" -C "$BRANCH" --clean $FORCE site.yml; then
    # Success - remove marker file
    rm -f "$MARKER_FILE"
    echo "=== ansible-pull finished successfully $(date -u +'%Y-%m-%d %H:%M:%SZ') ==="
    exit 0
else
    # Failed - keep marker file for next run
    echo "=== ansible-pull FAILED $(date -u +'%Y-%m-%d %H:%M:%SZ'), marker kept for retry ==="
    exit 1
fi
