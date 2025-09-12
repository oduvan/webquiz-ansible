#!/bin/bash

# inject-ansible-pull.sh
# Script to inject ansible-pull bootstrap into a Raspberry Pi Bookworm OS image

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/oduvan/webquiz-ansible.git"

# Default values
BRANCH="master"
TEMP_DIR=""
LOOP_DEVICE=""
MOUNT_POINT=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <image_file>

Inject ansible-pull bootstrap into a Raspberry Pi Bookworm OS image.

Arguments:
  image_file          Path to the Raspberry Pi OS image file (.img)

Options:
  -b, --branch BRANCH Set git branch for ansible-pull (default: master)
  -h, --help          Show this help message

Examples:
  $0 2023-12-05-raspios-bookworm-arm64.img
  $0 --branch develop my-pi-image.img
  $0 -b feature/test custom-bookworm.img

This script will:
1. Mount the provided image file
2. Inject the bootstrap script that contains all setup logic
3. Configure first-boot service to run bootstrap and clean up after itself
4. Let the bootstrap script handle installing ansible-pull service and timer

Requirements:
- Must run as root (uses loop devices and mount)
- Image must be a valid Raspberry Pi OS Bookworm image
- kpartx and losetup utilities must be available

EOF
}

cleanup() {
    local exit_code=$?
    
    if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
        log "Unmounting image..."
        umount "$MOUNT_POINT" 2>/dev/null || warn "Failed to unmount $MOUNT_POINT"
        umount "${MOUNT_POINT}_boot" 2>/dev/null || warn "Failed to unmount ${MOUNT_POINT}_boot"
    fi
    
    if [[ -n "$LOOP_DEVICE" ]]; then
        log "Detaching loop device..."
        kpartx -d "$LOOP_DEVICE" 2>/dev/null || warn "Failed to remove partition mappings"
        losetup -d "$LOOP_DEVICE" 2>/dev/null || warn "Failed to detach loop device"
    fi
    
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log "Cleanup completed successfully"
    else
        error "Script failed with exit code $exit_code"
    fi
}

trap cleanup EXIT

check_requirements() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (needed for loop devices and mounting)"
        exit 1
    fi

    # Check required tools
    local tools=("losetup" "kpartx" "mount" "umount" "fdisk")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "Required tool '$tool' not found. Please install it."
            exit 1
        fi
    done

    # Check if we have the bootstrap script
    if [[ ! -f "$SCRIPT_DIR/bootstrap.sh" ]]; then
        error "bootstrap.sh not found at $SCRIPT_DIR/bootstrap.sh"
        error "Make sure you're running this script from the repository root"
        exit 1
    fi


}

validate_image() {
    local image_file="$1"
    
    if [[ ! -f "$image_file" ]]; then
        error "Image file '$image_file' not found"
        exit 1
    fi

    if [[ ! -r "$image_file" ]]; then
        error "Image file '$image_file' is not readable"
        exit 1
    fi

    # Check if it looks like a disk image
    local file_type
    file_type=$(file "$image_file")
    if [[ ! "$file_type" =~ (DOS|boot|filesystem|disk|image) ]]; then
        warn "File '$image_file' may not be a disk image: $file_type"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    log "Image file validation passed: $image_file"
}

setup_loop_device() {
    local image_file="$1"
    
    log "Setting up loop device for image..."
    LOOP_DEVICE=$(losetup -f --show "$image_file")
    if [[ -z "$LOOP_DEVICE" ]]; then
        error "Failed to create loop device for $image_file"
        exit 1
    fi
    
    log "Loop device created: $LOOP_DEVICE"
    
    # Setup partition mappings
    log "Creating partition mappings..."
    kpartx -a "$LOOP_DEVICE"
    
    # Wait a moment for devices to be created
    sleep 2
    
    # List available partitions
    log "Available partitions:"
    find /dev/mapper -name "$(basename "$LOOP_DEVICE")p*" 2>/dev/null || true
}

mount_image() {
    log "Creating temporary mount points..."
    TEMP_DIR=$(mktemp -d)
    MOUNT_POINT="$TEMP_DIR/root"
    mkdir -p "$MOUNT_POINT"
    mkdir -p "${MOUNT_POINT}_boot"
    
    # Find the root partition (usually the second partition)
    local root_partition
    local boot_partition
    root_partition="/dev/mapper/$(basename "$LOOP_DEVICE")p2"
    boot_partition="/dev/mapper/$(basename "$LOOP_DEVICE")p1"
    
    if [[ ! -e "$root_partition" ]]; then
        error "Root partition $root_partition not found"
        exit 1
    fi
    
    if [[ ! -e "$boot_partition" ]]; then
        error "Boot partition $boot_partition not found"
        exit 1
    fi
    
    log "Mounting root partition..."
    mount "$root_partition" "$MOUNT_POINT"
    
    log "Mounting boot partition..."
    mount "$boot_partition" "${MOUNT_POINT}_boot"
    
    # Verify we have a valid filesystem
    if [[ ! -d "$MOUNT_POINT/etc" ]]; then
        error "Mounted filesystem doesn't look like a Linux root filesystem (no /etc directory)"
        exit 1
    fi
    
    log "Image mounted successfully at $MOUNT_POINT"
}

