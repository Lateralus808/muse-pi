#!/usr/bin/env python3
"""Muse Pi setup wizard.

A tiny local web page (Python standard library only) that walks the owner
through first-time setup:

  1. Give your Muse the keys  — paste your Muse's SSH public key and set
     your own password for the "@USERNAME@" account.
  2. Connect Tailscale          — runs "tailscale up" and shows the sign-in
     link to approve on your own Tailscale account.
  3. Optional extras             — one-click installers for Uptime Kuma,
     Pi-hole, Syncthing and the Tailscale subnet-router setup. Each extra
     is a separate, readable shell script in /usr/local/muse-pi/extras/.
  4. Done                        — shows this Pi's address and switches the
     wizard off (it stops opening itself on the desktop).

It listens on 127.0.0.1 only — nothing here is reachable from the network.
It runs as root because setup tasks (setting a password, installing
packages) need root; that is also why it disables itself when setup is
finished. "@HOSTNAME@" and "@USERNAME@" are substituted by
build-muse-pi.sh.
"""

import html
import os
import re
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER = "@USERNAME@"
HOSTNAME = "@HOSTNAME@"
HOME = "/home/" + USER
STATE = "/usr/local/muse-pi/state"
EXTRAS_DIR = "/usr/local/muse-pi/extras"
PORT = 8977

EXTRAS = [
    ("uptime-kuma", "Uptime Kuma — status board",
     "A web page that watches your other computers and services and shows "
     "whether they are up. Installs Docker and runs on port 3001.",
     "uptime-kuma.sh"),
    ("pihole", "Pi-hole — network ad-blocking",
     "Blocks ads and trackers, but ONLY for devices whose DNS you point at "
     "this Pi (one device, or your whole router). It changes nothing until "
     "you do that, and its DHCP server stays off.",
     "pihole.sh"),
    ("syncthing", "Syncthing — file sync",
     "Keeps folders in sync between this Pi and your other computers, "
     "privately — no cloud account involved.",
     "syncthing.sh"),
    ("subnet-router", "Subnet router — reach your LAN through Tailscale",
     "Lets your Tailscale network reach the rest of your home network "
     "through this Pi. After installing, the route still needs your "
     "approval in your Tailscale admin page — nothing is shared until "
     "you approve it.",
     "subnet-router.sh"),
]

KEY_RE = re.compile(
    r"^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|"
    r"ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|"
    r"sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/=]+(\s+.*)?$")

jobs = {}          # name -> subprocess.Popen
jobs_lock = threading.Lock()


def state_flag(name):
    return os.path.exists(os.path.join(STATE, name))


def set_flag(name):
    os.makedirs(STATE, exist_ok=True)
    open(os.path.join(STATE, name), "a").close()


def run_capture(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:  # noqa: BLE001 - show the owner what happened
        return 1, str(e)


def start_job(name, argv, logname):
    with jobs_lock:
        p = jobs.get(name)
        if p is not None and p.poll() is None:
            return False
        os.makedirs(STATE, exist_ok=True)
        logf = open(os.path.join(STATE, logname), "wb")
        jobs[name] = subprocess.Popen(argv, stdout=logf,
                                      stderr=subprocess.STDOUT,
                                      start_new_session=True)
        return True


def job_running(name):
    with jobs_lock:
        p = jobs.get(name)
        return p is not None and p.poll() is None


def read_log(logname, limit=6000):
    path = os.path.join(STATE, logname)
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as f:
        data = f.read()
    return data[-limit:].decode("utf-8", "replace")


def key_installed():
    path = os.path.join(HOME, ".ssh", "authorized_keys")
    return os.path.exists(path) and os.path.getsize(path) > 0


def tailscale_state():
    """Returns (present, connected, auth_url)."""
    if shutil.which("tailscale") is None:
        return False, False, ""
    _, out = run_capture(["tailscale", "status"])
    connected = "Logged out" not in out and "not logged in" not in out.lower() \
        and out.strip() != ""
    url = ""
    log = read_log("tailscale.log")
    m = re.findall(r"https://login\.tailscale\.com/\S+", log)
    if m:
        url = m[-1]
    return True, connected, url


def lan_ips():
    rc, out = run_capture(["hostname", "-I"])
    return out.split() if rc == 0 else []


CSS = """
body{font-family:system-ui,sans-serif;max-width:44em;margin:2em auto;
padding:0 1em;line-height:1.45;color:#1c1c1e}
h1{font-size:1.6em} h2{font-size:1.15em;margin-top:1.6em}
.card{border:1px solid #ccc;border-radius:10px;padding:1em 1.2em;margin:1em 0}
.done{color:#137333;font-weight:600}.todo{color:#b06000;font-weight:600}
textarea,input[type=password]{width:100%;box-sizing:border-box;padding:.5em;
margin:.4em 0;font-family:monospace}
button{background:#2456c8;color:#fff;border:0;border-radius:6px;
padding:.55em 1.1em;font-size:1em;cursor:pointer}
pre{background:#111;color:#ddd;padding:.8em;border-radius:8px;
white-space:pre-wrap;word-break:break-word;max-height:16em;overflow:auto}
.small{font-size:.9em;color:#444}
"""


def page(body, refresh=False):
    meta = '<meta http-equiv="refresh" content="5">' if refresh else ""
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
            f"<title>Muse Pi Setup</title>{meta}<style>{CSS}</style>"
            f"</head><body>{body}</body></html>")


