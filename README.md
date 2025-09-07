# Ansible Pull Configuration for Raspberry Pi

This Ansible project is designed to be used with `ansible-pull` to configure Raspberry Pi devices running Bookworm OS with automatic webquiz hotspot functionality.

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

## Customization

You can override variables by creating `group_vars/all.yml` or `host_vars/localhost.yml`:

```yaml
timezone: "America/New_York"
```

## Project Structure

```
├── ansible.cfg          # Ansible configuration
├── site.yml            # Main playbook
├── inventory/
│   └── localhost       # Local inventory
├── playbooks/
│   └── raspberry-pi.yml # Pi-specific tasks
├── group_vars/         # Group variables
├── host_vars/          # Host variables
└── roles/              # Custom roles
```