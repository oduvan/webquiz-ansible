#!/usr/bin/env python3
"""Wi-Fi setup page for a Raspberry Pi that cannot reach a network.

When the Pi has no wifi.conf, or the configured network does not answer,
start-hotspot.sh raises a hotspot and starts this server. You join the hotspot,
the captive portal lands you here, and you either pick a network you saved
earlier or type a new one in.

Why the result does not come back in the HTTP response: the Pi has one radio,
and the hotspot you are connected through is using it. Testing credentials
means dropping that hotspot, which kills your connection mid-request. So a test
is handed to wifi-try.sh, which runs detached, writes its outcome to a status
file, and brings the hotspot back. The page polls the status file once you are
reconnected.

Saved networks live as individual files in /mnt/data/wifi/. The active network
is /mnt/data/wifi.conf, which start-hotspot.sh reads at boot. A network is only
copied to the active config after it has actually connected.

There is no password on this page. Whoever can join the hotspot can configure
the network; the hotspot is the only gate.

Security note: these files are sourced by bash at boot, so every value is
validated and single-quote escaped. An unescaped backtick in an SSID would be
command execution as root.
"""

import json
import os
import re
import shlex
import subprocess

from aiohttp import web

# --- Configuration (overridable via environment) ---------------------------
HOST = os.environ.get("WIFI_SETUP_HOST", "127.0.0.1")
PORT = int(os.environ.get("WIFI_SETUP_PORT", "8083"))
SAVED_DIR = os.environ.get("SAVED_DIR", "/mnt/data/wifi")
ACTIVE_CONF = os.environ.get("ACTIVE_CONF", "/mnt/data/wifi.conf")
STATUS_FILE = os.environ.get("STATUS_FILE", "/run/wifi-setup-status.json")
TRY_SCRIPT = os.environ.get("WIFI_TRY_SCRIPT", "/usr/local/bin/wifi-try.sh")
CANDIDATE_CONF = os.environ.get("CANDIDATE_CONF", "/run/wifi-candidate.conf")

# --- Validation ------------------------------------------------------------
# Saved-entry names become filenames, so keep them boring.
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
IP_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
SSID_MAX = 32          # IEEE 802.11 allows 1-32 octets
DEFAULT_DNS = os.environ.get("DEFAULT_DNS", "8.8.8.8")
DEFAULT_PREFIX = os.environ.get("DEFAULT_PREFIX", "24")
PASSWORD_MIN = 8       # WPA2 PSK minimum
PASSWORD_MAX = 63


def _clean(value):
    """Strip a submitted value and reject what would corrupt a bash file."""
    if value is None:
        return ""
    value = str(value).strip()
    if "\n" in value or "\r" in value or "\x00" in value:
        raise ValueError("Control characters are not allowed.")
    return value


def _valid_ipv4(value):
    m = IP_RE.match(value)
    return bool(m) and all(0 <= int(g) <= 255 for g in m.groups())


