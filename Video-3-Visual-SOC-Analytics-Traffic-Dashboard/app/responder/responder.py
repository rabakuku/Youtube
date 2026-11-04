#!/usr/bin/env python3
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/app/responder/responder.py
# -----------------------------------------------------------------------------
# Visual SOC responder — Grafana alert → ntfy (buttons) → FortiGate quarantine
#
#   :8092  INTERNAL (soc_net only, not published)  POST /grafana   Grafana webhook
#                                                  POST /release-all  (rollback.sh)
#   :8091  PUBLIC   (VIP 172.24.66.52:8091)        GET|POST /a/<token>  button actions
#   both   GET /health
#
# Quarantine = FortiGate address object  Q-<ip>  added to address group
# SOC-Quarantine, which is the source of the top deny policy SOC_Quarantine_Block.
#
# Python standard library only. Configuration comes from environment variables
# (compose/.env). With no FGT_API_TOKEN the service runs in DRY-RUN mode: every
# step happens (notifications, timers, audit) except the FortiGate API calls.
# -----------------------------------------------------------------------------
import base64
import hashlib
import hmac
import html
import ipaddress
import json
import os
import secrets
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def env(name, default=""):
    return os.environ.get(name, default).strip()


CFG = {
    "fgt_host": env("FGT_HOST", "192.168.10.1"),
    "fgt_token": env("FGT_API_TOKEN"),
    "fgt_verify_tls": env("FGT_VERIFY_TLS", "false").lower() == "true",
    "fgt_vdom": env("FGT_VDOM", "root"),
    "fgt_group": env("FGT_QUARANTINE_GROUP", "SOC-Quarantine"),
    "fgt_prefix": env("FGT_ADDR_PREFIX", "Q-"),
    "ntfy_url": env("NTFY_INTERNAL_URL", "http://soc-ntfy:80").rstrip("/"),
    "ntfy_topic": env("NTFY_TOPIC"),
    "public_responder": env("PUBLIC_RESPONDER_URL", "http://172.24.66.52:8091").rstrip("/"),
    "public_grafana": env("PUBLIC_GRAFANA_URL", "http://172.24.66.52:8080").rstrip("/"),
    "loki_url": env("LOKI_URL", "http://soc-loki:3100").rstrip("/"),
    "mode": env("QUARANTINE_MODE", "approve").lower(),
    "minutes": float(env("QUARANTINE_MINUTES", "15") or 15),
    "allowlist": [n for n in env("QUARANTINE_ALLOWLIST", "192.168.10.0/24").split(",") if n.strip()],
    "secret": env("RESPONDER_SECRET"),
    "link_ttl": int(env("LINK_TTL_SECONDS", "1800") or 1800),
    "internal_nets": [n for n in env("INTERNAL_NETS", "10.89.0.0/24,127.0.0.0/8").split(",") if n.strip()],
    "state_file": env("STATE_FILE", "/data/state.json"),
    "public_port": int(env("PUBLIC_PORT", "8091")),
    "internal_port": int(env("INTERNAL_PORT", "8092")),
}
DRY_RUN = env("DRY_RUN", "false").lower() == "true" or not CFG["fgt_token"]
ALLOW_NETS = [ipaddress.ip_network(n.strip(), strict=False) for n in CFG["allowlist"]]
INTERNAL_NETS = [ipaddress.ip_network(n.strip(), strict=False) for n in CFG["internal_nets"]]
LOCK = threading.RLock()


def log(msg, **kv):
    extra = " ".join(f"{k}={v}" for k, v in kv.items())
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg} {extra}".rstrip(), flush=True)


def fmt_minutes(m):
    return f"{int(m)} minute{'s' if int(m) != 1 else ''}" if float(m).is_integer() else f"{m:g} minutes"


# --- state ------------------------------------------------------------------------
STATE = {"quarantined": {}, "pending": {}, "used": {}}


def load_state():
    try:
        with open(CFG["state_file"]) as f:
            data = json.load(f)
        for k in STATE:
            STATE[k] = data.get(k, {})
        log("state loaded", quarantined=len(STATE["quarantined"]), pending=len(STATE["pending"]))
    except FileNotFoundError:
        pass
    except Exception as e:  # corrupt file: start clean but keep a copy
        log("state unreadable, starting clean", error=e)
        try:
            os.replace(CFG["state_file"], CFG["state_file"] + ".bad")
        except OSError:
            pass


def save_state():
    os.makedirs(os.path.dirname(CFG["state_file"]) or ".", exist_ok=True)
    tmp = CFG["state_file"] + ".tmp"
    with open(tmp, "w") as f:
        json.dump(STATE, f, indent=1)
    os.replace(tmp, CFG["state_file"])


