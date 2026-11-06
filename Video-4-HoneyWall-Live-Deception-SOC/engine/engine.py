#!/usr/bin/env python3
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/engine/engine.py
"""
HoneyWall engine

  Cowrie JSON log  ->  normalize + MITRE tags  ->  rules (brute force / honeytoken)
      ->  FortiGate REST ban + read-back confirmation (Time-to-Quarantine)
      ->  dashboard live stream (SSE) + ntfy alert + incident report (template or LLM)

Single dependency: aiohttp. All settings come from environment variables (.env).
"""

import asyncio
import datetime as dt
import glob
import ipaddress
import json
import os
import random
import re
import shlex
import struct
import sys
import time
from collections import Counter, deque

from aiohttp import ClientSession, ClientTimeout, TCPConnector, web

# --------------------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------------------


def env(name, default=""):
    v = os.environ.get(name)
    return default if v is None or v == "" else v


def env_bool(name, default=False):
    return env(name, "true" if default else "false").strip().lower() in ("1", "true", "yes", "on")


def env_int(name, default):
    try:
        return int(env(name, str(default)))
    except ValueError:
        return default


def env_list(name, default=""):
    return [x.strip() for x in env(name, default).split(",") if x.strip()]


def is_placeholder(v):
    return (not v) or (v.startswith("<") and v.endswith(">"))


CFG = {
    "cowrie_log": env("COWRIE_LOG", "/cowrie-var/log/cowrie/cowrie.json"),
    "web_log": env("WEB_DECOY_LOG", "/decoy-web-log/web.json"),
    "web_enabled": env_bool("WEB_DECOY_ENABLED", True),
    "web_vip_port": env_int("WEB_DECOY_VIP_PORT", 80),
    "web_honeytokens": env_list("WEB_HONEYTOKENS", "/.env,/backup/.env.bak,/backup/db_dump.sql"),
    "tty_dir": env("COWRIE_TTY_DIR", "/cowrie-var/lib/cowrie/tty"),
    "data_dir": env("DATA_DIR", "/data"),
    "listen": env("ENGINE_LISTEN", "0.0.0.0:8000"),
    # lab identity
    "fgt_host": env("FGT_HOST", "192.168.10.1"),
    "fgt_wan_ip": env("FGT_WAN_IP", "172.24.66.58"),
    "alpine_ip": env("ALPINE_IP", "192.168.10.2"),
    "kali_ip": env("KALI_IP", "192.168.40.3"),
    "decoy_vip_ip": env("DECOY_VIP_IP", "192.168.40.1"),
    "decoy_vip_port": env_int("DECOY_VIP_PORT", 22),
    "decoy_hostname": env("DECOY_HOSTNAME", "srv-corp-ssh01"),
    "leaked_user": env("DECOY_LEAKED_USER", "svc_backup"),
    # FortiGate
    "fgt_token": env("FGT_API_TOKEN", ""),
    "fgt_vdom": env("FGT_VDOM", "root"),
    "fgt_verify_tls": env_bool("FGT_VERIFY_TLS", False),
    "fgt_simulate": env_bool("FGT_SIMULATE", False),
    "enforcement_mode": env("ENFORCEMENT_MODE", "rest-ban"),
    "ban_expiry": env_int("BAN_EXPIRY", 0),
    "close_sessions": env_bool("FGT_CLOSE_SESSIONS", True),
    "never_ban": env_list("NEVER_BAN", "192.168.10.0/24"),
    "ban_poll_sec": env_int("BAN_POLL_SEC", 3),
    # rules
    "brute_threshold": env_int("BRUTE_THRESHOLD", 5),
    "brute_window": env_int("BRUTE_WINDOW_SEC", 30),
    "honeytokens": env_list("HONEYTOKENS", "/root/.aws/credentials"),
    "high_risk": [x for x in env("HIGH_RISK_COMMANDS", "wget ,curl ,chmod +x").split(",") if x.strip()],
    # dashboard defaults
    "title": env("DASHBOARD_TITLE", "HoneyWall"),
    "theme": env("DASHBOARD_THEME", "hollywood"),
    "sound": env_bool("DASHBOARD_SOUND", True),
    "flash": env_bool("DASHBOARD_FLASH", True),
    "layout": env("DASHBOARD_LAYOUT", "full"),
    "token": env("DASHBOARD_TOKEN", ""),
    "public_url": env("DASHBOARD_PUBLIC_URL", "http://172.24.66.58:8080"),
    # ntfy
    "ntfy_enabled": env_bool("NTFY_ENABLED", True),
    "ntfy_url": env("NTFY_URL", "http://ntfy:80").rstrip("/"),
    "ntfy_topic": env("NTFY_TOPIC", "honeywall"),
    "ntfy_public": env("NTFY_BASE_URL", "http://172.24.66.58:8090").rstrip("/"),
    # LLM
    "llm_enabled": env_bool("LLM_ENABLED", False),
    "llm_mode": env("LLM_ACCESS_MODE", "tailscale"),
    "llm_base_url": env("LLM_BASE_URL", ""),
    "llm_api_key": env("LLM_API_KEY", ""),
    "llm_model": env("LLM_MODEL", "llama3.1:8b"),
    "llm_timeout": env_int("LLM_TIMEOUT_SEC", 60),
    "llm_proxy": env("LLM_HTTP_PROXY", ""),
    "llm_verify_tls": env_bool("LLM_VERIFY_TLS", True),
    "report_delay": env_int("REPORT_DELAY_SEC", 4),
}

NEVER_BAN_NETS = []
for _c in CFG["never_ban"]:
    try:
        NEVER_BAN_NETS.append(ipaddress.ip_network(_c, strict=False))
    except ValueError:
        pass

# --------------------------------------------------------------------------------------
# Pretty logs (they look good in `docker compose logs -f engine` on camera)
# --------------------------------------------------------------------------------------

C = {"r": "\033[0m", "red": "\033[1;31m", "grn": "\033[1;32m", "yel": "\033[1;33m",
     "cyn": "\033[1;36m", "mag": "\033[1;35m", "dim": "\033[2m"}


def log(tag, msg, color="cyn"):
    stamp = dt.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"{C['dim']}{stamp}{C['r']} {C[color]}[{tag:^10}]{C['r']} {msg}", flush=True)


# --------------------------------------------------------------------------------------
# MITRE ATT&CK mapping
# --------------------------------------------------------------------------------------

MITRE = {
    "T1046": "Network Service Discovery",
    "T1110.001": "Brute Force: Password Guessing",
    "T1078": "Valid Accounts",
    "T1021.004": "Remote Services: SSH",
    "T1059.004": "Unix Shell",
    "T1082": "System Information Discovery",
    "T1033": "System Owner/User Discovery",
    "T1083": "File and Directory Discovery",
    "T1552.001": "Credentials In Files",
    "T1105": "Ingress Tool Transfer",
    "T1548.003": "Sudo and Sudo Caching",
    "T1070.003": "Clear Command History",
    "T1053.003": "Scheduled Task: Cron",
    "T1222.002": "File Permissions Modification",
    "T1005": "Data from Local System",
    "T1595.002": "Active Scanning: Vulnerability Scanning",
    "T1595.003": "Active Scanning: Wordlist Scanning",
    "T1190": "Exploit Public-Facing Application",
}

