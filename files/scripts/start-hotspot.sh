#!/bin/bash
#
# start-hotspot.sh - Put the Pi on a network at boot, or ask for one.
#
# Tried in order:
#   1. The Wi-Fi network in /mnt/data/wifi.conf, if one is configured.
#   2. The hotspot in that same file, if the operator asked for one.
#   3. A recovery hotspot serving the Wi-Fi setup page.
#
# Step 3 is the normal path for a fresh device: it has no wifi.conf at all, so
# it raises a hotspot you can join and hands you a page to enter Wi-Fi details.
# It is also where a device lands when its configured network has moved or the
# password has changed.
#
# The quiz server starts in every case, so the device is useful even with no
# network configuration at all.

set -u

# shellcheck source=/dev/null
. "${WIFI_LIB:-/usr/local/bin/wifi-lib.sh}"

VENV_PATH="${VENV_PATH:-/home/oduvan/venv_webquiz}"

start_webserver() {
  log "Starting web server and webquiz application"
  python3 /usr/local/bin/create_index_html.py
  # shellcheck source=/dev/null
  source "$VENV_PATH/bin/activate" && \
    webquiz --config /mnt/data/webquiz/server.conf --url-format "http://{IP}/webquiz/" &
}

start_setup_page() {
  log "Starting the Wi-Fi setup page"
  # Point the captive portal at the setup page rather than the file listing.
  recovery_marker_on
  if ! systemctl start wifi-setup-server.service; then
    err "Could not start wifi-setup-server.service"
    return 1
  fi
  return 0
}

# Does this device need to ask for Wi-Fi details?
#   yes - no config at all, or a configured network we could not join
#   no  - connected, or the operator deliberately asked for hotspot-only mode
need_setup=0

# --- Step 1: the configured Wi-Fi network -----------------------------------
if [ -f "$ACTIVE_CONF" ]; then
  log "Found config: $ACTIVE_CONF"
  # shellcheck source=/dev/null
  . "$ACTIVE_CONF"

  log "Configuration summary:"
  [ -n "${SSID:-}" ] && log "  WiFi Client: $SSID"
  [ -n "${HOTSPOT_SSID:-}" ] && log "  Hotspot: $HOTSPOT_SSID"

  if [ -n "${SSID:-}" ] && [ -n "${PASSWORD:-}" ]; then
    if wifi_connect "$SSID" "$PASSWORD"; then
      log "WiFi client connection successful, starting webserver"
      # The device is on a network, so clear any leftover setup redirect.
      recovery_marker_off
      start_webserver
      exit 0
    fi
    warn "WiFi client connection failed; will ask for new details"
    wifi_release "$SSID"
    need_setup=1
  elif [ -n "${SSID:-}" ]; then
    warn "SSID is set but PASSWORD is missing - will ask for new details"
    need_setup=1
  fi
else
  warn "Config file not found: $ACTIVE_CONF"
  log "This device has no network configured yet"
  need_setup=1
fi

# --- Step 2 and 3: raise a hotspot ------------------------------------------
# recovery_hotspot() prefers the operator's own HOTSPOT_SSID when wifi.conf set
# one, so a configured device keeps the hotspot name its owner chose.
hotspot_line="$(recovery_hotspot)"
hotspot_ssid="${hotspot_line%%$'\t'*}"
hotspot_pass="${hotspot_line#*$'\t'}"

log "Starting hotspot '$hotspot_ssid'"
if hotspot_up "$hotspot_ssid" "$hotspot_pass"; then
  if [ "$need_setup" -eq 1 ]; then
    start_setup_page
  else
    # Hotspot-only mode was the operator's choice, so leave the captive portal
    # showing the quiz rather than the network settings. The setup page has no
    # password and students are on this network.
    log "Hotspot-only mode was configured; not starting the setup page"
    recovery_marker_off
  fi
  start_webserver
  exit 0
fi

err "Failed to create hotspot '$hotspot_ssid'"
log "Starting webserver without network setup"
start_webserver
exit 1
