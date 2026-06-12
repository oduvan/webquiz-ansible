#!/usr/bin/env python3
"""WiFi configuration endpoint.

A small aiohttp server that lets an operator (typically connected to the Pi's
WiFi hotspot) save WiFi networks and activate one on demand.

Design notes:
  * Saved networks live as individual files in WIFI_DIR (/mnt/data/wifi/), each
    in the same bash env-var format used by files/wifi.conf.example
    (SSID, PASSWORD, optional IPADDR/GATEWAY/DNS/IPPREFIX).
  * The *active* network is the existing /mnt/data/wifi.conf consumed at boot by
    start-hotspot.sh. Activation is delegated to the separate wifi-activate.sh
    script, which connects via nmcli and, on success, copies the saved file to
    the active location.
  * Every mutating request is authenticated against the WebQuiz admin master_key
    read from /mnt/data/webquiz/server.conf.

Security: saved files are `source`d by bash, so all values are strictly
validated and single-quote escaped to avoid command injection.
"""

import asyncio
import hmac
import html
import os
import re
import shlex

from aiohttp import web

# --- Configuration (overridable via environment) ---------------------------
HOST = os.environ.get("WIFI_CONFIG_HOST", "0.0.0.0")
PORT = int(os.environ.get("WIFI_CONFIG_PORT", "8082"))
WIFI_DIR = os.environ.get("WIFI_DIR", "/mnt/data/wifi")
ACTIVE_CONF = os.environ.get("ACTIVE_CONF", "/mnt/data/wifi.conf")
WEBQUIZ_CONF = os.environ.get("WEBQUIZ_CONF", "/mnt/data/webquiz/server.conf")
ACTIVATE_SCRIPT = os.environ.get(
    "WIFI_ACTIVATE_SCRIPT", "/usr/local/bin/wifi-activate.sh"
)

# --- Validation rules ------------------------------------------------------
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# IEEE 802.11 SSID: 1-32 octets. WPA2 PSK: 8-63 chars. We also forbid newlines
# and NUL everywhere because the values are written into a bash-sourced file.
SSID_MAX = 32
PASSWORD_MAX = 63
IP_RE = re.compile(r"^[0-9.]{1,15}$")
PREFIX_RE = re.compile(r"^[0-9]{1,2}$")


def read_master_key():
    """Read admin.master_key from the WebQuiz YAML config.

    Uses PyYAML when available (webquiz depends on it) and falls back to a
    minimal line-based parse so the endpoint still works if PyYAML is absent.
    Returns the key string, or None if it cannot be determined.
    """
    try:
        with open(WEBQUIZ_CONF, "r") as fh:
            text = fh.read()
    except OSError:
        return None

    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text) or {}
        admin = data.get("admin") or {}
        key = admin.get("master_key")
        if key is not None:
            return str(key)
    except Exception:
        pass

    # Fallback: find `master_key:` inside the `admin:` block.
    in_admin = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.match(r"^admin\s*:", line):
            in_admin = True
            continue
        # A new top-level (non-indented) key ends the admin block.
        if in_admin and re.match(r"^\S", line) and not re.match(r"^admin\s*:", line):
            in_admin = False
        if in_admin:
            m = re.match(r"^\s*master_key\s*:\s*(.+?)\s*$", line)
            if m:
                val = m.group(1)
                # Strip surrounding quotes and trailing inline comment.
                if val and val[0] in "\"'":
                    quote = val[0]
                    end = val.find(quote, 1)
                    if end != -1:
                        return val[1:end]
                val = val.split("#", 1)[0].strip()
                return val
    return None


def check_password(supplied):
    """Constant-time comparison of the supplied password to the master key."""
    key = read_master_key()
    if not key or supplied is None:
        return False
    return hmac.compare_digest(str(supplied), str(key))


def list_networks():
    """Return a sorted list of saved network names (without .conf)."""
    try:
        names = [
            fn[:-5]
            for fn in os.listdir(WIFI_DIR)
            if fn.endswith(".conf") and os.path.isfile(os.path.join(WIFI_DIR, fn))
        ]
    except OSError:
        names = []
    return sorted(names)


def active_matches(name):
    """True if the saved network <name> is byte-identical to the active conf."""
    path = os.path.join(WIFI_DIR, name + ".conf")
    try:
        with open(path, "rb") as a, open(ACTIVE_CONF, "rb") as b:
            return a.read() == b.read()
    except OSError:
        return False


