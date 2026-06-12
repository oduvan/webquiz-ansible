#!/bin/bash
#
# wifi-activate.sh - Activate a saved WiFi network configuration.
#
# This script is intentionally SEPARATE from start-hotspot.sh. It is invoked
# (typically by the wifi-config-server) to switch the Pi onto a saved WiFi
# network on demand:
#
#   1. Source the given saved config file (bash env-var format, same fields as
#      files/wifi.conf.example: SSID, PASSWORD, optional IPADDR/GATEWAY/DNS/
#      IPPREFIX).
#   2. Attempt to connect with nmcli (DHCP, or static IP when all of
#      IPADDR/GATEWAY/DNS are provided).
#   3. On success, copy the saved config to the active location
#      (/mnt/data/wifi.conf) so the choice persists across reboots, then exit 0.
#   4. On failure, leave the current active config untouched and exit non-zero.
#
# Usage: wifi-activate.sh <path-to-saved-config>

set -u

ACTIVE_CONF="${ACTIVE_CONF:-/mnt/data/wifi.conf}"
IFACE="${IFACE:-wlan0}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }

CONFIG_PATH="${1:-}"

if [ -z "$CONFIG_PATH" ]; then
  err "Usage: $0 <path-to-saved-config>"
  exit 2
fi

if [ ! -f "$CONFIG_PATH" ]; then
  err "Config file not found: $CONFIG_PATH"
  exit 2
fi

# Load the saved configuration.
# shellcheck disable=SC1090
source "$CONFIG_PATH"

if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ]; then
  err "Config '$CONFIG_PATH' is missing SSID or PASSWORD"
  exit 2
fi

log "Activating WiFi network '$SSID' on $IFACE"

# Determine whether a full static IP configuration was supplied.
have_static=0
if [ -n "${IPADDR:-}" ] && [ -n "${GATEWAY:-}" ] && [ -n "${DNS:-}" ]; then
  have_static=1
  log "Static IP requested: $IPADDR (gw: $GATEWAY, dns: $DNS)"
else
  log "No full static IP config found; will use DHCP"
fi

# Start from a clean connection profile with the same name.
nmcli -t -f NAME connection show | grep -Fxq "$SSID" && \
  nmcli connection delete "$SSID" >/dev/null 2>&1

# Create the connection by connecting once (this also stores the PSK).
if ! nmcli dev wifi connect "$SSID" password "$PASSWORD" ifname "$IFACE" name "$SSID" >/dev/null 2>&1; then
  err "WiFi connect failed for SSID '$SSID'"
  nmcli connection delete "$SSID" >/dev/null 2>&1 || true
  exit 1
fi

# Apply static or DHCP addressing as requested.
if [ "$have_static" -eq 1 ]; then
  ipprefix="${IPPREFIX:-24}"
  nmcli connection modify "$SSID" \
    ipv4.addresses "$IPADDR/$ipprefix" \
    ipv4.gateway "$GATEWAY" \
    ipv4.dns "$DNS" \
    ipv4.method manual \
    ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set static IPv4"
else
  nmcli connection modify "$SSID" \
    ipv4.method auto \
    ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set DHCP"
fi

# Re-activate with the final addressing settings.
if ! nmcli connection up "$SSID" >/dev/null 2>&1; then
  err "Failed to activate connection '$SSID'"
  exit 1
fi

log "WiFi connection '$SSID' established successfully"

# Persist the choice as the active config (only after a successful connect).
if cp "$CONFIG_PATH" "$ACTIVE_CONF"; then
  log "Saved '$CONFIG_PATH' as active config $ACTIVE_CONF"
else
  warn "Connected, but failed to copy config to $ACTIVE_CONF"
fi

exit 0
