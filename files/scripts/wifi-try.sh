#!/bin/bash
#
# wifi-try.sh - Test candidate Wi-Fi credentials, then come back to the hotspot.
#
# Called (detached) by wifi-setup-server.py when the operator submits a network
# on the setup page. The radio can only do one thing at a time, so testing
# credentials means dropping the hotspot the operator is connected through.
# That is why this runs detached and reports through a status file instead of an
# HTTP response: the response could never reach the browser.
#
# Sequence:
#   1. Record which hotspot to come back to, before anything changes.
#   2. Mark the status "running" so the page can show progress.
#   3. Drop the hotspot and try the candidate credentials.
#   4. On success, copy the candidate over the active config so the next boot
#      uses it. On failure, leave the active config untouched.
#   5. Raise the hotspot again either way, so the operator can read the result
#      and decide whether to reboot.
#
# Usage: wifi-try.sh <candidate-config-path>

set -u

# shellcheck source=/dev/null
. "${WIFI_LIB:-/usr/local/bin/wifi-lib.sh}"

CANDIDATE="${1:-}"

if [ -z "$CANDIDATE" ] || [ ! -f "$CANDIDATE" ]; then
  err "Usage: $0 <candidate-config-path>"
  status_write failed "" "Internal error: candidate config not found."
  exit 2
fi

# --- Step 1: work out where to return, before we touch anything -------------
# Read the hotspot settings from the *active* config in a subshell so the
# candidate's own values cannot overwrite them later.
hotspot_line="$(
  if [ -f "$ACTIVE_CONF" ]; then
    # shellcheck source=/dev/null
    . "$ACTIVE_CONF" 2>/dev/null || true
  fi
  recovery_hotspot
)"
RETURN_SSID="${hotspot_line%%$'\t'*}"
RETURN_PASS="${hotspot_line#*$'\t'}"

log "Will return to hotspot '$RETURN_SSID' when the test finishes"

# --- Step 2: load the candidate ---------------------------------------------
# shellcheck source=/dev/null
. "$CANDIDATE"

if [ -z "${SSID:-}" ] || [ -z "${PASSWORD:-}" ]; then
  err "Candidate config is missing SSID or PASSWORD"
  status_write failed "${SSID:-}" "Config is missing the network name or password."
  exit 2
fi

CANDIDATE_SSID="$SSID"
status_write running "$CANDIDATE_SSID" "Trying to connect…"

# --- Step 3: drop the hotspot and try the credentials -----------------------
log "Releasing hotspot '$RETURN_SSID' to free the radio"
wifi_release "$RETURN_SSID"

# A scan first gives a much better error message than a bare connect failure:
# "network not found" and "wrong password" are very different problems.
seen=1
if ! nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -Fxq "$CANDIDATE_SSID"; then
  seen=0
  warn "SSID '$CANDIDATE_SSID' not visible in scan"
fi

result_state="failed"
result_msg="Could not connect."
result_ip=""

if wifi_connect "$CANDIDATE_SSID" "$PASSWORD"; then
  result_ip="$(nmcli -t -f IP4.ADDRESS device show "$IFACE" 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1)"
  result_state="ok"
  result_msg="Connected successfully."
  log "Test succeeded for '$CANDIDATE_SSID' (ip: ${result_ip:-unknown})"

  # --- Step 4: persist the choice, only now that it is proven --------------
  if cp "$CANDIDATE" "$ACTIVE_CONF"; then
    log "Wrote $ACTIVE_CONF"
    # The Pi can connect on its own now, so the next boot should not land in
    # recovery mode.
    recovery_marker_off
  else
    result_msg="Connected, but saving the config failed. Check the data partition."
    warn "Failed to copy candidate to $ACTIVE_CONF"
  fi
else
  if [ "$seen" -eq 0 ]; then
    result_msg="Network '$CANDIDATE_SSID' was not found. Check the name, or move closer."
  else
    result_msg="Found '$CANDIDATE_SSID' but could not connect. The password is probably wrong."
  fi
  err "Test failed for '$CANDIDATE_SSID': $result_msg"
fi

# --- Step 5: always come back to the hotspot --------------------------------
log "Releasing client connection and restoring the hotspot"
wifi_release "$CANDIDATE_SSID"

if hotspot_up "$RETURN_SSID" "$RETURN_PASS"; then
  log "Hotspot '$RETURN_SSID' is back up"
else
  err "Could not restore hotspot '$RETURN_SSID' - reboot to recover"
  result_msg="$result_msg (Warning: the hotspot could not be restarted. Reboot the device.)"
fi

status_write "$result_state" "$CANDIDATE_SSID" "$result_msg" "$result_ip"

[ "$result_state" = "ok" ] && exit 0
exit 1