CMD_RULES = [
    (re.compile(r"^(uname|hostname|lscpu|cat /etc/(os-release|issue)|cat /proc/(cpuinfo|version)|free|df|uptime)\b"), "T1082"),
    (re.compile(r"^(whoami|id|w|who|last|groups)\b"), "T1033"),
    (re.compile(r"^(ls|find|tree|locate|du)\b"), "T1083"),
    (re.compile(r"^(wget|curl|tftp|scp|ftpget)\b"), "T1105"),
    (re.compile(r"^sudo\b"), "T1548.003"),
    (re.compile(r"^history\s+-c|unset\s+HISTFILE"), "T1070.003"),
    (re.compile(r"^crontab\b"), "T1053.003"),
    (re.compile(r"^chmod\b"), "T1222.002"),
    (re.compile(r"^(cat|less|more|head|tail|strings|mysqldump|tar|zip|gzip)\b"), "T1005"),
]


def tags(*ids):
    return [{"id": i, "name": MITRE.get(i, "")} for i in dict.fromkeys(ids)]


def split_commands(line):
    parts = re.split(r"\s*(?:&&|\|\||;|\|)\s*", line.strip())
    return [p for p in parts if p]


def classify_command(line):
    ids = ["T1059.004"]
    for seg in split_commands(line):
        for rx, tid in CMD_RULES:
            if rx.search(seg):
                ids.append(tid)
    return ids


def honeytoken_hit(line):
    try:
        words = shlex.split(line, posix=True)
    except ValueError:
        words = line.split()
    for path in CFG["honeytokens"]:
        if path in line:
            return path
        base = os.path.basename(path)
        for w in words:
            if w == base or w.endswith("/" + base):
                return path
    return None


def high_risk(line):
    low = line.lower()
    return [h for h in CFG["high_risk"] if h.strip() and h.lower() in low]