def _clean(value):
    """Reject values containing characters unsafe for a bash-sourced file."""
    if value is None:
        return ""
    value = value.strip()
    if "\n" in value or "\r" in value or "\x00" in value:
        raise ValueError("control characters are not allowed")
    return value


def build_config(form):
    """Validate form fields and render the bash env-var config file contents.

    Raises ValueError with a human-readable message on invalid input.
    """
    name = _clean(form.get("name"))
    if not NAME_RE.match(name):
        raise ValueError(
            "Name must be 1-64 chars of letters, digits, dot, dash or underscore."
        )

    ssid = _clean(form.get("ssid"))
    if not ssid or len(ssid) > SSID_MAX:
        raise ValueError("SSID is required and must be at most 32 characters.")

    password = _clean(form.get("password"))
    if not password or not (8 <= len(password) <= PASSWORD_MAX):
        raise ValueError("Password is required and must be 8-63 characters.")

    lines = [
        "# Saved WiFi network: %s" % name,
        "# Generated by wifi-config-server. Format matches wifi.conf.example.",
        "SSID=%s" % shlex.quote(ssid),
        "PASSWORD=%s" % shlex.quote(password),
    ]

    # Optional static IP block (only emitted when all three are present).
    ipaddr = _clean(form.get("ipaddr"))
    gateway = _clean(form.get("gateway"))
    dns = _clean(form.get("dns"))
    prefix = _clean(form.get("ipprefix"))
    if ipaddr or gateway or dns:
        for label, val in (("IPADDR", ipaddr), ("GATEWAY", gateway), ("DNS", dns)):
            if not IP_RE.match(val):
                raise ValueError(
                    "For a static IP, %s must be a valid IPv4 address." % label
                )
        lines.append("IPADDR=%s" % shlex.quote(ipaddr))
        lines.append("GATEWAY=%s" % shlex.quote(gateway))
        lines.append("DNS=%s" % shlex.quote(dns))
        if prefix:
            if not PREFIX_RE.match(prefix) or not (0 <= int(prefix) <= 32):
                raise ValueError("IP prefix must be a number between 0 and 32.")
            lines.append("IPPREFIX=%s" % shlex.quote(prefix))

    return name, "\n".join(lines) + "\n"


