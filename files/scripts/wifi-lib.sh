#!/bin/bash
#
# wifi-lib.sh - Shared Wi-Fi helpers.
#
# Sourced by start-hotspot.sh (at boot) and wifi-try.sh (when testing
# credentials from the setup page). Both need the same nmcli logic, so it lives
# here once instead of being copied into each script.
#
# This file only defines functions and defaults. Sourcing it does nothing.

ACTIVE_CONF="${ACTIVE_CONF:-/mnt/data/wifi.conf}"
SAVED_DIR="${SAVED_DIR:-/mnt/data/wifi}"
STATUS_FILE="${STATUS_FILE:-/run/wifi-setup-status.json}"
IFACE="${IFACE:-wlan0}"

# Name of the hotspot raised when there is nothing to connect to. A fresh Pi
# has no wifi.conf at all, so this name has to be fixed in code.
RECOVERY_SSID="${RECOVERY_SSID:-webquiz-setup}"

# Marker that makes nginx send captive-portal probes to the setup page instead
# of the normal file listing. Lives in the nginx root; the leading dot keeps it
# out of the generated file index.
RECOVERY_MARKER="${RECOVERY_MARKER:-/mnt/data/webfiles/.wifi-setup-redirect.html}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }

# Connect to a Wi-Fi network as a client.
#
# Reads the optional static-IP settings from the environment (IPADDR, GATEWAY,
# DNS, IPPREFIX) so callers can just source a config file first.
#
# Usage: wifi_connect <ssid> <password>
# Returns 0 once the connection is up, non-zero otherwise.
wifi_connect() {
  local ssid="$1"
  local password="$2"

  log "Attempting to connect to WiFi: $ssid on $IFACE"

  local have_static=0
  if [ -n "${IPADDR:-}" ] && [ -n "${GATEWAY:-}" ] && [ -n "${DNS:-}" ]; then
    have_static=1
    log "Static IP requested: $IPADDR (gw: $GATEWAY, dns: $DNS)"
  else
    log "No full static IP config found; will use DHCP"
  fi

  # Start from a clean profile with the same name.
  nmcli -t -f NAME connection show | grep -Fxq "$ssid" && \
    nmcli connection delete "$ssid" >/dev/null 2>&1

  # Connecting once creates the profile and stores the PSK.
  if ! nmcli dev wifi connect "$ssid" password "$password" ifname "$IFACE" name "$ssid" >/dev/null 2>&1; then
    warn "WiFi connect failed for SSID '$ssid'"
    return 1
  fi

  if [ "$have_static" -eq 1 ]; then
    local ipprefix="${IPPREFIX:-24}"
    nmcli connection modify "$ssid" \
      ipv4.addresses "$IPADDR/$ipprefix" \
      ipv4.gateway "$GATEWAY" \
      ipv4.dns "$DNS" \
      ipv4.method manual \
      ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set static IPv4"
  else
    nmcli connection modify "$ssid" \
      ipv4.method auto \
      ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set DHCP"
  fi

  if ! nmcli connection up "$ssid" >/dev/null 2>&1; then
    err "Failed to activate connection '$ssid'"
    return 1
  fi

  log "WiFi connection '$ssid' established successfully"
  return 0
}

# Raise an access point on IFACE.
#
# Usage: hotspot_up <ssid> [password]
# An empty password creates an open network.
hotspot_up() {
  local ssid="$1"
  local password="${2:-}"

  log "Creating and starting hotspot: $ssid"

  nmcli connection delete "$ssid" 2>/dev/null || true

  # Build the argument list rather than a string, so a password containing
  # spaces survives.
  #
  # For an open network the security settings must be left out ALTOGETHER.
  # "wifi-sec.key-mgmt none" does not mean "open" to NetworkManager, it means
  # WEP with a static key: the profile is created, then activation fails with
  # "Secrets were required, but not provided" and the hotspot never comes up.
  local -a args=(
    connection add type wifi ifname "$IFACE" con-name "$ssid" autoconnect no
    wifi.mode ap wifi.ssid "$ssid"
    ipv4.method shared
    ipv6.method ignore
  )

  if [ -n "$password" ]; then
    args+=(wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password")
    log "Hotspot will be password-protected"
  else
    warn "Hotspot will be OPEN (no password)"
  fi

  if ! nmcli "${args[@]}"; then
    warn "Failed to create hotspot connection"
    return 1
  fi

  if ! nmcli connection up "$ssid"; then
    warn "Could not bring up hotspot '$ssid'"
    return 1
  fi

  log "Hotspot '$ssid' created and started successfully"
  return 0
}

# Drop whatever is currently on the radio, so the next attempt starts clean.
wifi_release() {
  local name="${1:-}"
  [ -n "$name" ] && nmcli connection down "$name" >/dev/null 2>&1
  [ -n "$name" ] && nmcli connection delete "$name" >/dev/null 2>&1
  nmcli device disconnect "$IFACE" >/dev/null 2>&1
  return 0
}

# Stop saved Wi-Fi profiles from reconnecting on their own.
#
# A device that has been on a network still has its NetworkManager profile with
# autoconnect enabled. With no wifi.conf that profile reconnects by itself, so
# "no configuration" would not actually mean "no network": the radio is taken
# and the setup hotspot can never come up. Call this before raising a hotspot.
#
# Only touched when we are about to raise a hotspot, so a normal boot that
# connects to Wi-Fi keeps autoconnect as a safety net.
wifi_autoconnect_off() {
  local uuid
  while read -r uuid; do
    [ -n "$uuid" ] || continue
    log "Disabling autoconnect on saved profile $uuid"
    nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null \
             | awk -F: '$2 == "802-11-wireless" { print $1 }')
  return 0
}

# Which hotspot should recovery mode raise?
#
# Prefers the operator's own HOTSPOT_SSID from the active config when there is
# one, so a Pi that has been set up keeps the name its owner chose. Falls back
# to RECOVERY_SSID for a Pi with no config at all.
#
# Echoes "<ssid>\t<password>"; the password may be empty for an open network.
recovery_hotspot() {
  if [ -n "${HOTSPOT_SSID:-}" ]; then
    printf '%s\t%s\n' "$HOTSPOT_SSID" "${HOTSPOT_PASSWORD:-}"
  else
    printf '%s\t%s\n' "$RECOVERY_SSID" ""
  fi
}

# Write the machine-readable status the setup page polls.
#
# Usage: status_write <state> <ssid> <message> [ip]
# state is one of: running, ok, failed
status_write() {
  local state="$1" ssid="$2" message="$3" ip="${4:-}"
  local dir
  dir="$(dirname "$STATUS_FILE")"
  mkdir -p "$dir" 2>/dev/null || true

  # Escape the few characters that would break the JSON string literals.
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

  cat > "$STATUS_FILE" <<JSON
{
  "state": "$(esc "$state")",
  "ssid": "$(esc "$ssid")",
  "message": "$(esc "$message")",
  "ip": "$(esc "$ip")",
  "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
}

# Turn the captive-portal landing page into a redirect to the setup page.
recovery_marker_on() {
  mkdir -p "$(dirname "$RECOVERY_MARKER")" 2>/dev/null || true
  cat > "$RECOVERY_MARKER" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="0; url=/wifi/">
<title>Wi-Fi setup</title>
</head>
<body>
<p>Opening Wi-Fi setup… <a href="/wifi/">continue</a></p>
</body>
</html>
HTML
}

recovery_marker_off() {
  rm -f "$RECOVERY_MARKER" 2>/dev/null || true
}