inject_bootstrap() {
    log "Injecting bootstrap script into image..."
    
    # Copy bootstrap script
    cp "$SCRIPT_DIR/bootstrap.sh" "$MOUNT_POINT/usr/local/bin/bootstrap.sh"
    chmod +x "$MOUNT_POINT/usr/local/bin/bootstrap.sh"
    
    # Modify bootstrap script to use the specified branch
    if [[ "$BRANCH" != "master" ]]; then
        log "Configuring bootstrap script for branch: $BRANCH"
        sed -i "s/BRANCH=\"\${1:-master}\"/BRANCH=\"$BRANCH\"/" "$MOUNT_POINT/usr/local/bin/bootstrap.sh"
    fi
    
    log "Bootstrap script injected successfully"
}

inject_firstboot_service() {
    log "Creating first-boot service for bootstrap..."
    
    # Create a first-boot service that runs bootstrap and cleans up after itself
    cat > "$MOUNT_POINT/etc/systemd/system/ansible-firstboot.service" << EOF
[Unit]
Description=First Boot Ansible Pull Bootstrap
Documentation=https://docs.ansible.com/
After=network-online.target
Wants=network-online.target
Before=getty@tty1.service
ConditionPathExists=!/var/lib/ansible-pull-configured

[Service]
Type=oneshot
User=root
WorkingDirectory=/tmp
ExecStart=/usr/local/bin/bootstrap.sh $BRANCH
ExecStartPost=/bin/touch /var/lib/ansible-pull-configured
ExecStartPost=/bin/rm -f /usr/local/bin/bootstrap.sh
ExecStartPost=/bin/systemctl disable ansible-firstboot.service
ExecStartPost=/bin/rm -f /etc/systemd/system/ansible-firstboot.service
StandardOutput=file:/var/log/ansible-firstboot.log
StandardError=file:/var/log/ansible-firstboot.log
TimeoutSec=1800
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable the first-boot service
    mkdir -p "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants"
    ln -sf "/etc/systemd/system/ansible-firstboot.service" \
           "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/ansible-firstboot.service"
    
    log "First-boot service created and enabled"
}

verify_injection() {
    log "Verifying injection..."
    
    local errors=0
    
    # Check if bootstrap script exists and is executable
    if [[ ! -x "$MOUNT_POINT/usr/local/bin/bootstrap.sh" ]]; then
        error "Bootstrap script not found or not executable"
        ((errors++))
    fi
    
    # Check if first-boot service exists
    if [[ ! -f "$MOUNT_POINT/etc/systemd/system/ansible-firstboot.service" ]]; then
        error "ansible-firstboot.service not found"
        ((errors++))
    fi
    
    # Check if first-boot service is enabled
    if [[ ! -L "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/ansible-firstboot.service" ]]; then
        error "ansible-firstboot service not enabled"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "Verification passed - all components injected successfully"
    else
        error "Verification failed with $errors errors"
        exit 1
    fi
}

main() {
    local image_file=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -b|--branch)
                BRANCH="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$image_file" ]]; then
                    image_file="$1"
                else
                    error "Multiple image files specified"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [[ -z "$image_file" ]]; then
        error "No image file specified"
        show_usage
        exit 1
    fi
    
    # Convert to absolute path
    image_file=$(readlink -f "$image_file")
    
    log "Starting ansible-pull injection for image: $image_file"
    log "Using branch: $BRANCH"
    
    # Execute main workflow
    check_requirements
    validate_image "$image_file"
    setup_loop_device "$image_file"
    mount_image
    inject_bootstrap
    inject_firstboot_service
    verify_injection
    
    log "Ansible-pull injection completed successfully!"
    log ""
    log "The image has been modified with a bootstrap script that will run on first boot."
    log "When this image is flashed and booted on a Raspberry Pi, it will:"
    log "  1. Run the bootstrap script on first boot"
    log "  2. Install ansible and required packages"
    log "  3. Pull configuration from: $REPO_URL"
    log "  4. Use branch: $BRANCH"
    log "  5. Install and enable the ansible-pull service and timer"
    log "  6. Remove the bootstrap script and first-boot service (self-cleanup)"
    log ""
    log "First boot logs will be available at: /var/log/ansible-firstboot.log"
    log "Ongoing ansible-pull logs will be in: /mnt/data/ansible-pull.log"
}

# Run main function with all arguments
main "$@"