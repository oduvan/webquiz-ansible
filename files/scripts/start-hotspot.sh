#!/bin/bash

WIFI_CONF="/mnt/data/wifi.conf"
IFACE="${IFACE:-wlan0}"
HOTSPOT_NAME="${HOTSPOT_NAME:-wifi-hotspot}"
VENV_PATH="${VENV_PATH:-/home/oduvan/venv_webquiz}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }

start_webserver() {
  log "Starting web server and webquiz application"
  # Generate index.html if needed
  python3 /usr/local/bin/create_index_html.py
  # Start webquiz server in background
  source /home/oduvan/venv_webquiz/bin/activate && webquiz --config /mnt/data/webquiz/server.conf --url-format "http://{IP}/webquiz/" &
}

cleanup_hotspot_settings() {
  log "Cleaning up hotspot settings for WiFi client mode"

  # NetworkManager handles cleanup automatically when connection is stopped

}

try_wifi_client() {
  local ssid="$1"
  local password="$2"

  log "Attempting to connect to WiFi: $ssid on $IFACE"

  # Clean up any hotspot settings that might interfere
  cleanup_hotspot_settings

  # Check for static IP configuration
  local have_static=0
  if [ -n "${IPADDR:-}" ] && [ -n "${GATEWAY:-}" ] && [ -n "${DNS:-}" ]; then
    have_static=1
    log "Static IP requested: $IPADDR (gw: $GATEWAY, dns: $DNS)"
  else
    log "No full static IP config found; will use DHCP"
  fi

  # Ensure we start from a clean connection profile with the same name
  nmcli -t -f NAME connection show | grep -Fxq "$ssid" && nmcli connection delete "$ssid" >/dev/null 2>&1

  # Create connection by connecting once (this also stores the PSK)
  if ! nmcli dev wifi connect "$ssid" password "$password" ifname "$IFACE" name "$ssid" >/dev/null 2>&1; then
    warn "WiFi connect failed for SSID '$ssid'"
    return 1
  fi

  # Switch to static or DHCP as requested
  if [ "$have_static" -eq 1 ]; then
    # /24 mask by default; override with IPPREFIX in config if needed
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

  # Bring connection up (re-activate with our IP settings)
  if ! nmcli connection up "$ssid" >/dev/null 2>&1; then
    err "Failed to activate connection '$ssid'"
    return 1
  fi

  log "WiFi connection '$ssid' established successfully"
  return 0
}

create_hotspot() {
  local ssid="$1"
  local password="${2:-}"

  log "Creating and starting hotspot: $ssid"

  # Delete existing connection if it exists
  nmcli connection delete "$ssid" 2>/dev/null || true

  # Configure WiFi security
  local wifi_sec
  if [ -n "$password" ]; then
    wifi_sec="wifi-sec.key-mgmt wpa-psk wifi-sec.psk $password"
    log "Hotspot will be password-protected"
  else
    wifi_sec="wifi-sec.key-mgmt none"
    warn "Hotspot will be OPEN (no password)"
  fi

  # Create hotspot using NetworkManager's shared mode for automatic DHCP/DNS
  # Note: $wifi_sec is intentionally unquoted to allow word splitting for nmcli arguments
  # shellcheck disable=SC2086
  if ! nmcli connection add type wifi ifname "$IFACE" con-name "$ssid" autoconnect no \
    wifi.mode ap wifi.ssid "$ssid" \
    $wifi_sec \
    ipv4.method shared \
    ipv6.method ignore; then
    warn "Failed to create hotspot connection"
    return 1
  fi

  # NetworkManager's shared mode automatically handles NAT, DHCP and DNS services

  # Start the hotspot
  if ! nmcli connection up "$ssid"; then
    warn "Could not bring up hotspot '$ssid'"
    return 1
  fi

  log "Hotspot '$ssid' created and started successfully"
  return 0
}


# --- Main Logic ---
if [ -f "$WIFI_CONF" ]; then
  log "Found config: $WIFI_CONF"
  # shellcheck disable=SC1090
  source "$WIFI_CONF"

  # Log configuration summary
  log "Configuration summary:"
  [ -n "${SSID:-}" ] && log "  WiFi Client: $SSID"
  [ -n "${HOTSPOT_SSID:-}" ] && log "  Hotspot: $HOTSPOT_SSID"

  # Phase 1: Try WiFi client connection if configured
  if [ -n "${SSID:-}" ] && [ -n "${PASSWORD:-}" ]; then
    if try_wifi_client "$SSID" "$PASSWORD"; then
      log "WiFi client connection successful, starting webserver"
      start_webserver
      exit 0
    else
      warn "WiFi client connection failed, checking for hotspot fallback"
      # Clean up failed WiFi connection before attempting hotspot
      nmcli connection delete "$SSID" 2>/dev/null || true
      nmcli device disconnect "$IFACE" 2>/dev/null || true
    fi
  elif [ -n "${SSID:-}" ]; then
    warn "SSID is set but PASSWORD is missing - WiFi client mode skipped"
  fi

  # Phase 2: Try hotspot if configured (either as fallback or primary)
  if [ -n "${HOTSPOT_SSID:-}" ]; then
    log "Attempting hotspot configuration"
    if create_hotspot "$HOTSPOT_SSID" "${HOTSPOT_PASSWORD:-}"; then
      log "Hotspot created successfully, starting webserver"
      start_webserver
      exit 0
    else
      err "Failed to create hotspot '$HOTSPOT_SSID'"
      # Start webserver anyway
      start_webserver
      exit 1
    fi
  fi

  # Phase 3: No network configuration succeeded
  warn "No network configuration available or all attempts failed"
  log "Starting webserver without network setup"
  start_webserver
  exit 0

else
  warn "Config file not found: $WIFI_CONF"
  log "Starting webserver without network configuration"
  start_webserver
  exit 0
fi