# --- helpers -----------------------------------------------------------------------
def valid_ip(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if a.version != 4 or a.is_unspecified or a.is_multicast or a.is_loopback:
        return None
    return str(a)


def allowlisted(ip):
    a = ipaddress.ip_address(ip)
    return any(a in n for n in ALLOW_NETS)


def is_internal(client_ip):
    try:
        a = ipaddress.ip_address(client_ip)
    except ValueError:
        return False
    return any(a in n for n in INTERNAL_NETS)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_link(act, ip, ttl=None):
    exp = int(time.time()) + (ttl or CFG["link_ttl"])
    payload = f"{act}|{ip}|{exp}|{secrets.token_hex(8)}".encode()
    sig = hmac.new(CFG["secret"].encode(), payload, hashlib.sha256).digest()[:16]
    return f"{CFG['public_responder']}/a/{b64(payload)}.{b64(sig)}"


def check_token(token):
    """Return (act, ip, nonce, exp) or raise ValueError."""
    try:
        p64, s64 = token.split(".", 1)
        payload, sig = unb64(p64), unb64(s64)
    except Exception:
        raise ValueError("malformed link")
    good = hmac.new(CFG["secret"].encode(), payload, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(good, sig):
        raise ValueError("invalid signature")
    act, ip, exp, nonce = payload.decode().split("|")
    if int(exp) < time.time():
        raise ValueError("link expired")
    if act not in ("q", "i", "r") or not valid_ip(ip):
        raise ValueError("bad action")
    return act, ip, nonce, int(exp)


# --- integrations ------------------------------------------------------------------
def http_json(method, url, body=None, headers=None, ctx=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:300].decode(errors="replace")}


def ntfy(title, message, priority=3, tags=None, actions=None, click=None):
    if not CFG["ntfy_topic"]:
        log("ntfy topic not set, skipping notification", title=title)
        return
    body = {"topic": CFG["ntfy_topic"], "title": title, "message": message,
            "priority": priority, "tags": tags or [], "markdown": True}
    if actions:
        body["actions"] = actions
    if click:
        body["click"] = click
    try:
        status, resp = http_json("POST", CFG["ntfy_url"] + "/", body, timeout=5)
        if status >= 300:
            log("ntfy publish failed", status=status, resp=resp)
    except Exception as e:
        log("ntfy publish error", error=e)


def audit(event, ip, **fields):
    """Write one audit line to Loki (label source=responder) for the wallboard."""
    line = json.dumps({"event": event, "ip": ip, "dry_run": DRY_RUN, **fields})
    body = {"streams": [{"stream": {"source": "responder", "event": event},
                         "values": [[str(time.time_ns()), line]]}]}
    try:
        http_json("POST", CFG["loki_url"] + "/loki/api/v1/push", body, timeout=5)
    except Exception as e:
        log("loki audit push failed", error=e)
    log(f"AUDIT {event}", ip=ip, **{k: v for k, v in fields.items() if k != "alert"})


class FortiGate:
    def __init__(self):
        self.base = f"https://{CFG['fgt_host']}/api/v2/cmdb"
        self.ctx = ssl.create_default_context()
        if not CFG["fgt_verify_tls"]:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE
        self.headers = {"Authorization": f"Bearer {CFG['fgt_token']}", "Accept": "application/json"}

    def _call(self, method, path, body=None):
        sep = "&" if "?" in path else "?"
        url = f"{self.base}{path}{sep}vdom={urllib.parse.quote(CFG['fgt_vdom'])}"
        return http_json(method, url, body, self.headers, self.ctx)

    @staticmethod
    def _ok(status, resp):
        return status == 200 and resp.get("status", "success") == "success"

    def name(self, ip):
        return f"{CFG['fgt_prefix']}{ip}"

    def members(self):
        status, resp = self._call("GET", f"/firewall/addrgrp/{urllib.parse.quote(CFG['fgt_group'])}")
        if not self._ok(status, resp) or not resp.get("results"):
            raise RuntimeError(f"cannot read group {CFG['fgt_group']}: HTTP {status} {resp}")
        return [m["name"] for m in resp["results"][0].get("member", [])]

    def _set_members(self, names):
        if "none" not in names:
            names = ["none"] + names  # FortiOS refuses an empty address group
        status, resp = self._call("PUT", f"/firewall/addrgrp/{urllib.parse.quote(CFG['fgt_group'])}",
                                  {"member": [{"name": n} for n in names]})
        if not self._ok(status, resp):
            raise RuntimeError(f"cannot update group: HTTP {status} {resp}")

    def quarantine(self, ip):
        obj = self.name(ip)
        status, resp = self._call("POST", "/firewall/address", {
            "name": obj, "subnet": f"{ip} 255.255.255.255",
            "comment": "Visual SOC quarantine - managed by soc-responder"})
        if not self._ok(status, resp):
            st2, r2 = self._call("GET", f"/firewall/address/{urllib.parse.quote(obj)}")
            if not self._ok(st2, r2):  # not "already exists" -> real failure
                raise RuntimeError(f"cannot create address {obj}: HTTP {status} {resp}")
        current = self.members()
        if obj not in current:
            self._set_members(current + [obj])  # "none" stays as the permanent placeholder

    def release(self, ip):
        obj = self.name(ip)
        current = self.members()
        if obj in current:
            self._set_members([m for m in current if m != obj])
        status, resp = self._call("DELETE", f"/firewall/address/{urllib.parse.quote(obj)}")
        if not (self._ok(status, resp) or status == 404):
            log("address delete failed (left in place, harmless)", obj=obj, status=status)


FGT = FortiGate()


# --- core actions -----------------------------------------------------------------
def describe(alert):
    labels = alert.get("labels", {})
    ann = alert.get("annotations", {})
    return labels.get("alertname", "Alert"), ann.get("description") or ann.get("summary") or ""


def quarantine(ip, reason, by):
    with LOCK:
        if ip in STATE["quarantined"]:
            return "already quarantined"
        if allowlisted(ip):
            return "allowlisted"
        if not DRY_RUN:
            try:
                FGT.quarantine(ip)
            except Exception as e:
                audit("quarantine_failed", ip, reason=reason, error=str(e))
                ntfy(f"Quarantine FAILED for {ip}", f"FortiGate API error:\n`{e}`", 5, ["x"])
                return f"failed: {e}"
        until = time.time() + CFG["minutes"] * 60
        STATE["quarantined"][ip] = {"since": time.time(), "until": until, "reason": reason, "by": by}
        STATE["pending"].pop(ip, None)
        save_state()
    mins = fmt_minutes(CFG["minutes"])
    audit("quarantine", ip, minutes=CFG["minutes"], reason=reason, by=by, mode=CFG["mode"])
    heartbeat()
    ntfy(f"{ip} quarantined for {mins}",
         f"**Reason:** {reason}\n**By:** {by}\n**Until:** {time.strftime('%H:%M:%S', time.localtime(until))}\n\n"
         f"Every new connection from {ip} is now denied by *SOC_Quarantine_Block*."
         + ("\n\n_DRY RUN: no FortiGate change was made._" if DRY_RUN else ""),
         4, ["no_entry"],
         [{"action": "http", "label": "Release now", "method": "POST", "clear": True,
           "url": make_link("r", ip, ttl=int(CFG["minutes"] * 60) + 600)},  # valid for the whole quarantine
          {"action": "view", "label": "Wallboard", "url": CFG["public_grafana"] + "/d/fortinet-visual-soc"}])
    return "quarantined"


def release(ip, why):
    with LOCK:
        entry = STATE["quarantined"].get(ip)
        if not entry:
            return "not quarantined"
        if not DRY_RUN:
            try:
                FGT.release(ip)
            except Exception as e:
                audit("release_failed", ip, error=str(e))
                ntfy(f"Release FAILED for {ip}", f"FortiGate API error:\n`{e}`\nRetrying in 60 s.", 5, ["x"])
                entry["until"] = time.time() + 60
                save_state()
                return f"failed: {e}"
        STATE["quarantined"].pop(ip, None)
        save_state()
    held = (time.time() - entry["since"]) / 60
    audit("release", ip, why=why, held_minutes=round(held, 1))
    heartbeat()
    ntfy(f"{ip} released", f"Quarantine lifted ({why}) after {held:.1f} minutes.\n{ip} can connect again.",
         3, ["white_check_mark"])
    return "released"


def handle_alert(alert):
    labels = alert.get("labels", {})
    name, text = describe(alert)
    ip = valid_ip(labels.get("srcip", ""))
    if alert.get("status") != "firing":
        if not ip:  # health alerts (e.g. log feed silent) get a resolved message
            ntfy(f"Resolved: {name}", text or "Back to normal.", 2, ["white_check_mark"])
        return "resolved"
    if not ip:
        ntfy(name, text, 4, ["warning"], click=CFG["public_grafana"] + "/d/visual-soc-detections")
        return "notified"
    if allowlisted(ip):
        audit("allowlisted", ip, alert=name)
        ntfy(f"{name}: {ip} (allowlisted)", f"{text}\n\nNo action: {ip} is on the allowlist.", 2, ["information_source"])
        return "allowlisted"
    with LOCK:
        if ip in STATE["quarantined"]:
            return "already quarantined"
        pend = STATE["pending"].get(ip)
        if pend and pend["exp"] > time.time():
            return "approval pending"
    if CFG["mode"] == "auto":
        return quarantine(ip, name, "auto (Grafana alert)")
    with LOCK:
        STATE["pending"][ip] = {"alert": name, "exp": time.time() + CFG["link_ttl"]}
        save_state()
    audit("approval_requested", ip, alert=name)
    mins = fmt_minutes(CFG["minutes"])
    ntfy(f"{name}: {ip}", f"{text}\n\nQuarantine **{ip}** for {mins}?",
         5 if labels.get("severity") == "critical" else 4, ["rotating_light"],
         [{"action": "http", "label": f"Quarantine {mins}", "url": make_link("q", ip), "method": "POST", "clear": True},
          {"action": "http", "label": "Ignore", "url": make_link("i", ip), "method": "POST", "clear": True},
          {"action": "view", "label": "Wallboard", "url": CFG["public_grafana"] + "/d/fortinet-visual-soc"}],
         click=CFG["public_grafana"] + "/d/visual-soc-detections")
    return "approval requested"


def run_action(act, ip, nonce, exp, client):
    with LOCK:
        if nonce in STATE["used"]:
            return "link already used"
        STATE["used"][nonce] = exp
        save_state()
    by = f"admin via ntfy ({client})"
    if act == "q":
        return quarantine(ip, STATE["pending"].get(ip, {}).get("alert", "manual approval"), by)
    if act == "i":
        with LOCK:
            STATE["pending"].pop(ip, None)
            save_state()
        audit("ignored", ip, by=by)
        ntfy(f"Ignored alert for {ip}", "No action taken.", 2, ["see_no_evil"])
        return "ignored"
    return release(ip, f"released by {by}")


def heartbeat():
    """Current quarantine list -> Loki every 30 s, so Grafana can show who is quarantined *now*."""
    with LOCK:
        ips = sorted(STATE["quarantined"])
        until = {ip: time.strftime("%H:%M:%S", time.localtime(STATE["quarantined"][ip]["until"])) for ip in ips}
    line = json.dumps({"event": "state", "count": len(ips), "ips": ",".join(ips) or "-", "until": until,
                       "mode": CFG["mode"], "dry_run": DRY_RUN})
    body = {"streams": [{"stream": {"source": "responder", "event": "state"}, "values": [[str(time.time_ns()), line]]}]}
    try:
        http_json("POST", CFG["loki_url"] + "/loki/api/v1/push", body, timeout=5)
    except Exception as e:
        log("loki heartbeat failed", error=e)


def ticker():
    last_beat = 0
    while True:
        time.sleep(5)
        now = time.time()
        if now - last_beat >= 30:
            heartbeat(); last_beat = now
        try:
            for ip, e in list(STATE["quarantined"].items()):
                if e["until"] <= now:
                    release(ip, "timer expired")
            with LOCK:
                changed = False
                for ip, p in list(STATE["pending"].items()):
                    if p["exp"] <= now:
                        STATE["pending"].pop(ip); changed = True
                for n, exp in list(STATE["used"].items()):
                    if exp <= now:
                        STATE["used"].pop(n); changed = True
                if changed:
                    save_state()
        except Exception as e:
            log("ticker error", error=e)


def reconcile():
    """Never leave an orphaned ban behind: adopt Q-* members unknown to our state."""
    if DRY_RUN:
        return
    try:
        members = FGT.members()
    except Exception as e:
        log("reconcile: cannot read FortiGate group (will keep running)", error=e)
        return
    pre = CFG["fgt_prefix"]
    with LOCK:
        for m in members:
            ip = valid_ip(m[len(pre):]) if m.startswith(pre) else None
            if ip and ip not in STATE["quarantined"]:
                STATE["quarantined"][ip] = {"since": time.time(), "until": time.time() + CFG["minutes"] * 60,
                                            "reason": "found on FortiGate at startup", "by": "reconcile"}
                ntfy(f"Adopted existing quarantine: {ip}",
                     f"Found {m} in {CFG['fgt_group']}; it will be released in {fmt_minutes(CFG['minutes'])}.",
                     3, ["information_source"])
        for ip in list(STATE["quarantined"]):
            if f"{pre}{ip}" not in members:
                log("state had a quarantine the FortiGate no longer has; dropping", ip=ip)
                STATE["quarantined"].pop(ip)
        save_state()


# --- HTTP -------------------------------------------------------------------------
PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Visual SOC responder</title><style>body{{font-family:system-ui,sans-serif;background:#070a13;color:#f8fafc;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}}.c{{background:#0f172a;border:1px solid
#38bdf8;border-radius:10px;padding:2rem 2.5rem;max-width:32rem}}h1{{font-size:1.3rem;margin:0 0 .6rem}}p{{color:#94a3b8}}
button{{background:#ee2737;color:#fff;border:0;border-radius:6px;padding:.7rem 1.4rem;font-weight:700;font-size:1rem;cursor:pointer}}
</style></head><body><div class="c"><h1>{title}</h1><p>{body}</p>{form}</div></body></html>"""
LABEL = {"q": "Quarantine", "i": "Ignore alert for", "r": "Release"}


class Base(BaseHTTPRequestHandler):
    server_version = "soc-responder/1.0"

    def log_message(self, fmt, *args):
        log(f"http {self.client_address[0]} " + fmt % args)

    def send(self, code, body, ctype="application/json"):
        data = (json.dumps(body) if ctype == "application/json" else body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if ctype.startswith("text") else ""))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def health(self):
        self.send(200, {"ok": True, "dry_run": DRY_RUN, "mode": CFG["mode"],
                        "quarantined": sorted(STATE["quarantined"]), "pending": sorted(STATE["pending"])})


class Internal(Base):
    def do_GET(self):
        if self.path == "/health":
            return self.health()
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if not is_internal(self.client_address[0]):
            return self.send(403, {"error": "internal only"})
        if self.path == "/release-all":  # used by rollback.sh before the stack is removed
            ips = sorted(STATE["quarantined"])
            return self.send(200, {"released": {ip: release(ip, "stack shutdown (rollback.sh)") for ip in ips}})
        if self.path != "/grafana":
            return self.send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(min(length, 1_000_000)) or b"{}")
        except Exception:
            return self.send(400, {"error": "bad json"})
        results = [handle_alert(a) for a in payload.get("alerts", [])]
        self.send(200, {"results": results})


class Public(Base):
    def do_OPTIONS(self):  # CORS preflight from the ntfy web app
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def _token(self):
        return self.path.split("?")[0][len("/a/"):] if self.path.startswith("/a/") else None

    def do_GET(self):
        if self.path == "/health":
            return self.health()
        token = self._token()
        if not token:
            return self.send(404, PAGE.format(title="Not found", body="", form=""), "text/html")
        try:
            act, ip, _, _ = check_token(token)
        except ValueError as e:
            return self.send(403, PAGE.format(title="Link not valid", body=html.escape(str(e)), form=""), "text/html")
        form = f'<form method="post"><button type="submit">{LABEL[act]} {html.escape(ip)}</button></form>'
        self.send(200, PAGE.format(title=f"{LABEL[act]} {html.escape(ip)}?",
                                   body="Confirm the action below.", form=form), "text/html")

    def do_POST(self):
        token = self._token()
        if not token:
            return self.send(404, {"error": "not found"})
        try:
            act, ip, nonce, exp = check_token(token)
        except ValueError as e:
            return self.send(403, {"error": str(e)})
        result = run_action(act, ip, nonce, exp, self.client_address[0])
        if "text/html" in self.headers.get("Accept", ""):
            return self.send(200, PAGE.format(title=f"{html.escape(ip)}: {html.escape(result)}",
                                              body="You can close this tab.", form=""), "text/html")
        self.send(200, {"ip": ip, "result": result})


def main():
    if not CFG["secret"] or len(CFG["secret"]) < 16:
        sys.exit("RESPONDER_SECRET missing or shorter than 16 characters (setup.sh generates it).")
    if CFG["mode"] not in ("approve", "auto"):
        sys.exit("QUARANTINE_MODE must be 'approve' or 'auto'.")
    load_state()
    log("soc-responder starting", mode=CFG["mode"], minutes=CFG["minutes"], dry_run=DRY_RUN,
        fgt=CFG["fgt_host"], group=CFG["fgt_group"], allowlist=",".join(CFG["allowlist"]))
    if DRY_RUN:
        log("DRY-RUN: no FGT_API_TOKEN set (or DRY_RUN=true) - FortiGate will not be changed")
    reconcile()
    threading.Thread(target=ticker, daemon=True).start()
    internal = ThreadingHTTPServer(("0.0.0.0", CFG["internal_port"]), Internal)
    threading.Thread(target=internal.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", CFG["public_port"]), Public).serve_forever()


if __name__ == "__main__":
    main()
