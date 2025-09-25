#!/bin/bash

WIFI_CONF="/mnt/data/wifi.conf"
IFACE="${IFACE:-wlan0}"
HOTSPOT_NAME="${HOTSPOT_NAME:-wifi-hotspot}"
VENV_PATH="${VENV_PATH:-/home/oduvan/venv_webquiz}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }

create_hotspot() {
  log "Creating and starting hotspot: $SSID"
  
  # Delete existing connection if it exists
  nmcli connection delete "$SSID" 2>/dev/null || true
  
  # Create hotspot connection from config
  if [ -n "${PASSWORD:-}" ]; then
    WIFI_SEC="wifi-sec.key-mgmt wpa-psk wifi-sec.psk $PASSWORD"
  else
    WIFI_SEC="wifi-sec.key-mgmt none"
  fi
  
  # Use configured IP or default
  HOTSPOT_IP="${IPADDR:-10.42.0.1/24}"
  
  # Create hotspot with shared internet connection for DHCP and DNS
  # Note: $WIFI_SEC is intentionally unquoted to allow word splitting for nmcli arguments
  # Note: ipv4.dns is not set because method=shared manages DNS automatically
  # shellcheck disable=SC2086
  if ! nmcli connection add type wifi ifname wlan0 con-name "$SSID" autoconnect no \
    wifi.mode ap wifi.ssid "$SSID" \
    $WIFI_SEC \
    ipv4.method shared ipv4.addresses "$HOTSPOT_IP" \
    ipv6.method ignore; then
    warn "Failed to create hotspot connection"
    return 1
  fi
  
  # Ensure dnsmasq service is running for DNS resolution
  # Update dnsmasq configuration to use the correct hotspot IP
  if [ -f "/etc/dnsmasq.conf" ]; then
    # Create a backup if it doesn't exist
    [ ! -f "/etc/dnsmasq.conf.backup" ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
    # Extract IP address without CIDR notation for DNS configuration
    HOTSPOT_DNS="${HOTSPOT_IP%/*}"
    # Update the address line to use the current hotspot IP
    sed -i "s|address=/#/.*|address=/#/$HOTSPOT_DNS|" /etc/dnsmasq.conf
  fi
  systemctl restart dnsmasq || warn "Failed to restart dnsmasq"
  
  # Start the hotspot
  if ! nmcli connection up "$SSID"; then
    warn "Could not bring up hotspot '$SSID'"
    return 1
  fi
  
  log "Hotspot '$SSID' created and started successfully"
}


# --- 1) Read config if present ---
if [ -f "$WIFI_CONF" ]; then
  log "Found config: $WIFI_CONF"
  # shellcheck disable=SC1090
  source "$WIFI_CONF"

  # Check if this is a hotspot configuration
  if [ "${HOTSPOT:-0}" = "1" ]; then
    # Validate mandatory vars for hotspot
    if [ -z "${SSID:-}" ]; then
      err "Hotspot config must define SSID"
      exit 1
    fi
    if ! create_hotspot; then
      err "Failed to create and start hotspot '$SSID'"
      exit 1
    fi
    exit 0
  fi

  # Validate mandatory vars for WiFi client
  if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ]; then
    err "WiFi client config must define SSID and PASSWORD"
    exit 1
  else
    log "Will try to connect to SSID: $SSID on $IFACE"

    # Optional static IP (all three must be present for manual mode)
    HAVE_STATIC=0
    if [ -n "${IPADDR:-}" ] && [ -n "${GATEWAY:-}" ] && [ -n "${DNS:-}" ]; then
      HAVE_STATIC=1
      log "Static IP requested: $IPADDR (gw: $GATEWAY, dns: $DNS)"
    else
      log "No full static IP config found; will use DHCP"
    fi

    # Ensure we start from a clean connection profile with the same name
    nmcli -t -f NAME connection show | grep -Fxq "$SSID" && nmcli connection delete "$SSID" >/dev/null 2>&1

    # Create connection by connecting once (this also stores the PSK)
    if ! nmcli dev wifi connect "$SSID" password "$PASSWORD" ifname "$IFACE" name "$SSID" >/dev/null 2>&1; then
      err "Wi-Fi connect failed for SSID '$SSID'"
      exit 1
    else
      # Switch to static or DHCP as requested
      if [ "$HAVE_STATIC" -eq 1 ]; then
        # /24 mask by default; override with IPPREFIX in config if needed
        IPPREFIX="${IPPREFIX:-24}"
        nmcli connection modify "$SSID" \
          ipv4.addresses "$IPADDR/$IPPREFIX" \
          ipv4.gateway "$GATEWAY" \
          ipv4.dns "$DNS" \
          ipv4.method manual \
          ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set static IPv4"
      else
        nmcli connection modify "$SSID" \
          ipv4.method auto \
          ipv6.method ignore >/dev/null 2>&1 || warn "Failed to set DHCP"
      fi

      # Bring connection up (re-activate with our IP settings)
      if ! nmcli connection up "$SSID" >/dev/null 2>&1; then
        err "Failed to activate connection '$SSID'"
        exit 1
      else
        log "Wi-Fi connection '$SSID' is up"
        # update_webquiz - handled by ansible-pull
      fi
    fi
  fi
else
  warn "Config file not found: $WIFI_CONF - no network configuration will be applied"
fi

log "Script finished."



# Generate index.html if needed
python3 /usr/local/bin/create_index_html.py
source /home/oduvan/venv_webquiz/bin/activate && webquiz --config /mnt/data/webquiz/server.conf &