def build_config(form, name=None):
    """Validate submitted fields and render a bash env-var config file.

    Returns the file contents. Raises ValueError with a message fit to show the
    operator.
    """
    ssid = _clean(form.get("ssid"))
    if not ssid or len(ssid.encode("utf-8")) > SSID_MAX:
        raise ValueError("Network name is required and must be at most 32 bytes.")

    password = _clean(form.get("password"))
    if not PASSWORD_MIN <= len(password) <= PASSWORD_MAX:
        raise ValueError("Password must be between 8 and 63 characters.")

    lines = []
    if name:
        lines.append("# Saved Wi-Fi network: %s" % name)
    lines.append("# Written by wifi-setup-server. Format matches wifi.conf.example.")
    lines.append("SSID=%s" % shlex.quote(ssid))
    lines.append("PASSWORD=%s" % shlex.quote(password))

    # A static address is required, not optional. With DHCP the operator has no
    # way to know where the device will be after it reboots: the lease can
    # change, and there is no second chance to ask once the device has left the
    # setup hotspot. A fixed address is the whole point of configuring it here.
    ipaddr = _clean(form.get("ipaddr"))
    gateway = _clean(form.get("gateway"))
    dns = _clean(form.get("dns")) or DEFAULT_DNS
    prefix = _clean(form.get("ipprefix")) or DEFAULT_PREFIX

    for label, val in (("IP address", ipaddr), ("gateway", gateway), ("DNS server", dns)):
        if not val:
            raise ValueError("The %s is required." % label)
        if not _valid_ipv4(val):
            raise ValueError("The %s must be a valid IPv4 address." % label)

    if not prefix.isdigit() or not 0 <= int(prefix) <= 32:
        raise ValueError("The network prefix must be a number from 0 to 32.")

    lines.append("IPADDR=%s" % shlex.quote(ipaddr))
    lines.append("GATEWAY=%s" % shlex.quote(gateway))
    lines.append("DNS=%s" % shlex.quote(dns))
    lines.append("IPPREFIX=%s" % shlex.quote(prefix))

    # Carry the operator's hotspot choice forward, so a Pi that has been set up
    # keeps raising the hotspot name its owner picked if Wi-Fi fails later.
    hotspot_ssid, hotspot_pass = read_hotspot(ACTIVE_CONF)
    if hotspot_ssid:
        lines.append("HOTSPOT_SSID=%s" % shlex.quote(hotspot_ssid))
        if hotspot_pass:
            lines.append("HOTSPOT_PASSWORD=%s" % shlex.quote(hotspot_pass))

    return "\n".join(lines) + "\n"


# --- Reading existing config files -----------------------------------------
def parse_conf(path):
    """Read a wifi.conf-style file into a dict.

    These files are bash, but ours only ever contain KEY='value' lines, so a
    line parser is enough and avoids running anything.
    """
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                key = key.strip()
                if not key.isidentifier():
                    continue
                try:
                    parts = shlex.split(raw)
                except ValueError:
                    continue
                out[key] = parts[0] if parts else ""
    except OSError:
        pass
    return out


def read_hotspot(path):
    conf = parse_conf(path)
    return conf.get("HOTSPOT_SSID", ""), conf.get("HOTSPOT_PASSWORD", "")


def saved_path(name):
    """Resolve a saved-entry name to a path, refusing anything outside the dir."""
    if not NAME_RE.match(name or ""):
        raise ValueError("Invalid name.")
    return os.path.join(SAVED_DIR, name + ".conf")


def list_saved():
    """Return the saved networks as [{name, ssid, static}], sorted by name."""
    try:
        files = sorted(fn for fn in os.listdir(SAVED_DIR) if fn.endswith(".conf"))
    except OSError:
        return []

    out = []
    for fn in files:
        name = fn[:-5]
        if not NAME_RE.match(name):
            continue
        conf = parse_conf(os.path.join(SAVED_DIR, fn))
        if not conf.get("SSID"):
            continue
        # Everything except the password, which is never sent back to the
        # browser. Editing an entry means typing a new one anyway, which is
        # usually the reason for editing it.
        out.append(
            {
                "name": name,
                "ssid": conf.get("SSID", ""),
                "static": conf.get("IPADDR", ""),
                "ipaddr": conf.get("IPADDR", ""),
                "gateway": conf.get("GATEWAY", ""),
                "dns": conf.get("DNS", ""),
                "ipprefix": conf.get("IPPREFIX", ""),
            }
        )
    return out


def read_status():
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"state": "idle", "ssid": "", "message": "", "ip": ""}


def scan_networks():
    """Nearby SSIDs, strongest first. Typing an SSID by hand invites typos."""
    try:
        proc = subprocess.run(
            ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"],
            capture_output=True,
            text=True,
            timeout=25,
        )
    except (OSError, subprocess.SubprocessError):
        return []

    seen = {}
    for line in proc.stdout.splitlines():
        # nmcli -t escapes colons inside fields as \:, so split on unescaped ones.
        fields = re.split(r"(?<!\\):", line)
        if len(fields) < 2:
            continue
        ssid = fields[0].replace("\\:", ":").strip()
        if not ssid:
            continue
        try:
            signal = int(fields[1])
        except ValueError:
            signal = 0
        security = fields[2].strip() if len(fields) > 2 else ""
        # The same network often appears once per band; keep the strongest.
        if ssid not in seen or signal > seen[ssid]["signal"]:
            seen[ssid] = {"ssid": ssid, "signal": signal, "security": security}

    return sorted(seen.values(), key=lambda n: -n["signal"])


