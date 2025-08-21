# Ansible Pull Configuration for Raspberry Pi

This Ansible project is designed to be used with `ansible-pull` to configure Raspberry Pi devices running Bookworm OS.

## Usage

On your Raspberry Pi, run the following command to pull and apply the configuration:

```bash
ansible-pull -U https://github.com/yourusername/webquiz-ansible.git
```

## What it does

- Updates the package cache
- Upgrades all system packages
- Installs essential packages (git, curl, vim, htop, python3-pip)
- Enables SSH service
- Configures timezone (defaults to UTC, can be overridden)

## Customization

You can override variables by creating `group_vars/all.yml` or `host_vars/localhost.yml`:

```yaml
timezone: "America/New_York"
```

## Prerequisites

Make sure Ansible is installed on your Raspberry Pi:

```bash
sudo apt update
sudo apt install ansible git
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