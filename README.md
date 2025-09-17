# Ansible Pull Configuration for Raspberry Pi

This Ansible project is designed to be used with `ansible-pull` to configure Raspberry Pi devices running Bookworm OS with automatic webquiz hotspot functionality.

## Performance Features

This configuration includes several optimizations for faster execution:
- **Smart caching**: Fact caching and conditional operations reduce repeat work
- **Parallel execution**: Increased forks for faster task completion  
- **Conditional upgrades**: Only upgrade packages when needed
- **Idempotent tasks**: Skip unnecessary operations on subsequent runs
- **Optimized networking**: SSH pipelining and connection reuse

**Performance Impact**: Initial runs ~50% faster, subsequent runs ~90% faster (seconds instead of minutes).

See [PERFORMANCE.md](PERFORMANCE.md) for detailed optimization information.

## Quick Start

For a fresh Raspberry Pi, run this one-liner to bootstrap the entire system:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/oduvan/webquiz-ansible/master/bootstrap.sh)"
```

To use a specific branch:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/oduvan/webquiz-ansible/master/bootstrap.sh)" -- develop
```

## Manual Usage

If you prefer to install prerequisites manually, first install Ansible:

```bash
sudo apt update && sudo apt install ansible git
```

Then run ansible-pull:

```bash
ansible-pull -U https://github.com/oduvan/webquiz-ansible.git site.yml
```

## What it does

- Updates the package cache and upgrades all system packages
- Installs essential packages (git, curl, vim, htop, python3-pip, python3-venv)
- Enables SSH service
- Installs and configures nginx web server
- Creates user 'oduvan' with sudo access
- Sets up Python virtual environment with webquiz package
- Configures exfat partition mounting at /mnt/data
- Installs hotspot management scripts and services
- **Configures automatic ansible-pull service that runs:**
  - 5 minutes after boot
  - Every 30 minutes thereafter
  - Logs all activity to `/mnt/data/ansible-pull.log`

## Automatic Updates

After the initial setup, the system will automatically:
- Pull the latest configuration from this repository
- Apply any changes to keep the system up-to-date
- Log all ansible-pull activity to `/mnt/data/ansible-pull.log`

This ensures your Raspberry Pi stays configured correctly without manual intervention.

## Branch Configuration

The system supports configurable Git branches for ansible-pull:

- **Bootstrap with specific branch**: Pass the branch name as an argument to the bootstrap script
- **Branch persistence**: The selected branch is stored in `/mnt/data/ansible-branch`
- **Automatic updates**: The ansible-pull service reads the branch from the stored file
- **Default behavior**: Uses 'master' branch if no branch file exists

### Examples

```bash
# Bootstrap with master branch (default)
bootstrap.sh

# Bootstrap with develop branch
bootstrap.sh develop

# Bootstrap with feature branch
bootstrap.sh feature/my-feature

# Show help
bootstrap.sh --help
```

### Manual Branch Change

To change the branch on an existing system:

```bash
echo "new-branch-name" | sudo tee /mnt/data/ansible-branch
```

The next ansible-pull run will use the new branch.

## Image Pre-configuration

For automated deployment at scale, you can pre-configure Raspberry Pi OS images before flashing to SD cards using the `inject-ansible-pull.sh` script:

```bash
# Download and modify a Raspberry Pi OS image
sudo ./inject-ansible-pull.sh 2023-12-05-raspios-bookworm-arm64.img

# Use a specific branch for development
sudo ./inject-ansible-pull.sh --branch develop my-pi-image.img

# Show help
./inject-ansible-pull.sh --help
```

The script will:
1. Mount the provided Raspberry Pi OS image file
2. Inject the bootstrap script and existing ansible-pull services
3. Configure a first-boot systemd service using the existing infrastructure
4. Enable automatic ansible-pull timer for ongoing updates

**Requirements for image injection:**
- Must run as root (uses loop devices and mounting)
- Requires `losetup`, `kpartx`, `mount`, and `umount` utilities
- Image must be a valid Raspberry Pi OS Bookworm image file

After flashing the modified image to an SD card, the Raspberry Pi will automatically configure itself on first boot using ansible-pull.

## Customization

You can override variables by creating `group_vars/all.yml` or `host_vars/localhost.yml`:

```yaml
timezone: "America/New_York"
```

## Project Structure

```
├── ansible.cfg                    # Ansible configuration
├── site.yml                      # Main playbook
├── bootstrap.sh                   # Bootstrap script for fresh systems
├── inject-ansible-pull.sh         # Image injection script
├── inventory/
│   └── localhost                 # Local inventory
├── playbooks/
│   └── raspberry-pi.yml          # Pi-specific tasks
├── files/
│   ├── systemd/                  # Systemd service files
│   ├── scripts/                  # Helper scripts
│   ├── nginx/                    # Nginx configuration
│   └── webquiz/                  # Webquiz configuration
├── group_vars/                   # Group variables
├── host_vars/                    # Host variables
└── roles/                        # Custom roles
```