# --- Handlers --------------------------------------------------------------
async def handle_index(request):
    return web.Response(text=PAGE, content_type="text/html")


async def handle_saved(request):
    return web.json_response({"saved": list_saved(), "active": parse_conf(ACTIVE_CONF).get("SSID", "")})


async def handle_scan(request):
    return web.json_response({"networks": scan_networks()})


async def handle_status(request):
    return web.json_response(read_status())


async def handle_test(request):
    """Validate a network, stage it, and hand it to wifi-try.sh detached.

    Returns as soon as the test is launched. The connection carrying this
    response is about to be dropped with the hotspot, which is why the result
    arrives through /wifi/api/status instead.
    """
    try:
        body = await request.json()
    except ValueError:
        return web.json_response({"error": "Expected JSON."}, status=400)

    name = _clean(body.get("name"))

    # Either re-test something already saved, or validate what was typed in.
    if body.get("use_saved"):
        try:
            path = saved_path(name)
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
        if not os.path.isfile(path):
            return web.json_response({"error": "No saved network by that name."}, status=404)
        with open(path, "r", encoding="utf-8") as fh:
            contents = fh.read()
        ssid = parse_conf(path).get("SSID", "")
    else:
        try:
            contents = build_config(body, name=name or None)
        except ValueError as exc:
            return web.json_response({"error": str(exc)}, status=400)
        ssid = _clean(body.get("ssid"))

        # Saving is optional; an unnamed network is tested and, if it works,
        # becomes the active config without being kept in the library.
        if name:
            if not NAME_RE.match(name):
                return web.json_response(
                    {"error": "Name must be 1-64 characters: letters, digits, dot, dash, underscore."},
                    status=400,
                )
            os.makedirs(SAVED_DIR, exist_ok=True)
            with open(saved_path(name), "w", encoding="utf-8") as fh:
                fh.write(contents)

    # Stage the candidate where wifi-try.sh can source it. /run is tmpfs, so a
    # half-written candidate cannot survive a reboot.
    os.makedirs(os.path.dirname(CANDIDATE_CONF), exist_ok=True)
    with open(CANDIDATE_CONF, "w", encoding="utf-8") as fh:
        fh.write(contents)
    os.chmod(CANDIDATE_CONF, 0o600)

    # Detach fully: this process must not be the test's parent, or restarting
    # the server would kill a test in flight.
    subprocess.Popen(
        ["/usr/bin/setsid", TRY_SCRIPT, CANDIDATE_CONF],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )

    return web.json_response({"started": True, "ssid": ssid}, status=202)


async def handle_delete(request):
    try:
        body = await request.json()
    except ValueError:
        return web.json_response({"error": "Expected JSON."}, status=400)
    try:
        path = saved_path(_clean(body.get("name")))
    except ValueError as exc:
        return web.json_response({"error": str(exc)}, status=400)
    try:
        os.remove(path)
    except FileNotFoundError:
        return web.json_response({"error": "No saved network by that name."}, status=404)
    except OSError as exc:
        return web.json_response({"error": "Could not delete: %s" % exc}, status=500)
    return web.json_response({"deleted": True})


