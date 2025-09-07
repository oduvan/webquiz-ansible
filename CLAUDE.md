# Ansible Pull Project for Raspberry Pi

## Project Overview
- Ansible project configured for `ansible-pull` deployment
- Target: Raspberry Pi running Bookworm OS
- Manages basic system configuration, SSH, nginx web server, and webquiz environment

## Key Files
- `site.yml` - Main playbook for ansible-pull
- `playbooks/raspberry-pi.yml` - Pi-specific tasks (SSH, nginx, user setup)
- `files/nginx/default` - Default nginx site configuration
- `inventory/localhost` - Local inventory file
- `ansible.cfg` - Project configuration

## Usage
```bash
ansible-pull -U https://github.com/oduvan/webquiz-ansible.git
```

## Current Features
- System package updates
- Essential package installation
- SSH service enablement
- Nginx web server installation and configuration
- User 'oduvan' creation with sudo access
- Python virtual environment '/home/oduvan/webquiz_env' with webquiz package
- Timezone configuration (default: UTC)