def never_ban(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return any(a in n for n in NEVER_BAN_NETS)


def parse_ts(s):
    if not s:
        return time.time()
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return time.time()


def iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------------------


class Attacker:
    def __init__(self, ip, t):
        self.ip = ip
        self.first_seen = t
        self.last_seen = t
        self.status = "watching"  # watching | triggered | quarantined | released
        self.fails = deque()
        self.counts = Counter()
        self.creds = deque(maxlen=80)
        self.commands = deque(maxlen=150)
        self.sessions = set()
        self.honeytokens = []
        self.high_risk = 0
        self.success_users = set()
        self.mitre = Counter()
        self.ban = None
        self.history = []
        self.cycle_start = t   # reset on Unban so each act gets its own report

    @property
    def score(self):
        if self.status in ("triggered", "quarantined"):
            return 100
        s = (self.counts["failed"] * 8 + self.counts["success"] * 20 + self.counts["command"] * 3
             + self.high_risk * 15 + len(self.honeytokens) * 100 + self.counts["recon"] * 5)
        return min(100, s)

    def to_dict(self):
        return {
            "ip": self.ip, "first_seen": iso(self.first_seen), "last_seen": iso(self.last_seen),
            "status": self.status, "score": self.score, "counts": dict(self.counts),
            "creds": list(self.creds)[-30:], "commands": list(self.commands)[-60:],
            "sessions": sorted(self.sessions), "honeytokens": self.honeytokens,
            "success_users": sorted(self.success_users),
            "mitre": [{"id": k, "name": MITRE.get(k, ""), "count": v} for k, v in self.mitre.most_common()],
            "ban": self.ban, "history": self.history[-10:],
        }


class State:
    def __init__(self):
        self.attackers = {}
        self.events = deque(maxlen=400)
        self.pass_counter = Counter()
        self.user_counter = Counter()
        self.sessions = {}
        self.session_tty = {}
        self.bans = {}            # ip -> metadata (reason, ttq, ...) - merged with FortiGate list
        self.fgt_bans = []        # last list read from FortiGate
        self.fgt = {"online": False, "hostname": "", "version": "", "serial": "", "latency_ms": None,
                    "simulate": CFG["fgt_simulate"], "error": "", "checked": None}
        self.reports = []
        self.settings = {"llm_enabled": CFG["llm_enabled"]}
        self.scoreboard = []      # [{ip, rule, ttq_ms, at}]
        self.seq = 0
        self.clients = set()

    def attacker(self, ip, t):
        a = self.attackers.get(ip)
        if a is None:
            a = self.attackers[ip] = Attacker(ip, t)
        a.last_seen = max(a.last_seen, t)
        return a

    def reset(self):
        self.attackers.clear()
        self.events.clear()
        self.pass_counter.clear()
        self.user_counter.clear()
        self.sessions.clear()
        self.scoreboard.clear()


S = State()


def config_public():
    return {
        "title": CFG["title"], "theme": CFG["theme"], "sound": CFG["sound"], "flash": CFG["flash"],
        "layout": CFG["layout"], "fgt_host": CFG["fgt_host"], "fgt_wan_ip": CFG["fgt_wan_ip"],
        "alpine_ip": CFG["alpine_ip"], "kali_ip": CFG["kali_ip"], "decoy_vip_ip": CFG["decoy_vip_ip"],
        "decoy_vip_port": CFG["decoy_vip_port"], "decoy_hostname": CFG["decoy_hostname"],
        "brute_threshold": CFG["brute_threshold"], "brute_window": CFG["brute_window"],
        "honeytokens": CFG["honeytokens"], "enforcement_mode": CFG["enforcement_mode"],
        "ban_expiry": CFG["ban_expiry"], "ntfy_public": CFG["ntfy_public"] + "/" + CFG["ntfy_topic"],
        "ntfy_enabled": CFG["ntfy_enabled"], "llm_mode": CFG["llm_mode"], "llm_model": CFG["llm_model"],
        "llm_configured": not is_placeholder(CFG["llm_base_url"]), "simulate": CFG["fgt_simulate"],
        "web_enabled": CFG["web_enabled"], "web_vip_port": CFG["web_vip_port"],
        "web_honeytokens": CFG["web_honeytokens"],
    }


def leaderboard():
    return {"passwords": S.pass_counter.most_common(10), "usernames": S.user_counter.most_common(10),
            "passwords_total": sum(S.pass_counter.values())}


def bans_view():
    out = []
    for b in S.fgt_bans:
        ip = b["ip"]
        meta = S.bans.get(ip, {})
        out.append({**b, **{k: meta.get(k) for k in ("reason", "rule", "ttq_ms", "t0", "t1", "report_id")}})
    return out


def snapshot():
    return {
        "config": config_public(), "settings": S.settings, "fgt": S.fgt,
        "attackers": [a.to_dict() for a in S.attackers.values()],
        "events": list(S.events)[-200:], "bans": bans_view(), "leaderboard": leaderboard(),
        "reports": [r for r in S.reports][-30:], "scoreboard": S.scoreboard[-20:],
        "sessions": list(S.sessions.values())[-40:],
    }


def emit(kind, data):
    S.seq += 1
    msg = f"id: {S.seq}\nevent: {kind}\ndata: {json.dumps(data, default=str)}\n\n"
    for q in list(S.clients):
        try:
            q.put_nowait(msg)
        except asyncio.QueueFull:
            pass


def toast(level, title, text=""):
    emit("toast", {"level": level, "title": title, "text": text})


# --------------------------------------------------------------------------------------
# FortiGate REST client (real or simulated)
# --------------------------------------------------------------------------------------


class FortiGate:
    def __init__(self, http):
        self.http = http
        self.base = f"https://{CFG['fgt_host']}"
        self.sim_bans = {}

    @property
    def configured(self):
        return CFG["fgt_simulate"] or not is_placeholder(CFG["fgt_token"])

    async def req(self, method, path, body=None):
        if not self.configured:
            raise RuntimeError("FGT_API_TOKEN not set (or set FGT_SIMULATE=true)")
        headers = {"Authorization": f"Bearer {CFG['fgt_token']}", "Accept": "application/json"}
        params = {"vdom": CFG["fgt_vdom"]}
        ssl = None if CFG["fgt_verify_tls"] else False
        async with self.http.request(method, self.base + path, json=body, params=params, headers=headers,
                                     ssl=ssl, timeout=ClientTimeout(total=6)) as r:
            text = await r.text()
            try:
                data = json.loads(text) if text else {}
            except json.JSONDecodeError:
                data = {"raw": text[:300]}
            if r.status >= 400:
                raise RuntimeError(f"HTTP {r.status} {path}: {str(data)[:200]}")
            return data

    async def status(self):
        if CFG["fgt_simulate"]:
            await asyncio.sleep(0.02)
            return {"hostname": "FGT-SIMULATED", "version": "v7.4.13 (simulated)", "serial": "SIMULATED"}
        d = await self.req("GET", "/api/v2/monitor/system/status")
        res = d.get("results", {}) if isinstance(d.get("results"), dict) else {}
        return {
            "hostname": res.get("hostname", d.get("hostname", "")),
            "version": d.get("version", res.get("version", "")),
            "serial": d.get("serial", res.get("serial", "")),
        }

    async def list_bans(self):
        if CFG["fgt_simulate"]:
            return [{"ip": ip, "created": c, "expires": 0, "source": "HoneyWall (simulated)"}
                    for ip, c in self.sim_bans.items()]
        d = await self.req("GET", "/api/v2/monitor/user/banned")
        out = []
        for row in d.get("results", []) or []:
            ip = row.get("ip_address") or row.get("ipaddr") or row.get("ip") or row.get("ipv4_address")
            if ip:
                out.append({"ip": ip, "created": row.get("created"), "expires": row.get("expires"),
                            "source": row.get("source", "")})
        return out

    async def ban(self, ip):
        if CFG["fgt_simulate"]:
            await asyncio.sleep(random.uniform(0.08, 0.25))
            self.sim_bans[ip] = int(time.time())
            return
        await self.req("POST", "/api/v2/monitor/user/banned/add_users",
                       {"ip_addresses": [ip], "expiry": CFG["ban_expiry"]})

    async def unban(self, ip):
        if CFG["fgt_simulate"]:
            await asyncio.sleep(random.uniform(0.05, 0.15))
            self.sim_bans.pop(ip, None)
            return
        await self.req("POST", "/api/v2/monitor/user/banned/clear_users", {"ip_addresses": [ip]})

    async def close_sessions(self, ip):
        # Endpoint behaviour verified in Stage 5; failure here never blocks the quarantine.
        if CFG["fgt_simulate"]:
            return "simulated"
        await self.req("POST", "/api/v2/monitor/firewall/session/close-multiple", {"saddr": ip})
        return "ok"

    async def is_banned(self, ip):
        return any(b["ip"] == ip for b in await self.list_bans())


FGT = None
HTTP = None


# --------------------------------------------------------------------------------------
# ntfy
# --------------------------------------------------------------------------------------


async def ntfy(title, body, priority="default", tag_list="shield", click=None):
    if not CFG["ntfy_enabled"]:
        return
    headers = {"Title": title.encode("ascii", "ignore").decode(), "Priority": priority,
               "Tags": tag_list, "Markdown": "yes", "Click": click or CFG["public_url"]}
    try:
        async with HTTP.post(f"{CFG['ntfy_url']}/{CFG['ntfy_topic']}", data=body.encode("utf-8"),
                             headers=headers, timeout=ClientTimeout(total=5)) as r:
            if r.status >= 300:
                log("ntfy", f"HTTP {r.status}", "yel")
    except Exception as e:  # ntfy is optional (lite profile)
        log("ntfy", f"unreachable: {e.__class__.__name__}", "yel")


# --------------------------------------------------------------------------------------
# Reports (template always, LLM optional)
# --------------------------------------------------------------------------------------


def report_facts(ip):
    a = S.attackers.get(ip)
    if not a:
        return {}
    timeline = [e for e in S.events if e.get("src_ip") == ip and e.get("t", 0) >= a.cycle_start][-60:]
    return {
        "attacker_ip": ip, "decoy": f"{CFG['decoy_hostname']} ({CFG['decoy_vip_ip']}:{CFG['decoy_vip_port']})",
        "first_seen": iso(a.first_seen), "last_seen": iso(a.last_seen), "ban": a.ban,
        "failed_logins": a.counts["failed"], "successful_logins": a.counts["success"],
        "accounts_used": sorted(a.success_users),
        "credentials_tried": [f"{c['username']}:{c['password']}" for c in list(a.creds)[-25:]],
        "commands": [c["input"] for c in list(a.commands)[-40:]],
        "honeytokens_touched": a.honeytokens, "high_risk_commands": a.high_risk,
        "web_requests": a.counts["web"] + a.counts["web_probe"],
        "mitre": [f"{k} {MITRE.get(k, '')}" for k, _ in a.mitre.most_common()],
        "timeline": [f"{e['ts']} {e['summary']}" for e in timeline],
    }


def template_report(f):
    ban = f.get("ban") or {}
    lines = [
        f"# Incident Report — {f['attacker_ip']}",
        "",
        f"**Decoy:** {f['decoy']}  ",
        f"**Rule:** {ban.get('reason', 'n/a')}  ",
        f"**Time-to-Quarantine:** {ban.get('ttq_ms', 'n/a')} ms  ",
        f"**Enforcement:** FortiGate REST ban ({CFG['enforcement_mode']}), confirmed by read-back",
        "",
        "## Summary",
        f"The source {f['attacker_ip']} made {f['failed_logins']} failed and {f['successful_logins']} "
        f"successful login(s) against the decoy and ran {len(f['commands'])} command(s). "
        + (f"It touched honeytoken(s): {', '.join(f['honeytokens_touched'])}. " if f["honeytokens_touched"] else "")
        + "HoneyWall quarantined the IP on the FortiGate.",
        "",
        "## MITRE ATT&CK",
        *[f"- {m}" for m in f["mitre"]],
        "",
        "## Credentials tried (last 25)",
        *([f"- `{c}`" for c in f["credentials_tried"]] or ["- none"]),
        "",
        "## Commands",
        *([f"- `{c}`" for c in f["commands"]] or ["- none"]),
        "",
        "## Indicators of Compromise",
        f"- Source IP: `{f['attacker_ip']}`",
        *[f"- Account used: `{u}`" for u in f["accounts_used"]],
        *[f"- Honeytoken accessed: `{h}`" for h in f["honeytokens_touched"]],
        "",
        "## Recommended actions",
        "- Keep the source quarantined until the endpoint is investigated.",
        "- Rotate any real credential that matches the ones tried.",
        "- Hunt for the same source and accounts across real servers and VPN logs.",
        "",
        "_Generated by HoneyWall (template report — LLM disabled or unreachable)._",
    ]
    return "\n".join(lines)


def llm_url():
    b = CFG["llm_base_url"].rstrip("/")
    if b.endswith("/chat/completions"):
        return b
    if b.endswith("/v1"):
        return b + "/chat/completions"
    return b + "/v1/chat/completions"


async def llm_complete(messages, max_tokens=900):
    if is_placeholder(CFG["llm_base_url"]):
        raise RuntimeError("LLM_BASE_URL not set")
    headers = {"Content-Type": "application/json"}
    if not is_placeholder(CFG["llm_api_key"]):
        headers["Authorization"] = f"Bearer {CFG['llm_api_key']}"
    proxy = CFG["llm_proxy"] if (CFG["llm_mode"] == "tailscale" and CFG["llm_proxy"]) else None
    body = {"model": CFG["llm_model"], "messages": messages, "temperature": 0.2,
            "max_tokens": max_tokens, "stream": False}
    t = time.time()
    ssl = None if CFG["llm_verify_tls"] else False
    async with HTTP.post(llm_url(), json=body, headers=headers, proxy=proxy, ssl=ssl,
                         timeout=ClientTimeout(total=CFG["llm_timeout"])) as r:
        text = await r.text()
        if r.status >= 400:
            raise RuntimeError(f"HTTP {r.status}: {text[:200]}")
        d = json.loads(text)
    return d["choices"][0]["message"]["content"].strip(), int((time.time() - t) * 1000)


LLM_SYSTEM = (
    "You are a senior SOC analyst. You receive JSON facts captured by an SSH honeypot that sits behind a "
    "FortiGate firewall. Write a concise incident report in Markdown with these sections: "
    "# Incident Report — <ip>, ## Summary (3 sentences), ## Attacker intent, ## Timeline (bullets), "
    "## Indicators of Compromise, ## MITRE ATT&CK, ## Recommended actions (bullets). "
    "Only use the facts given. Do not invent hosts, hashes or names. Max 350 words."
)


def save_report(rep):
    os.makedirs(os.path.join(CFG["data_dir"], "reports"), exist_ok=True)
    base = os.path.join(CFG["data_dir"], "reports", rep["id"])
    with open(base + ".md", "w", encoding="utf-8") as fh:
        fh.write(rep["markdown"])
    with open(base + ".json", "w", encoding="utf-8") as fh:
        json.dump(rep, fh, indent=2, default=str)


def report_index(rep):
    return {k: rep[k] for k in ("id", "ip", "created", "source", "rule", "ttq_ms", "latency_ms", "status")}


async def build_report(ip):
    await asyncio.sleep(CFG["report_delay"])
    f = report_facts(ip)
    if not f:
        return
    ban = f.get("ban") or {}
    rid = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + ip
    rep = {"id": rid, "ip": ip, "created": iso(time.time()), "rule": ban.get("reason"),
           "ttq_ms": ban.get("ttq_ms"), "facts": f, "source": "template", "latency_ms": None,
           "status": "ready", "markdown": template_report(f)}
    if S.settings.get("llm_enabled"):
        rep["status"] = "generating"
        S.reports.append(report_index(rep))
        emit("report", report_index(rep))
        log("llm", f"generating report for {ip} via {CFG['llm_mode']} ({CFG['llm_model']})", "mag")
        try:
            md, ms = await llm_complete([
                {"role": "system", "content": LLM_SYSTEM},
                {"role": "user", "content": json.dumps(f, default=str)},
            ])
            rep.update({"markdown": md + "\n\n_Generated by HoneyWall AI analyst ("
                        + CFG["llm_model"] + ", " + str(ms) + " ms)._",
                        "source": "llm", "latency_ms": ms, "status": "ready"})
            log("llm", f"report ready in {ms} ms", "grn")
        except Exception as e:
            rep.update({"status": "ready", "source": "template", "error": str(e)[:200]})
            log("llm", f"failed ({e}); kept template report", "yel")
            toast("warn", "LLM unreachable", "Template report saved instead")
        S.reports = [r for r in S.reports if r["id"] != rid]
    S.reports.append(report_index(rep))
    S.reports = S.reports[-100:]
    save_report(rep)
    if ip in S.bans:
        S.bans[ip]["report_id"] = rid
    a = S.attackers.get(ip)
    if a and a.ban:
        a.ban["report_id"] = rid
    emit("report", report_index(rep))
    summary = rep["markdown"].split("## Summary", 1)[-1].strip().split("\n\n")[0][:400]
    await ntfy(f"Incident report ready: {ip}", summary + f"\n\n[Open report]({CFG['public_url']}/#report-{rid})",
               "default", "memo", f"{CFG['public_url']}/#report-{rid}")


def load_reports():
    d = os.path.join(CFG["data_dir"], "reports")
    out = []
    for p in sorted(glob.glob(os.path.join(d, "*.json")))[-100:]:
        try:
            with open(p, encoding="utf-8") as fh:
                out.append(report_index(json.load(fh)))
        except Exception:
            pass
    S.reports = out


# --------------------------------------------------------------------------------------
# Quarantine / release
# --------------------------------------------------------------------------------------

LOCKS = {}


def ban_meta_save():
    try:
        os.makedirs(CFG["data_dir"], exist_ok=True)
        with open(os.path.join(CFG["data_dir"], "bans.json"), "w") as fh:
            json.dump(S.bans, fh, indent=2)
    except OSError as e:
        log("state", f"cannot save bans.json: {e}", "yel")


def ban_meta_load():
    try:
        with open(os.path.join(CFG["data_dir"], "bans.json")) as fh:
            S.bans = json.load(fh)
    except (OSError, json.JSONDecodeError):
        S.bans = {}


async def quarantine(ip, rule, reason, t0, trigger_event=None, manual=False):
    lock = LOCKS.setdefault(ip, asyncio.Lock())
    if lock.locked():
        return
    async with lock:
        a = S.attacker(ip, t0)
        if a.status in ("triggered", "quarantined"):
            return
        if never_ban(ip):
            log("guard", f"{ip} is in NEVER_BAN - not quarantining ({reason})", "yel")
            toast("warn", f"{ip} matched {rule}", "Protected by NEVER_BAN, no action taken")
            return
        a.status = "triggered"
        emit("trigger", {"ip": ip, "rule": rule, "reason": reason, "t0": t0, "t0_iso": iso(t0),
                         "event": trigger_event, "attacker": a.to_dict()})
        log("TRIGGER", f"{C['red']}{ip}{C['r']} -> {reason}", "red")
        try:
            await FGT.ban(ip)
            confirmed = False
            for _ in range(40):
                if await FGT.is_banned(ip):
                    confirmed = True
                    break
                await asyncio.sleep(0.1)
            t1 = time.time()
        except Exception as e:
            a.status = "watching"
            log("FORTIGATE", f"ban FAILED for {ip}: {e}", "red")
            toast("crit", "FortiGate ban failed", str(e)[:160])
            emit("attacker", a.to_dict())
            return
        ttq = int((t1 - t0) * 1000)
        a.status = "quarantined"
        a.ban = {"rule": rule, "reason": reason, "t0": iso(t0), "t1": iso(t1), "ttq_ms": ttq,
                 "confirmed": confirmed, "manual": manual}
        a.history.append(a.ban)
        S.bans[ip] = dict(a.ban)
        ban_meta_save()
        S.scoreboard.append({"ip": ip, "rule": rule, "reason": reason, "ttq_ms": ttq, "at": iso(t1)})
        try:
            S.fgt_bans = await FGT.list_bans()
        except Exception:
            pass
        emit("quarantine", {"ip": ip, "rule": rule, "reason": reason, "ttq_ms": ttq, "confirmed": confirmed,
                            "t0": iso(t0), "t1": iso(t1), "attacker": a.to_dict(), "bans": bans_view(),
                            "scoreboard": S.scoreboard[-20:]})
        log("QUARANTINE", f"{C['red']}{ip}{C['r']} banned on FortiGate in {C['yel']}{ttq} ms{C['r']}"
            f" ({'confirmed by read-back' if confirmed else 'NOT confirmed'})", "red")
        asyncio.create_task(ntfy(
            f"QUARANTINED {ip} in {ttq / 1000:.2f}s",
            f"**{ip}** was banned on the FortiGate in **{ttq} ms**.\n\n"
            f"- Rule: {reason}\n- Decoy: {CFG['decoy_hostname']}\n"
            f"- Failed logins: {a.counts['failed']} · Commands: {a.counts['command']}\n\n"
            f"[Open HoneyWall]({CFG['public_url']})",
            "urgent", "rotating_light,no_entry"))
        if CFG["close_sessions"]:
            try:
                r = await FGT.close_sessions(ip)
                log("FORTIGATE", f"closed existing sessions from {ip} ({r})", "yel")
            except Exception as e:
                log("FORTIGATE", f"session close skipped: {str(e)[:120]}", "dim")
        asyncio.create_task(build_report(ip))


async def release(ip):
    try:
        await FGT.unban(ip)
        for _ in range(30):
            if not await FGT.is_banned(ip):
                break
            await asyncio.sleep(0.1)
        S.fgt_bans = await FGT.list_bans()
    except Exception as e:
        log("FORTIGATE", f"unban FAILED for {ip}: {e}", "red")
        raise
    a = S.attackers.get(ip)
    if a:
        a.status = "released"
        a.fails.clear()
        a.honeytokens = []
        a.high_risk = 0
        a.counts = Counter()
        a.creds.clear()
        a.commands.clear()
        a.mitre.clear()
        a.success_users.clear()
        a.cycle_start = time.time()
    S.bans.pop(ip, None)
    ban_meta_save()
    emit("release", {"ip": ip, "bans": bans_view(), "attacker": a.to_dict() if a else None})
    log("RELEASE", f"{ip} unbanned on FortiGate", "grn")
    asyncio.create_task(ntfy(f"Released {ip}", f"{ip} was removed from the FortiGate ban list.",
                             "low", "white_check_mark"))


# --------------------------------------------------------------------------------------
# Cowrie event handling
# --------------------------------------------------------------------------------------

RECON_CLIENT = re.compile(r"nmap|libssh|masscan|zgrab|paramiko|scan", re.I)


def new_event(kind, ip, t, sess, summary, severity="info", mitre=None, **detail):
    new_event.n += 1
    return {"id": new_event.n, "kind": kind, "src_ip": ip, "t": t, "ts": iso(t), "session": sess,
            "summary": summary, "severity": severity, "mitre": tags(*(mitre or [])), "detail": detail}


new_event.n = 0


WEB_404 = {}


def handle_web(raw):
    """Events from the web decoy (decoy-web/decoy_web.py)."""
    eid = raw.get("eventid", "")
    ip = raw.get("src_ip")
    if not ip:
        return
    t = parse_ts(raw.get("timestamp"))
    sess = raw.get("session", "web")
    a = S.attacker(ip, t)
    post_ban = a.status == "quarantined"
    trig = None
    evt = None

    if eid == "web.request":
        path, status, scanner = str(raw.get("path", "")), raw.get("status"), raw.get("scanner", "")
        if path.startswith("/login") and raw.get("method") == "POST":
            return  # the login itself arrives as web.login.failed
        ids = []
        sev = "info"
        if scanner and scanner not in ("curl", "wget", "python-requests"):
            ids.append("T1595.002")
            sev = "warn"
        if status == 404:
            n = WEB_404.get(ip, [])
            n = [x for x in n if t - x < 10] + [t]
            WEB_404[ip] = n
            if len(n) >= 5:
                ids.append("T1595.003")
                sev = "warn"
                if len(n) % 25 != 5:  # wordlist burst: show the first hit and every 25th
                    a.counts["web_probe"] += 1
                    return
        a.counts["web"] += 1
        if ids:
            a.counts["recon"] += 1
        ua = raw.get("user_agent", "")
        evt = new_event("web_request", ip, t, sess, f"HTTP {raw.get('method')} {path} → {status}"
                        + (f"  ({scanner})" if scanner else ""), sev, ids, method=raw.get("method"),
                        path=path, status=status, user_agent=ua, scanner=scanner)

    elif eid == "web.login.failed":
        u, p = str(raw.get("username", "")), str(raw.get("password", ""))
        a.counts["failed"] += 1
        S.user_counter[u] += 1
        S.pass_counter[p] += 1
        a.creds.append({"username": u, "password": p, "ok": False, "ts": iso(t), "proto": "web"})
        a.fails.append(t)
        while a.fails and t - a.fails[0] > CFG["brute_window"]:
            a.fails.popleft()
        evt = new_event("web_login_failed", ip, t, sess, f"Web login failed  {u} / {p}", "warn",
                        ["T1110.001"], username=u, password=p, window_count=len(a.fails), proto="web")
        if not post_ban and len(a.fails) >= CFG["brute_threshold"]:
            span = t - a.fails[0]
            trig = ("brute_force", f"Brute force: {len(a.fails)} failed logins in {span:.1f}s "
                    f"(threshold {CFG['brute_threshold']}/{CFG['brute_window']}s)")

    elif eid == "web.honeytoken":
        path = str(raw.get("path", ""))
        tok = "web:" + path
        if tok not in a.honeytokens:
            a.honeytokens.append(tok)
        a.commands.append({"input": f"GET {path}", "session": sess, "user": "web", "ts": iso(t),
                           "honeytoken": tok, "risk": []})
        evt = new_event("web_honeytoken", ip, t, sess, f"Honeytoken downloaded over HTTP: {path}", "crit",
                        ["T1190", "T1552.001"], path=path, honeytoken=tok)
        if not post_ban:
            trig = ("honeytoken", f"Honeytoken touched: {path} (web decoy)")
    else:
        return

    if post_ban:
        evt["post_ban"] = True
        evt["summary"] = "[after ban] " + evt["summary"]
    for m in evt["mitre"]:
        a.mitre[m["id"]] += 1
    S.events.append(evt)
    payload = {"event": evt, "attacker": a.to_dict()}
    if evt["kind"] == "web_login_failed":
        payload["leaderboard"] = leaderboard()
    emit("event", payload)
    log(evt["kind"][:10], f"{ip} {evt['summary']}", {"crit": "red", "warn": "yel"}.get(evt["severity"], "cyn"))
    if trig:
        asyncio.create_task(quarantine(ip, trig[0], trig[1], t, evt))


def handle(raw):
    eid = raw.get("eventid", "")
    ip = raw.get("src_ip")
    if eid.startswith("web."):
        return handle_web(raw)
    if not ip or not eid.startswith("cowrie."):
        return
    t = parse_ts(raw.get("timestamp"))
    sess = raw.get("session", "")
    a = S.attacker(ip, t)
    si = S.sessions.setdefault(sess, {"session": sess, "ip": ip, "start": iso(t), "user": None,
                                      "attempts": 0, "logins": 0, "commands": 0, "closed": False,
                                      "client": "", "recon": False, "has_tty": False})
    post_ban = a.status == "quarantined"
    evt = None
    trig = None

    if eid == "cowrie.session.connect":
        a.sessions.add(sess)
        a.counts["connect"] += 1
        evt = new_event("connect", ip, t, sess,
                        f"{ip}:{raw.get('src_port', '?')} → {CFG['decoy_hostname']} ({CFG['decoy_vip_ip']}:{CFG['decoy_vip_port']})")

    elif eid == "cowrie.client.version":
        ver = str(raw.get("version", ""))
        si["client"] = ver
        if RECON_CLIENT.search(ver) and not si["recon"]:
            si["recon"] = True
            a.counts["recon"] += 1
            evt = new_event("recon", ip, t, sess, f"Scanner fingerprint: {ver}", "warn", ["T1046"], version=ver)
        else:
            evt = new_event("client", ip, t, sess, f"SSH client: {ver}", version=ver)

    elif eid == "cowrie.login.failed":
        u, p = str(raw.get("username", "")), str(raw.get("password", ""))
        si["attempts"] += 1
        a.counts["failed"] += 1
        S.user_counter[u] += 1
        S.pass_counter[p] += 1
        a.creds.append({"username": u, "password": p, "ok": False, "ts": iso(t)})
        a.fails.append(t)
        while a.fails and t - a.fails[0] > CFG["brute_window"]:
            a.fails.popleft()
        evt = new_event("login_failed", ip, t, sess, f"Login failed  {u} / {p}", "warn", ["T1110.001"],
                        username=u, password=p, window_count=len(a.fails))
        if not post_ban and len(a.fails) >= CFG["brute_threshold"]:
            span = t - a.fails[0]
            trig = ("brute_force", f"Brute force: {len(a.fails)} failed logins in {span:.1f}s "
                    f"(threshold {CFG['brute_threshold']}/{CFG['brute_window']}s)")

    elif eid == "cowrie.login.success":
        u, p = str(raw.get("username", "")), str(raw.get("password", ""))
        si["attempts"] += 1
        si["logins"] += 1
        si["user"] = u
        a.counts["success"] += 1
        a.success_users.add(u)
        S.user_counter[u] += 1
        S.pass_counter[p] += 1
        a.creds.append({"username": u, "password": p, "ok": True, "ts": iso(t)})
        leaked = " (LEAKED CREDENTIAL)" if u == CFG["leaked_user"] else ""
        evt = new_event("login_success", ip, t, sess, f"Login SUCCESS  {u} / {p}{leaked}", "crit",
                        ["T1078", "T1021.004"], username=u, password=p)

    elif eid == "cowrie.command.input":
        line = str(raw.get("input", ""))
        si["commands"] += 1
        a.counts["command"] += 1
        hit = honeytoken_hit(line)
        risk = high_risk(line)
        ids = classify_command(line)
        if hit:
            ids.append("T1552.001")
            if hit not in a.honeytokens:
                a.honeytokens.append(hit)
        if risk:
            a.high_risk += len(risk)
        a.commands.append({"input": line, "session": sess, "user": si["user"], "ts": iso(t),
                           "honeytoken": hit, "risk": risk})
        sev = "crit" if hit else ("warn" if risk else "info")
        evt = new_event("command", ip, t, sess, f"$ {line}", sev, ids, input=line, honeytoken=hit,
                        risk=risk, user=si["user"])
        if hit and not post_ban:
            trig = ("honeytoken", f"Honeytoken touched: {hit}")

    elif eid == "cowrie.session.file_download":
        url = str(raw.get("url", ""))
        a.high_risk += 1
        evt = new_event("download", ip, t, sess, f"Download attempt: {url}", "warn", ["T1105"],
                        url=url, shasum=raw.get("shasum"))

    elif eid == "cowrie.session.closed":
        si["closed"] = True
        dur = raw.get("duration")
        if si["attempts"] == 0 and not si["recon"]:
            si["recon"] = True
            a.counts["recon"] += 1
            evt = new_event("recon", ip, t, sess, f"Probe: connected and left without logging in ({dur}s)",
                            "warn", ["T1046"])
        else:
            evt = new_event("closed", ip, t, sess, f"Session closed after {dur}s")

    elif eid == "cowrie.log.closed":
        path = raw.get("ttylog")
        if path:
            S.session_tty[sess] = os.path.join(CFG["tty_dir"], os.path.basename(str(path)))
            si["has_tty"] = True
        return
    else:
        return

    if post_ban and evt:
        evt["post_ban"] = True
        evt["summary"] = "[after ban] " + evt["summary"]
    for m in evt["mitre"]:
        a.mitre[m["id"]] += 1
    S.events.append(evt)
    payload = {"event": evt, "attacker": a.to_dict(), "session": si}
    if evt["kind"] in ("login_failed", "login_success"):
        payload["leaderboard"] = leaderboard()
    emit("event", payload)

    color = {"crit": "red", "warn": "yel"}.get(evt["severity"], "cyn")
    log(evt["kind"][:10], f"{ip} {evt['summary']}", color)
    if trig:
        asyncio.create_task(quarantine(ip, trig[0], trig[1], t, evt))


async def tail_log(path):
    fh, inode, buf, first = None, None, b"", True
    name = os.path.basename(path)
    log("tail", f"watching {path}")
    while True:
        if fh is None:
            try:
                fh = open(path, "rb")
                inode = os.fstat(fh.fileno()).st_ino
                if first:
                    fh.seek(0, os.SEEK_END)  # existing log at startup: live only, start clean for the camera
                    log("tail", f"{name}: attached at end (live mode)", "grn")
                else:
                    log("tail", f"{name}: new or rotated file - reading from the start", "yel")
                first = False
            except FileNotFoundError:
                first = False  # the file will be brand new when it appears: read all of it
                await asyncio.sleep(0.5)
                continue
        chunk = fh.read(65536)
        if chunk:
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    handle(json.loads(line))
                except json.JSONDecodeError:
                    pass
                except Exception as e:
                    log("error", f"event handling failed: {e!r}", "red")
            continue
        await asyncio.sleep(0.05)
        try:
            st = os.stat(path)
            if st.st_ino != inode or st.st_size < fh.tell():
                fh.close()
                fh, buf = None, b""
        except FileNotFoundError:
            pass


# --------------------------------------------------------------------------------------
# TTY replay
# --------------------------------------------------------------------------------------

TTYSTRUCT = "<iLiiLL"
TTYSIZE = struct.calcsize(TTYSTRUCT)


def tty_path(sess):
    p = S.session_tty.get(sess)
    if p and os.path.exists(p):
        return p
    live = glob.glob(os.path.join(CFG["tty_dir"], f"*-{sess}-*.log"))
    return live[0] if live else None


def read_tty(path, limit=3_000_000):
    with open(path, "rb") as fh:
        data = fh.read(limit)
    frames, pos, start = [], 0, None
    while pos + TTYSIZE <= len(data):
        op, _tty, length, direction, sec, usec = struct.unpack_from(TTYSTRUCT, data, pos)
        pos += TTYSIZE
        t = sec + usec / 1e6
        start = t if start is None else start
        if op == 3:
            chunk = data[pos:pos + length]
            pos += length
            if direction == 2:
                frames.append({"t": round(t - start, 3), "d": chunk.decode("utf-8", "replace")})
        elif op == 2:
            break
    return frames


# --------------------------------------------------------------------------------------
# FortiGate pollers
# --------------------------------------------------------------------------------------


async def fgt_status_loop():
    while True:
        t = time.time()
        try:
            st = await FGT.status()
            S.fgt.update({"online": True, **st, "latency_ms": int((time.time() - t) * 1000), "error": "",
                          "checked": iso(time.time())})
        except Exception as e:
            if S.fgt.get("online") or S.fgt.get("error") != str(e)[:160]:
                log("FORTIGATE", f"status check failed: {str(e)[:160]}", "yel")
            S.fgt.update({"online": False, "error": str(e)[:160], "checked": iso(time.time())})
        emit("fgt", S.fgt)
        await asyncio.sleep(10)


async def bans_loop():
    last = None
    while True:
        try:
            bans = await FGT.list_bans()
            S.fgt_bans = bans
            ips = {b["ip"] for b in bans}
            for ip, a in S.attackers.items():
                if a.status == "quarantined" and ip not in ips and not LOCKS.get(ip, asyncio.Lock()).locked():
                    a.status = "released"
                    S.bans.pop(ip, None)
                    emit("release", {"ip": ip, "bans": bans_view(), "attacker": a.to_dict(), "external": True})
                    log("RELEASE", f"{ip} was removed on the FortiGate directly", "grn")
            for ip in ips:
                if ip not in S.bans:
                    S.bans[ip] = {"rule": "external", "reason": "Banned outside HoneyWall", "ttq_ms": None}
            view = json.dumps(bans_view(), sort_keys=True, default=str)
            if view != last:
                last = view
                emit("bans", bans_view())
        except Exception:
            pass
        await asyncio.sleep(CFG["ban_poll_sec"])


# --------------------------------------------------------------------------------------
# Rehearsal simulator (FGT_SIMULATE=true only) - same pipeline as real Cowrie events
# --------------------------------------------------------------------------------------


async def simulate(act, ip):
    sess = "%012x" % random.getrandbits(48)

    def banned():
        a = S.attackers.get(ip)
        return bool(a and a.status in ("triggered", "quarantined"))

    def ev(eid, **kw):
        handle({"eventid": eid, "src_ip": ip, "src_port": random.randint(40000, 60000),
                "session": sess, "timestamp": iso(time.time()), **kw})

    act = str(act).lower()
    if act == "1":
        ev("cowrie.session.connect")
        await asyncio.sleep(0.3)
        ev("cowrie.client.version", version="SSH-2.0-Nmap-SSH2-Hostkey")
        await asyncio.sleep(0.4)
        ev("cowrie.session.closed", duration="0.7")
    elif act == "2":
        pwds = ["123456", "password", "admin", "root", "toor", "qwerty", "letmein", "P@ssw0rd"]
        for i, p in enumerate(pwds):
            if banned():
                break
            sess = "%012x" % random.getrandbits(48)
            ev("cowrie.session.connect")
            await asyncio.sleep(0.15)
            ev("cowrie.login.failed", username="root" if i % 2 == 0 else "admin", password=p)
            await asyncio.sleep(random.uniform(0.4, 0.9))
    elif act == "3b":
        for path, st in [("/", 302), ("/login", 200), ("/robots.txt", 200), ("/backup/", 200)]:
            handle({"eventid": "web.request", "src_ip": ip, "session": "web-sim", "timestamp": iso(time.time()),
                    "method": "GET", "path": path, "status": st, "user_agent": "curl/8.11.1", "scanner": "curl"})
            await asyncio.sleep(0.8)
        for u, p in [("admin", "admin"), ("svc_backup", "backup123")]:
            handle({"eventid": "web.login.failed", "src_ip": ip, "session": "web-sim",
                    "timestamp": iso(time.time()), "username": u, "password": p})
            await asyncio.sleep(0.9)
        if not banned():
            handle({"eventid": "web.honeytoken", "src_ip": ip, "session": "web-sim",
                    "timestamp": iso(time.time()), "path": "/backup/.env.bak"})
    elif act == "3":
        ev("cowrie.session.connect")
        await asyncio.sleep(0.4)
        ev("cowrie.login.success", username=CFG["leaked_user"], password="Summer2026!")
        for cmd in ["whoami", "id", "uname -a", "ls -la", "cat .bash_history", "cat /root/.aws/credentials"]:
            if banned():
                break
            await asyncio.sleep(random.uniform(1.2, 2.2))
            ev("cowrie.command.input", input=cmd)


# --------------------------------------------------------------------------------------
# HTTP API
# --------------------------------------------------------------------------------------


@web.middleware
async def auth_mw(request, handler):
    tok = CFG["token"]
    if tok and request.path.startswith("/api/") and request.path != "/api/health":
        given = request.headers.get("X-HoneyWall-Token") or request.query.get("token")
        if given != tok:
            return web.json_response({"error": "unauthorized"}, status=401)
    return await handler(request)


async def h_health(_r):
    return web.json_response({"ok": True, "fgt_online": S.fgt["online"], "simulate": CFG["fgt_simulate"],
                              "clients": len(S.clients), "events": len(S.events)})


async def h_state(_r):
    return web.json_response(snapshot(), dumps=lambda o: json.dumps(o, default=str))


async def h_stream(request):
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                                       "X-Accel-Buffering": "no", "Connection": "keep-alive"})
    await resp.prepare(request)
    q = asyncio.Queue(maxsize=2000)
    S.clients.add(q)
    try:
        await resp.write(f"event: snapshot\ndata: {json.dumps(snapshot(), default=str)}\n\n".encode())
        while True:
            try:
                msg = await asyncio.wait_for(q.get(), timeout=15)
                await resp.write(msg.encode())
            except asyncio.TimeoutError:
                await resp.write(b": keepalive\n\n")
    except (ConnectionResetError, asyncio.CancelledError, RuntimeError):
        pass
    finally:
        S.clients.discard(q)
    return resp


