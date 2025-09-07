#!/bin/bash

set -euo pipefail

REPO_URL="https://github.com/oduvan/webquiz-ansible.git"
LOG_FILE="/tmp/bootstrap.log"
BRANCH="${1:-master}"  # Default to master branch if no argument provided
DATA_DIR="/mnt/data"
BRANCH_FILE="$DATA_DIR/ansible-branch"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

show_usage() {
    echo "Usage: $0 [branch]"
    echo "  branch: Git branch to use (default: master)"
    echo ""
    echo "Examples:"
    echo "  $0           # Use default 'master' branch"
    echo "  $0 develop   # Use 'develop' branch"
    echo "  $0 feature/test  # Use 'feature/test' branch"
}

# Check for help option
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

log "Starting Raspberry Pi bootstrap with ansible-pull..."

# Update package list
log "Updating package list..."
apt-get update || error "Failed to update package list"

# Install required packages
log "Installing required packages..."
apt-get install -y git ansible curl || error "Failed to install required packages"

# Verify ansible-pull is available
if ! command -v ansible-pull &> /dev/null; then
    error "ansible-pull command not found after installation"
fi

log "Running initial ansible-pull configuration..."
ansible-pull -U "$REPO_URL" -C "$BRANCH" site.yml || error "Initial ansible-pull failed"

# Save the branch to the branch file only if it's not the default branch
if [[ "$BRANCH" != "master" ]]; then
    log "Saving branch configuration for non-default branch..."
    echo "$BRANCH" > "$BRANCH_FILE" || error "Failed to save branch configuration"
    log "Branch '$BRANCH' saved to $BRANCH_FILE"
fi

log "Bootstrap completed successfully!"
log "The system is now configured and ansible-pull will run automatically."
log "Logs are available at: $LOG_FILE"