def render_home(msg=""):
    busy = job_running("tailscale") or any(
        job_running("extra-" + n) for n, *_ in EXTRAS)
    parts = ["<h1>Set up your Muse Pi</h1>",
             "<p>This short wizard gives your Muse a secure way in, "
             "connects Tailscale if you want it, and offers a few optional "
             "extras. Nothing here leaves this Pi.</p>"]
    if msg:
        parts.append(f"<p><b>{html.escape(msg)}</b></p>")

    # ---- step 1: keys + password
    parts.append("<div class='card'><h2>1. Give your Muse the keys</h2>")
    if key_installed():
        src = " (it was installed from the authorized_keys file on the card)" \
            if state_flag("key-from-boot") else ""
        parts.append(f"<p class='done'>&#10003; SSH key installed{src}.</p>"
                     "<p class='small'>SSH on this Pi accepts keys only — "
                     "password logins are disabled.</p>")
    else:
        parts.append(
            "<p class='todo'>Not done yet.</p>"
            "<p>Ask your Muse for its SSH <b>public</b> key (it starts with "
            "<code>ssh-ed25519</code>) and paste it here. A public key is "
            "safe to share — the private half never leaves your Muse.</p>"
            "<form method='post' action='/key'>"
            "<textarea name='key' rows='3' placeholder='ssh-ed25519 AAAA...'>"
            "</textarea><br><button type='submit'>Install key</button></form>")
    if state_flag("password-set"):
        parts.append("<p class='done'>&#10003; Your password is set.</p>")
    else:
        parts.append(
            f"<p>Set your own password for the <code>{USER}</code> account "
            "(used for the desktop login and for sudo). At least 8 "
            "characters.</p>"
            "<form method='post' action='/password'>"
            "<input type='password' name='pw1' placeholder='New password'>"
            "<input type='password' name='pw2' "
            "placeholder='Repeat it'>"
            "<button type='submit'>Set password</button></form>")
    parts.append("</div>")

    # ---- step 2: tailscale
    parts.append("<div class='card'><h2>2. Connect Tailscale "
                 "(recommended)</h2>")
    present, connected, url = tailscale_state()
    if not present:
        parts.append("<p>Tailscale is still being installed by the "
                     "first-boot setup. This Pi will restart itself once "
                     "or twice — when it settles, open this wizard again "
                     "from the desktop icon and this step will work.</p>")
    elif connected:
        parts.append("<p class='done'>&#10003; Tailscale is connected.</p>"
                     "<p class='small'>Your Muse can now reach this Pi "
                     "over your tailnet, from anywhere.</p>")
    else:
        if job_running("tailscale"):
            if url:
                parts.append(
                    "<p>One link to approve — it opens Tailscale in your "
                    "browser, on <b>your</b> account:</p>"
                    f"<p><a href='{html.escape(url)}' target='_blank'>"
                    f"{html.escape(url)}</a></p>"
                    "<p class='small'>After you approve it there, this page "
                    "updates itself.</p>")
            else:
                parts.append("<p>Starting Tailscale&hellip; your sign-in "
                             "link will appear here in a few seconds.</p>")
        else:
            parts.append(
                "<p>Tailscale lets your Muse reach this Pi securely from "
                "anywhere — no ports opened on your router. Click below, "
                "then approve the sign-in link on your own Tailscale "
                "account.</p>"
                "<form method='post' action='/tailscale'>"
                "<button type='submit'>Connect Tailscale</button></form>")
        log = read_log("tailscale.log")
        if log:
            parts.append(f"<pre>{html.escape(log)}</pre>")
    parts.append("</div>")

    # ---- step 3: extras
    parts.append("<div class='card'><h2>3. Optional extras</h2>"
                 "<p>Install only what you want — each one is a small "
                 "script you (or your Muse) can read first at "
                 "<code>/usr/local/muse-pi/extras/</code>.</p>")
    for name, title, desc, script in EXTRAS:
        done = state_flag(f"extra-{name}.done")
        running = job_running("extra-" + name)
        parts.append(f"<h3>{html.escape(title)}</h3><p>{html.escape(desc)}</p>")
        if done:
            parts.append("<p class='done'>&#10003; Installed.</p>")
        elif running:
            parts.append("<p class='todo'>Installing&hellip; this page "
                         "refreshes itself.</p>")
        else:
            parts.append(
                f"<form method='post' action='/extra/{name}'>"
                "<button type='submit'>Install</button></form>")
        log = read_log(f"extra-{name}.log")
        if log and (running or done):
            parts.append(f"<pre>{html.escape(log[-2500:])}</pre>")
    parts.append("</div>")

    # ---- step 4: done
    parts.append("<div class='card'><h2>4. Finish</h2>"
                 "<p>When steps 1 is done (and 2, if you want it), click "
                 "Finish. The wizard switches itself off and stops opening "
                 "on the desktop. You can bring it back any time from the "
                 "desktop icon.</p>"
                 "<form method='post' action='/done'>"
                 "<button type='submit'>Finish setup</button></form></div>")
    return page("".join(parts), refresh=busy)


