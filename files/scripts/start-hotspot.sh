#!/bin/bash

# Generate a random 4-character suffix
SUFFIX=$(tr -dc 0-9 </dev/urandom | head -c 5)
SSID="DOV-$SUFFIX"

# Set new SSID
#nmcli connection modify wifi-hotspot 802-11-wireless.ssid "$SSID"

# Start the hotspot
#!/bin/bash

WIFI_CONF="/mnt/data/wifi.conf"
IFACE="${IFACE:-wlan0}"
HOTSPOT_NAME="${HOTSPOT_NAME:-wifi-hotspot}"
VENV_PATH="${VENV_PATH:-/home/oduvan/venv_webquiz}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*"; }

hotspot_up() {
  log "Trying to bring up hotspot: $HOTSPOT_NAME"
  nmcli connection up "$HOTSPOT_NAME" 2>&1 || warn "Could not bring up hotspot '$HOTSPOT_NAME'"
}


# --- 1) Read config if present ---
if [ -f "$WIFI_CONF" ]; then
  log "Found config: $WIFI_CONF"
  # shellcheck disable=SC1090
  source "$WIFI_CONF"

  # Validate mandatory vars
  if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ]; then
    err "Config must define SSID and PASSWORD"
    hotspot_up
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
      hotspot_up
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
        hotspot_up
      else
        log "Wi-Fi connection '$SSID' is up"
        # update_webquiz - handled by ansible-pull
      fi
    fi
  fi
else
  warn "Config file not found: $WIFI_CONF"
  hotspot_up
fi

log "Script finished."



# Generate index.html if needed
python3 /usr/local/bin/create_index_html.py
source /home/oduvan/venv_webquiz/bin/activate && webquiz --config /mnt/data/webquiz/server.conf &
