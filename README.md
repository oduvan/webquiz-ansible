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
- Serves a Wi-Fi setup page when the device has no network (see below)
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

## Wi-Fi Setup Page

A device with no `wifi.conf`, or one whose configured network does not answer,
starts its own hotspot and serves a page for entering Wi-Fi details. This is the
normal path for a freshly flashed card: it has no network configuration at all.

**How to use it**

1. Power the device on and wait about a minute.
2. Join the Wi-Fi network it creates. With no configuration at all this is
   **`webquiz-setup`**, open, no password. If the device already had a
   `HOTSPOT_SSID` in its config, it keeps that name and password instead.
3. A setup page should open by itself. If it does not, go to
   **http://10.42.0.1/wifi/**.
4. Pick a network you saved earlier, or press **Scan for networks** and enter
   the password. Naming it keeps it in the list for next time.
5. Check the **fixed address** this device should use. It is required, not
   optional: with a DHCP lease you would have no reliable way to reach the
   device after it reboots, and there is no second chance to ask once it has
   left the setup hotspot.

   All four boxes come prefilled so you edit rather than type. The values are
   taken from the first of these that has an address, and the form says which
   one it used:

   | Source | When |
   |--------|------|
   | This device's own active config | It has been on a network before |
   | The most recently saved network | Nothing active, but something saved |
   | `192.168.1.50` / `192.168.1.1` | A device with no history at all |

   The last row is only a shape to edit - replace it with addresses from your
   own network.
6. Press **Test and save**.

**Fixing a network that did not connect**

A network you submit is saved even when the test fails, so one wrong word does
not cost you the address fields as well. Press **Edit** on it in the saved list:
the form reloads with its name, network name and address already filled in, and
an empty password box. Type the password again and press **Test and update** -
saving under the same name replaces the old entry rather than adding a second
one. Passwords are never sent back to the browser, which is why that box starts
empty.

**What happens during a test**

The device has one radio, and the hotspot is using it. Testing credentials
means dropping that hotspot, so the page stops responding for up to a minute.
Stay joined to the hotspot; it comes back on its own, whether the test passed or
failed, and the page then shows the result.

- **Connected** - the network is written to `/mnt/data/wifi.conf` and a
  **Reboot** button appears. After the reboot the device joins the network on
  its own and the hotspot disappears.
- **Failed** - `wifi.conf` is left alone and the page explains why: the network
  was not found, or the password was refused. Try again.

**Where things are kept**

| Path | What it is |
|------|------------|
| `/mnt/data/wifi.conf` | The active network, read at boot. Only written after a successful test. |
| `/mnt/data/wifi/` | Networks you saved, one file per network, same format. |
| `/run/wifi-setup-status.json` | The result of the last test. Cleared on reboot. |

Both config formats match [`files/wifi.conf.example`](files/wifi.conf.example),
so you can also write them by hand from any computer that can read the card.
A hand-written `wifi.conf` may still leave the static-IP fields out and take a
DHCP lease; it is only the setup page that insists on a fixed address.

> **Pick an address your router will not hand out.** A static address inside the
> router's DHCP pool can be leased to another device while this one is off, and
> then two machines answer on it. That shows up as changing SSH host keys and
> both devices becoming intermittently unreachable. Either choose an address
> outside the pool, or reserve it for this device in the router.

**Note on access.** The setup page has no password: anyone who can join the
hotspot can change the device's network settings. It therefore runs *only* while
the recovery hotspot is up. It is not started when the device is on a normal
network, and not started when you asked for hotspot-only mode by setting
`HOTSPOT_SSID` without an `SSID` - in that case students are on the network and
the captive portal keeps showing the quiz.

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