def render_done():
    ips = lan_ips()
    ip_txt = html.escape(ips[0]) if ips else HOSTNAME
    body = (f"<h1>Your Pi is ready</h1>"
            f"<p>Hostname: <code>{html.escape(HOSTNAME)}</code><br>"
            f"Network address: <code>{ip_txt}</code></p>"
            f"<p><b>Tell your Muse:</b> &ldquo;the Pi is ready&rdquo; — "
            f"it can connect as <code>{html.escape(USER)}@{ip_txt}</code> "
            f"with the key you gave it.</p>"
            "<p class='small'>The setup wizard has switched itself off. "
            "To run it again, use the &ldquo;Muse Pi Setup&rdquo; icon on "
            "the desktop.</p>")
    return page(body)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the journal quiet
        pass

    def _send(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if urlparse(self.path).path == "/":
            self._send(render_home())
        else:
            self._send(page("<h1>Not found</h1>"), 404)

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        msg = ""
        if path == "/key":
            key = (form.get("key") or [""])[0].strip().splitlines()
            key = key[0].strip() if key else ""
            if not KEY_RE.match(key):
                msg = "That does not look like an SSH public key — it should " \
                      "start with ssh-ed25519 (or ssh-rsa / ecdsa-...)."
            else:
                sshdir = os.path.join(HOME, ".ssh")
                os.makedirs(sshdir, mode=0o700, exist_ok=True)
                dest = os.path.join(sshdir, "authorized_keys")
                with open(dest, "a") as f:
                    f.write(key + "\n")
                uid = int(subprocess.run(["id", "-u", USER], capture_output=True,
                                         text=True).stdout.strip())
                gid = int(subprocess.run(["id", "-g", USER], capture_output=True,
                                         text=True).stdout.strip())
                os.chown(sshdir, uid, gid)
                os.chmod(sshdir, 0o700)
                os.chown(dest, uid, gid)
                os.chmod(dest, 0o600)
                msg = "Key installed."
            self._send(render_home(msg))
        elif path == "/password":
            pw1 = (form.get("pw1") or [""])[0]
            pw2 = (form.get("pw2") or [""])[0]
            if len(pw1) < 8:
                msg = "Password needs at least 8 characters."
            elif pw1 != pw2:
                msg = "The two passwords do not match."
            else:
                r = subprocess.run(["chpasswd"], input=f"{USER}:{pw1}\n",
                                   text=True, capture_output=True)
                if r.returncode == 0:
                    set_flag("password-set")
                    msg = "Password set."
                else:
                    msg = "Setting the password failed: " + r.stderr.strip()
            self._send(render_home(msg))
        elif path == "/tailscale":
            if shutil.which("tailscale"):
                start_job("tailscale",
                          ["tailscale", "up", "--hostname", HOSTNAME],
                          "tailscale.log")
            self._send(render_home())
        elif path.startswith("/extra/"):
            name = path.split("/", 2)[2]
            for n, _t, _d, script in EXTRAS:
                if n == name:
                    start_job("extra-" + n,
                              ["/bin/bash", os.path.join(EXTRAS_DIR, script)],
                              f"extra-{n}.log")
            self._send(render_home())
        elif path == "/done":
            try:
                os.remove(os.path.join(STATE, "setup-pending"))
            except FileNotFoundError:
                pass
            set_flag("setup-done")
            subprocess.Popen(["systemd-run", "--on-active=3",
                              "/bin/systemctl", "disable", "--now",
                              "muse-pi-wizard.service"],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL,
                             start_new_session=True)
            self._send(render_done())
        else:
            self._send(page("<h1>Not found</h1>"), 404)


if __name__ == "__main__":
    os.makedirs(STATE, exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