async def body_json(request):
    try:
        return await request.json()
    except Exception:
        return {}


async def h_unban(request):
    ip = (await body_json(request)).get("ip", "")
    try:
        ipaddress.ip_address(ip)
        await release(ip)
        return web.json_response({"ok": True, "ip": ip})
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)[:200]}, status=400)


async def h_ban(request):
    ip = (await body_json(request)).get("ip", "")
    try:
        ipaddress.ip_address(ip)
    except ValueError:
        return web.json_response({"ok": False, "error": "invalid ip"}, status=400)
    asyncio.create_task(quarantine(ip, "manual", "Manual ban from HoneyWall", time.time(), manual=True))
    return web.json_response({"ok": True, "ip": ip})


async def h_settings(request):
    b = await body_json(request)
    if "llm_enabled" in b:
        S.settings["llm_enabled"] = bool(b["llm_enabled"])
        try:
            with open(os.path.join(CFG["data_dir"], "settings.json"), "w") as fh:
                json.dump(S.settings, fh)
        except OSError:
            pass
        log("settings", f"LLM reports {'ON' if S.settings['llm_enabled'] else 'OFF'}", "mag")
    emit("settings", S.settings)
    return web.json_response(S.settings)


async def h_reset(_r):
    S.reset()
    emit("reset", snapshot())
    log("reset", "demo state cleared (bans and reports kept)", "grn")
    return web.json_response({"ok": True})