async def handle_reboot(request):
    # Detached, and after a short delay, so this response reaches the browser
    # before the Pi goes down.
    subprocess.Popen(
        ["/bin/sh", "-c", "sleep 2; /sbin/reboot"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return web.json_response({"rebooting": True})


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wi-Fi setup</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { font-family: -apple-system, system-ui, sans-serif; margin: 0;
         padding: 1rem; max-width: 34rem; margin-inline: auto; line-height: 1.5; }
  h1 { font-size: 1.3rem; margin: 0 0 .25rem; }
  .sub { color: #666; font-size: .85rem; margin: 0 0 1.25rem; }
  h2 { font-size: 1rem; margin: 1.5rem 0 .5rem; }
  .card { border: 1px solid #ccc; border-radius: .6rem; padding: .75rem;
          margin-bottom: .5rem; }
  .row { display: flex; align-items: center; gap: .5rem; justify-content: space-between; }
  .ssid { font-weight: 600; word-break: break-all; }
  .meta { color: #666; font-size: .8rem; }
  label { display: block; margin: .6rem 0 .2rem; font-size: .85rem; }
  input, select { width: 100%; padding: .5rem; border: 1px solid #bbb;
                  border-radius: .4rem; font-size: 1rem; }
  button { padding: .55rem .9rem; border: 0; border-radius: .4rem;
           background: #2563eb; color: #fff; font-size: .95rem; cursor: pointer; }
  button.ghost { background: transparent; color: #2563eb; border: 1px solid #2563eb; }
  button.danger { background: transparent; color: #b91c1c; border: 1px solid #b91c1c; }
  button[disabled] { opacity: .5; cursor: default; }
  .wide { width: 100%; margin-top: .75rem; }
  .banner { padding: .7rem .9rem; border-radius: .5rem; margin-bottom: 1rem;
            font-size: .9rem; display: none; }
  .banner.show { display: block; }
  .banner.ok { background: #dcfce7; color: #14532d; }
  .banner.err { background: #fee2e2; color: #7f1d1d; }
  .banner.busy { background: #fef9c3; color: #713f12; }
  details { margin-top: .5rem; }
  summary { cursor: pointer; font-size: .85rem; color: #2563eb; }
  .hint { color: #666; font-size: .8rem; margin-top: .4rem; }
  @media (prefers-color-scheme: dark) {
    .card { border-color: #444; }
    .sub, .meta, .hint { color: #aaa; }
    input, select { background: #1c1c1e; color: #eee; border-color: #555; }
    .banner.ok { background: #14532d; color: #dcfce7; }
    .banner.err { background: #7f1d1d; color: #fee2e2; }
    .banner.busy { background: #713f12; color: #fef9c3; }
  }
</style>
</head>
<body>
<h1>Wi-Fi setup</h1>
<p class="sub">This device could not join a network, so it started its own.
Pick a network below or enter one by hand, along with the fixed address you want
this device to use. The details are tested before anything is saved.</p>

<div id="banner" class="banner"></div>

<div id="result" style="display:none">
  <button id="reboot" class="wide">Reboot and use this network</button>
  <p class="hint">After the reboot this device joins the network on its own and
  this hotspot disappears.</p>
</div>

<h2>Saved networks</h2>
<div id="saved"><p class="meta">Loading…</p></div>

<h2 id="formTitle">Add a network</h2>
<p id="editing" class="hint" style="display:none"></p>
<form id="form" autocomplete="off">
  <label for="ssid">Network name</label>
  <input list="scanlist" id="ssid" name="ssid" required maxlength="32"
         placeholder="Pick from nearby or type a name">
  <datalist id="scanlist"></datalist>
  <button type="button" id="rescan" class="ghost" style="margin-top:.5rem">Scan for networks</button>

  <label for="password">Password</label>
  <input type="password" id="password" name="password" required minlength="8" maxlength="63">

  <label for="name">Remember as (optional)</label>
  <input id="name" name="name" maxlength="64" pattern="[A-Za-z0-9._-]{1,64}"
         placeholder="e.g. school-hall">
  <p class="hint">Give it a name to keep it in the list above for next time.</p>

  <fieldset>
    <legend>Fixed address</legend>
    <p class="hint">Required. This is the address you will use to reach this
    device after it reboots. Pick one your router will not hand out to anything
    else, or two devices end up sharing it.</p>

    <label for="ipaddr">IP address for this device</label>
    <input id="ipaddr" name="ipaddr" required
           pattern="(\d{1,3}\.){3}\d{1,3}" placeholder="192.168.1.50">

    <label for="gateway">Router address (gateway)</label>
    <input id="gateway" name="gateway" required
           pattern="(\d{1,3}\.){3}\d{1,3}" placeholder="192.168.1.1">

    <label for="dns">DNS server</label>
    <input id="dns" name="dns" required
           pattern="(\d{1,3}\.){3}\d{1,3}" value="8.8.8.8">

    <label for="ipprefix">Prefix length</label>
    <input id="ipprefix" name="ipprefix" required
           inputmode="numeric" pattern="\d{1,2}" value="24">
    <p class="hint">24 suits almost every home and school network. Change it
    only if you know yours is different.</p>
  </fieldset>

  <button type="submit" id="submit" class="wide">Test and save</button>
  <button type="button" id="cancelEdit" class="ghost wide" style="display:none">Cancel editing</button>
</form>

<script>
var banner = document.getElementById('banner');
var polling = null;

function show(kind, text) {
  banner.className = 'banner show ' + kind;
  banner.textContent = text;
}

function api(path, opts) {
  return fetch('/wifi/api/' + path, opts).then(function (r) {
    return r.json().then(function (body) {
      if (!r.ok) { throw new Error(body.error || ('HTTP ' + r.status)); }
      return body;
    });
  });
}

function loadSaved() {
  return api('saved').then(function (data) {
    var box = document.getElementById('saved');
    if (!data.saved.length) {
      box.innerHTML = '<p class="meta">Nothing saved yet.</p>';
      return;
    }
    box.innerHTML = '';
    data.saved.forEach(function (net) {
      var card = document.createElement('div');
      card.className = 'card';
      var row = document.createElement('div');
      row.className = 'row';
      var left = document.createElement('div');
      var ssid = document.createElement('div');
      ssid.className = 'ssid';
      ssid.textContent = net.ssid;
      var meta = document.createElement('div');
      meta.className = 'meta';
      meta.textContent = net.name + (net.static ? ' · static ' + net.static : '');
      left.appendChild(ssid);
      left.appendChild(meta);
      var right = document.createElement('div');
      var use = document.createElement('button');
      use.textContent = 'Use';
      use.onclick = function () { startTest({ use_saved: true, name: net.name }); };
      var edit = document.createElement('button');
      edit.className = 'ghost';
      edit.textContent = 'Edit';
      edit.style.marginLeft = '.4rem';
      edit.onclick = function () { startEdit(net); };
      var del = document.createElement('button');
      del.className = 'danger';
      del.textContent = 'Delete';
      del.style.marginLeft = '.4rem';
      del.onclick = function () {
        api('delete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: net.name })
        }).then(loadSaved).catch(function (e) { show('err', e.message); });
      };
      right.appendChild(use);
      right.appendChild(edit);
      right.appendChild(del);
      row.appendChild(left);
      row.appendChild(right);
      card.appendChild(row);
      box.appendChild(card);
    });
  }).catch(function (e) { show('err', e.message); });
}

function rescan() {
  var btn = document.getElementById('rescan');
  btn.disabled = true;
  btn.textContent = 'Scanning…';
  return api('scan').then(function (data) {
    var list = document.getElementById('scanlist');
    list.innerHTML = '';
    data.networks.forEach(function (net) {
      var opt = document.createElement('option');
      opt.value = net.ssid;
      list.appendChild(opt);
    });
    btn.textContent = data.networks.length
      ? 'Scan again (' + data.networks.length + ' found)'
      : 'Scan again (none found)';
  }).catch(function (e) {
    show('err', e.message);
    btn.textContent = 'Scan for networks';
  }).then(function () { btn.disabled = false; });
}

// Load a saved network back into the form so it can be corrected.
//
// A network whose password was wrong is still saved, because throwing the
// whole entry away would mean retyping the address fields to fix one word.
// The password is deliberately left blank: it is never sent to the browser,
// and changing it is usually why you are here.
function startEdit(net) {
  document.getElementById('ssid').value = net.ssid || '';
  document.getElementById('name').value = net.name || '';
  document.getElementById('ipaddr').value = net.ipaddr || '';
  document.getElementById('gateway').value = net.gateway || '';
  document.getElementById('dns').value = net.dns || '8.8.8.8';
  document.getElementById('ipprefix').value = net.ipprefix || '24';
  document.getElementById('password').value = '';

  document.getElementById('formTitle').textContent = 'Correct this network';
  var note = document.getElementById('editing');
  note.textContent = 'Editing "' + net.name + '". Enter the password again and press '
                   + 'Test and update. Saving under the same name replaces the old entry.';
  note.style.display = 'block';
  document.getElementById('submit').textContent = 'Test and update';
  document.getElementById('cancelEdit').style.display = 'block';

  document.getElementById('formTitle').scrollIntoView({ behavior: 'smooth', block: 'start' });
  document.getElementById('password').focus();
}

function cancelEdit() {
  document.getElementById('form').reset();
  document.getElementById('dns').value = '8.8.8.8';
  document.getElementById('ipprefix').value = '24';
  document.getElementById('formTitle').textContent = 'Add a network';
  document.getElementById('editing').style.display = 'none';
  document.getElementById('submit').textContent = 'Test and save';
  document.getElementById('cancelEdit').style.display = 'none';
}

function startTest(payload) {
  document.getElementById('submit').disabled = true;
  document.getElementById('result').style.display = 'none';
  show('busy', 'Testing… this device is leaving the hotspot, so this page will '
     + 'stop responding for up to a minute. Stay joined to the hotspot and it '
     + 'will come back with the result.');

  api('test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  }).then(function () {
    pollStatus();
  }).catch(function (e) {
    // A dropped request here usually means the radio already went down, so the
    // test is running; fall through to polling rather than reporting an error.
    pollStatus();
  });
}

function pollStatus() {
  if (polling) { clearInterval(polling); }
  polling = setInterval(function () {
    fetch('/wifi/api/status', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (s) {
        if (s.state === 'running') {
          show('busy', 'Testing "' + s.ssid + '"… waiting for the hotspot to come back.');
          return;
        }
        if (s.state === 'ok') {
          clearInterval(polling);
          polling = null;
          show('ok', 'Connected to "' + s.ssid + '"'
             + (s.ip ? ' (address ' + s.ip + ')' : '') + '. Saved as the network to use.');
          document.getElementById('result').style.display = 'block';
          document.getElementById('submit').disabled = false;
          // The entry is correct now, so drop out of editing mode.
          cancelEdit();
          loadSaved();
          return;
        }
        if (s.state === 'failed') {
          clearInterval(polling);
          polling = null;
          show('err', s.message || 'The test failed.');
          document.getElementById('submit').disabled = false;
          loadSaved();
        }
      })
      .catch(function () { /* hotspot still down; keep waiting */ });
  }, 3000);
}

document.getElementById('form').onsubmit = function (ev) {
  ev.preventDefault();
  startTest({
    ssid: document.getElementById('ssid').value,
    password: document.getElementById('password').value,
    name: document.getElementById('name').value,
    ipaddr: document.getElementById('ipaddr').value,
    gateway: document.getElementById('gateway').value,
    dns: document.getElementById('dns').value,
    ipprefix: document.getElementById('ipprefix').value
  });
};

document.getElementById('rescan').onclick = rescan;
document.getElementById('cancelEdit').onclick = cancelEdit;

document.getElementById('reboot').onclick = function () {
  this.disabled = true;
  this.textContent = 'Rebooting…';
  api('reboot', { method: 'POST' }).catch(function () { /* expected */ });
};

loadSaved();
// If a test was already running when this page loaded, pick it back up.
fetch('/wifi/api/status', { cache: 'no-store' })
  .then(function (r) { return r.json(); })
  .then(function (s) { if (s.state && s.state !== 'idle') { pollStatus(); } })
  .catch(function () {});
</script>
</body>
</html>
"""


def make_app():
    app = web.Application()
    app.router.add_get("/wifi/", handle_index)
    app.router.add_get("/wifi/api/saved", handle_saved)
    app.router.add_get("/wifi/api/scan", handle_scan)
    app.router.add_get("/wifi/api/status", handle_status)
    app.router.add_post("/wifi/api/test", handle_test)
    app.router.add_post("/wifi/api/delete", handle_delete)
    app.router.add_post("/wifi/api/reboot", handle_reboot)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host=HOST, port=PORT)