# --- HTML rendering --------------------------------------------------------
PAGE_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WiFi Configuration</title>
<style>
  body {{ font-family: sans-serif; max-width: 640px; margin: 1.5rem auto;
         padding: 0 1rem; color: #222; }}
  h1 {{ font-size: 1.4rem; }}
  fieldset {{ border: 1px solid #ccc; border-radius: 8px; margin-bottom: 1rem; }}
  label {{ display: block; margin: .5rem 0 .15rem; font-size: .9rem; }}
  input {{ width: 100%; padding: .45rem; box-sizing: border-box;
          border: 1px solid #bbb; border-radius: 6px; }}
  button {{ padding: .45rem .8rem; border: 0; border-radius: 6px;
           background: #2563eb; color: #fff; cursor: pointer; }}
  button.danger {{ background: #dc2626; }}
  .net {{ display: flex; align-items: center; justify-content: space-between;
         padding: .5rem 0; border-bottom: 1px solid #eee; }}
  .net form {{ display: inline; margin: 0 0 0 .4rem; }}
  .active {{ color: #16a34a; font-weight: bold; }}
  .msg {{ padding: .6rem .8rem; border-radius: 6px; margin-bottom: 1rem; }}
  .msg.ok {{ background: #dcfce7; color: #166534; }}
  .msg.err {{ background: #fee2e2; color: #991b1b; }}
  .hint {{ color: #666; font-size: .8rem; }}
</style>
</head>
<body>
<h1>WiFi Configuration</h1>
{message}
<h2>Saved networks</h2>
<div>{networks}</div>
<p class="hint">Activating a network switches this device off its hotspot and
onto the selected WiFi. If the connection fails you may lose access; the active
network only changes on a successful connection.</p>

<h2>Add a network</h2>
<form method="post" action="/save">
  <fieldset>
    <legend>Network</legend>
    <label>Name (identifier for this saved entry)</label>
    <input name="name" required pattern="[A-Za-z0-9._-]{{1,64}}">
    <label>SSID (WiFi name)</label>
    <input name="ssid" required maxlength="32">
    <label>Password</label>
    <input name="password" required minlength="8" maxlength="63">
  </fieldset>
  <fieldset>
    <legend>Static IP (optional)</legend>
    <label>IP address</label><input name="ipaddr">
    <label>Gateway</label><input name="gateway">
    <label>DNS</label><input name="dns">
    <label>Prefix (default 24)</label><input name="ipprefix">
  </fieldset>
  <fieldset>
    <legend>Access</legend>
    <label>Access password (WebQuiz master key)</label>
    <input name="access_password" type="password" required>
  </fieldset>
  <button type="submit">Save network</button>
</form>
</body>
</html>
"""


def render_network_row(name):
    label = html.escape(name)
    if active_matches(name):
        label += ' <span class="active">(active)</span>'
    return (
        '<div class="net"><span>{label}</span><span>'
        '<form method="post" action="/activate">'
        '<input type="hidden" name="name" value="{name}">'
        '<input type="password" name="access_password" placeholder="access password" required>'
        '<button type="submit">Activate</button></form>'
        '<form method="post" action="/delete">'
        '<input type="hidden" name="name" value="{name}">'
        '<input type="password" name="access_password" placeholder="access password" required>'
        '<button type="submit" class="danger">Delete</button></form>'
        "</span></div>"
    ).format(label=label, name=html.escape(name))


def render_page(message_html=""):
    rows = [render_network_row(n) for n in list_networks()]
    networks = "".join(rows) if rows else "<p>No saved networks yet.</p>"
    return PAGE_TEMPLATE.format(message=message_html, networks=networks)


def msg(kind, text):
    return '<div class="msg {kind}">{text}</div>'.format(
        kind=kind, text=html.escape(text)
    )


# --- Handlers --------------------------------------------------------------
async def handle_index(request):
    return web.Response(text=render_page(), content_type="text/html")


async def handle_save(request):
    form = await request.post()
    if not check_password(form.get("access_password")):
        return web.Response(
            text=render_page(msg("err", "Invalid access password.")),
            content_type="text/html",
            status=403,
        )
    try:
        name, contents = build_config(form)
    except ValueError as exc:
        return web.Response(
            text=render_page(msg("err", str(exc))),
            content_type="text/html",
            status=400,
        )

    os.makedirs(WIFI_DIR, exist_ok=True)
    path = os.path.join(WIFI_DIR, name + ".conf")
    with open(path, "w") as fh:
        fh.write(contents)

    return web.Response(
        text=render_page(msg("ok", "Saved network '%s'." % name)),
        content_type="text/html",
    )


async def handle_activate(request):
    form = await request.post()
    if not check_password(form.get("access_password")):
        return web.Response(
            text=render_page(msg("err", "Invalid access password.")),
            content_type="text/html",
            status=403,
        )
    name = _clean(form.get("name"))
    if not NAME_RE.match(name):
        return web.Response(
            text=render_page(msg("err", "Invalid network name.")),
            content_type="text/html",
            status=400,
        )
    path = os.path.join(WIFI_DIR, name + ".conf")
    if not os.path.isfile(path):
        return web.Response(
            text=render_page(msg("err", "No such saved network.")),
            content_type="text/html",
            status=404,
        )

    proc = await asyncio.create_subprocess_exec(
        ACTIVATE_SCRIPT,
        path,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    output = (out or b"").decode("utf-8", "replace")

    if proc.returncode == 0:
        text = render_page(msg("ok", "Activated '%s'." % name))
        status = 200
    else:
        text = render_page(
            msg("err", "Failed to activate '%s'. %s" % (name, output.strip()))
        )
        status = 502
    return web.Response(text=text, content_type="text/html", status=status)


async def handle_delete(request):
    form = await request.post()
    if not check_password(form.get("access_password")):
        return web.Response(
            text=render_page(msg("err", "Invalid access password.")),
            content_type="text/html",
            status=403,
        )
    name = _clean(form.get("name"))
    if not NAME_RE.match(name):
        return web.Response(
            text=render_page(msg("err", "Invalid network name.")),
            content_type="text/html",
            status=400,
        )
    path = os.path.join(WIFI_DIR, name + ".conf")
    try:
        os.remove(path)
    except OSError:
        return web.Response(
            text=render_page(msg("err", "No such saved network.")),
            content_type="text/html",
            status=404,
        )
    return web.Response(
        text=render_page(msg("ok", "Deleted '%s'." % name)),
        content_type="text/html",
    )


def make_app():
    app = web.Application()
    app.add_routes(
        [
            web.get("/", handle_index),
            web.post("/save", handle_save),
            web.post("/activate", handle_activate),
            web.post("/delete", handle_delete),
        ]
    )
    return app


if __name__ == "__main__":
    os.makedirs(WIFI_DIR, exist_ok=True)
    web.run_app(make_app(), host=HOST, port=PORT)