async def h_reports(_r):
    return web.json_response(S.reports[-100:])


def safe_report_path(rid, ext):
    if not re.fullmatch(r"[0-9A-Za-z._:-]+", rid):
        return None
    p = os.path.join(CFG["data_dir"], "reports", rid + ext)
    return p if os.path.exists(p) else None


async def h_report(request):
    rid = request.match_info["rid"]
    if rid.endswith(".md"):
        p = safe_report_path(rid[:-3], ".md")
        if not p:
            raise web.HTTPNotFound()
        return web.FileResponse(p, headers={"Content-Type": "text/markdown; charset=utf-8",
                                            "Content-Disposition": f'attachment; filename="{rid}"'})
    p = safe_report_path(rid, ".json")
    if not p:
        raise web.HTTPNotFound()
    with open(p, encoding="utf-8") as fh:
        return web.json_response(json.load(fh))


async def h_sessions(_r):
    out = []
    for s in list(S.sessions.values())[-60:]:
        out.append({**s, "has_tty": bool(tty_path(s["session"]))})
    return web.json_response(out)


async def h_replay(request):
    sess = request.match_info["sess"]
    if not re.fullmatch(r"[0-9a-fA-F]{6,32}", sess):
        raise web.HTTPBadRequest()
    p = tty_path(sess)
    if p:
        try:
            return web.json_response({"session": sess, "source": "tty", "frames": read_tty(p)})
        except OSError:
            pass
    si = S.sessions.get(sess, {})
    frames, t0 = [], None
    for a in S.attackers.values():
        for c in a.commands:
            if c["session"] == sess:
                t = parse_ts(c["ts"])
                t0 = t if t0 is None else t0
                frames.append({"t": round(t - t0, 3),
                               "d": f"{c.get('user') or 'user'}@{CFG['decoy_hostname']}:~$ {c['input']}\r\n"})
    return web.json_response({"session": sess, "source": "commands", "frames": frames, "info": si})


