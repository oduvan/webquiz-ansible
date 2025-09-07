#!/bin/bash

set -euo pipefail

REPO_URL="https://github.com/oduvan/webquiz-ansible.git"
LOG_FILE="/tmp/bootstrap.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

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
ansible-pull -U "$REPO_URL" site.yml || error "Initial ansible-pull failed"

log "Bootstrap completed successfully!"
log "The system is now configured and ansible-pull will run automatically."
log "Logs are available at: $LOG_FILE"