async def h_test_alert(_r):
    await ntfy("HoneyWall test alert", "If you can read this, ntfy alerts work.", "default", "test_tube")
    toast("info", "Test alert sent", f"Check {CFG['ntfy_public']}/{CFG['ntfy_topic']}")
    return web.json_response({"ok": True})


async def h_test_llm(_r):
    try:
        text, ms = await llm_complete([{"role": "user", "content": "Reply with exactly: HoneyWall LLM OK"}], 20)
        return web.json_response({"ok": True, "latency_ms": ms, "reply": text[:120], "mode": CFG["llm_mode"]})
    except Exception as e:
        return web.json_response({"ok": False, "error": str(e)[:300], "mode": CFG["llm_mode"]}, status=502)


async def h_simulate(request):
    if not CFG["fgt_simulate"]:
        return web.json_response({"ok": False, "error": "only available with FGT_SIMULATE=true"}, status=403)
    b = await body_json(request)
    act = str(b.get("act", "2")).lower()
    if act not in ("1", "2", "3", "3b"):
        return web.json_response({"ok": False, "error": "act must be 1, 2, 3 or 3b"}, status=400)
    ip = b.get("ip") or CFG["kali_ip"]
    asyncio.create_task(simulate(act, ip))
    return web.json_response({"ok": True, "act": act, "ip": ip})


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------


async def main():
    global FGT, HTTP
    os.makedirs(os.path.join(CFG["data_dir"], "reports"), exist_ok=True)
    try:
        with open(os.path.join(CFG["data_dir"], "settings.json")) as fh:
            S.settings.update(json.load(fh))
    except (OSError, json.JSONDecodeError):
        pass
    ban_meta_load()
    load_reports()

    HTTP = ClientSession(connector=TCPConnector(limit=30))
    FGT = FortiGate(HTTP)

    print(f"""{C['grn']}
   _   _                       __        __    _ _
  | | | | ___  _ __   ___ _   _\\ \\      / /_ _| | |
  | |_| |/ _ \\| '_ \\ / _ \\ | | |\\ \\ /\\ / / _` | | |
  |  _  | (_) | | | |  __/ |_| | \\ V  V / (_| | | |
  |_| |_|\\___/|_| |_|\\___|\\__, |  \\_/\\_/ \\__,_|_|_|
                          |___/   engine{C['r']}""", flush=True)
    log("config", f"decoy {CFG['decoy_hostname']} @ {CFG['decoy_vip_ip']}:{CFG['decoy_vip_port']} | "
        f"brute {CFG['brute_threshold']}/{CFG['brute_window']}s | honeytokens {len(CFG['honeytokens'])}")
    log("config", f"FortiGate {CFG['fgt_host']} mode={CFG['enforcement_mode']} expiry={CFG['ban_expiry']} "
        f"{'SIMULATED' if CFG['fgt_simulate'] else ('token set' if not is_placeholder(CFG['fgt_token']) else 'NO TOKEN')}",
        "yel" if CFG["fgt_simulate"] or is_placeholder(CFG["fgt_token"]) else "grn")
    log("config", f"ntfy {'on' if CFG['ntfy_enabled'] else 'off'} | LLM {'on' if S.settings['llm_enabled'] else 'off'}"
        f" ({CFG['llm_mode']}, {CFG['llm_model']})", "mag")

    app = web.Application(middlewares=[auth_mw])
    app.add_routes([
        web.get("/api/health", h_health),
        web.get("/api/state", h_state),
        web.get("/api/stream", h_stream),
        web.post("/api/unban", h_unban),
        web.post("/api/ban", h_ban),
        web.post("/api/settings", h_settings),
        web.post("/api/reset", h_reset),
        web.get("/api/reports", h_reports),
        web.get("/api/reports/{rid}", h_report),
        web.get("/api/sessions", h_sessions),
        web.get("/api/replay/{sess}", h_replay),
        web.post("/api/test/alert", h_test_alert),
        web.post("/api/test/llm", h_test_llm),
        web.post("/api/test/simulate", h_simulate),
    ])
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    host, port = CFG["listen"].rsplit(":", 1)
    await web.TCPSite(runner, host, int(port)).start()
    log("api", f"listening on {CFG['listen']}", "grn")

    tails = [tail_log(CFG["cowrie_log"])]
    if CFG["web_enabled"]:
        tails.append(tail_log(CFG["web_log"]))
    await asyncio.gather(*tails, fgt_status_loop(), bans_loop())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
