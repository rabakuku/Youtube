#!/usr/bin/env python3
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/decoy-web/decoy_web.py
"""
HoneyWall web decoy: a believable "Corp Backup Console" on the Users-side VIP 192.168.40.1:80.

Every request is written as one JSON line to WEB_DECOY_LOG, which the HoneyWall engine tails
(the same way it tails Cowrie). Nothing here can log anyone in. The bait:

  /robots.txt          -> points at /backup/ and /admin/
  /backup/             -> directory listing with db_dump.sql and .env.bak
  /login (POST)        -> always "Invalid username or password" (counts toward the brute-force rule)
  WEB_HONEYTOKENS      -> serving any of these paths emits web.honeytoken (instant quarantine)
"""

import asyncio
import datetime as dt
import html
import json
import os
import random
import uuid

from aiohttp import web

LOG = os.environ.get("WEB_DECOY_LOG", "/logs/web.json")
LISTEN_PORT = int(os.environ.get("WEB_DECOY_PORT", "8088"))
TITLE = os.environ.get("WEB_DECOY_TITLE", "Corp Backup Console")
HOSTNAME = os.environ.get("WEB_DECOY_HOSTNAME", "backup.corp.local")
TOKENS = [p.strip() for p in os.environ.get("WEB_HONEYTOKENS", "/.env,/backup/.env.bak,/backup/db_dump.sql").split(",") if p.strip()]
DB_DUMP = os.environ.get("WEB_DECOY_DB_DUMP", "/honeyfs/opt/backup/db_dump.sql")
MAX_LOG = 50 * 1024 * 1024

FAKE_ENV = """APP_ENV=production
APP_URL=https://backup.corp.local
DB_HOST=10.20.0.15
DB_DATABASE=corp_crm
DB_USERNAME=backup_ro
DB_PASSWORD=Bkp!Corp2026
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_DEFAULT_REGION=us-east-1
S3_BUCKET=corp-prod-backups
VEEAM_API_USER=svc_backup
"""

SCANNERS = ("nikto", "sqlmap", "gobuster", "dirb", "dirbuster", "feroxbuster", "ffuf", "wfuzz", "nmap",
            "masscan", "zgrab", "nuclei", "hydra", "wpscan", "whatweb", "python-requests", "curl", "wget")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def write_event(ev):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > MAX_LOG:
            os.replace(LOG, LOG + ".1")
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(ev) + "\n")
    except OSError as e:
        print(f"[decoy-web] cannot write log: {e}", flush=True)


def src_ip(request):
    peer = request.transport.get_extra_info("peername") if request.transport else None
    return peer[0] if peer else "0.0.0.0"


def session_for(request):
    sid = request.cookies.get("BCSESSID")
    return sid or uuid.uuid4().hex[:12]


def scanner_name(ua):
    low = (ua or "").lower()
    for s in SCANNERS:
        if s in low:
            return s
    return ""


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - Sign in</title>
<style>
 body{{margin:0;font-family:"Segoe UI",Arial,sans-serif;background:#eef1f5;color:#1d2733}}
 .bar{{background:#123a63;color:#fff;padding:14px 28px;font-size:15px;letter-spacing:.02em}}
 .box{{max-width:380px;margin:9vh auto;background:#fff;border:1px solid #d5dce5;border-radius:6px;padding:30px 34px;box-shadow:0 2px 6px rgba(0,0,0,.06)}}
 h1{{font-size:20px;margin:0 0 4px}} p.sub{{margin:0 0 22px;color:#5b6b7c;font-size:13px}}
 label{{display:block;font-size:13px;margin:12px 0 4px}}
 input{{width:100%;box-sizing:border-box;padding:9px 10px;border:1px solid #b9c4d0;border-radius:4px;font-size:14px}}
 button{{margin-top:20px;width:100%;padding:10px;background:#1b5fa8;color:#fff;border:0;border-radius:4px;font-size:14px}}
 .err{{background:#fdecec;color:#9b1c1c;border:1px solid #f3b9b9;padding:8px 10px;border-radius:4px;font-size:13px;margin-bottom:6px}}
 footer{{text-align:center;color:#8a97a6;font-size:12px}}
</style></head><body>
<div class="bar">{title} &nbsp;|&nbsp; {host}</div>
<div class="box">
 <h1>Sign in</h1><p class="sub">Use your corporate directory account.</p>
 {err}
 <form method="post" action="/login">
  <label for="u">Username</label><input id="u" name="username" autocomplete="username">
  <label for="p">Password</label><input id="p" name="password" type="password" autocomplete="current-password">
  <button type="submit">Sign in</button>
 </form>
</div>
<footer>Backup Console 4.2.1 &middot; &copy; 2026 Corp IT &middot; Authorized use only</footer>
</body></html>"""

LISTING = """<html><head><title>Index of /backup/</title></head><body>
<h1>Index of /backup/</h1><hr><pre><a href="../">../</a>
<a href=".env.bak">.env.bak</a>                                           12-Oct-2026 02:14     412
<a href="db_dump.sql">db_dump.sql</a>                                        12-Oct-2026 02:14     624
<a href="nightly.log">nightly.log</a>                                        04-Nov-2026 02:00    1873
</pre><hr></body></html>"""


def page(err=""):
    e = f'<div class="err">{html.escape(err)}</div>' if err else ""
    return PAGE.format(title=html.escape(TITLE), host=html.escape(HOSTNAME), err=e)


@web.middleware
async def log_mw(request, handler):
    if request.path == "/__honeywall_health":
        return await handler(request)
    sid = session_for(request)
    request["sid"] = sid
    ua = request.headers.get("User-Agent", "")

    def log(status):
        write_event({"eventid": "web.request", "timestamp": now_iso(), "src_ip": src_ip(request),
                     "session": "web-" + sid, "method": request.method, "path": request.path_qs[:300],
                     "status": status, "user_agent": ua[:200], "scanner": scanner_name(ua)})

    try:
        resp = await handler(request)
    except web.HTTPException as ex:
        log(ex.status)
        ex.headers["Server"] = "nginx/1.22.1"
        raise
    log(resp.status)
    resp.headers["Server"] = "nginx/1.22.1"
    if "BCSESSID" not in request.cookies:
        resp.set_cookie("BCSESSID", sid, httponly=True, samesite="Lax")
    return resp


def honeytoken(request, path):
    write_event({"eventid": "web.honeytoken", "timestamp": now_iso(), "src_ip": src_ip(request),
                 "session": "web-" + request["sid"], "path": path,
                 "user_agent": request.headers.get("User-Agent", "")[:200]})


async def h_index(_r):
    raise web.HTTPFound("/login")


async def h_login_get(_r):
    return web.Response(text=page(), content_type="text/html")


async def h_login_post(request):
    form = await request.post()
    u, p = str(form.get("username", ""))[:80], str(form.get("password", ""))[:80]
    write_event({"eventid": "web.login.failed", "timestamp": now_iso(), "src_ip": src_ip(request),
                 "session": "web-" + request["sid"], "username": u, "password": p,
                 "user_agent": request.headers.get("User-Agent", "")[:200]})
    await asyncio.sleep(random.uniform(0.25, 0.6))   # feels like a real directory lookup
    return web.Response(text=page("Invalid username or password."), content_type="text/html", status=200)


async def h_robots(_r):
    return web.Response(text="User-agent: *\nDisallow: /backup/\nDisallow: /admin/\n", content_type="text/plain")


async def h_admin(_r):
    raise web.HTTPFound("/login?next=/admin/")


async def h_backup_index(_r):
    return web.Response(text=LISTING, content_type="text/html")


async def h_file(request):
    path = request.path
    if path in TOKENS:
        honeytoken(request, path)
    if path in ("/.env", "/backup/.env.bak"):
        return web.Response(text=FAKE_ENV, content_type="text/plain")
    if path == "/backup/db_dump.sql":
        try:
            with open(DB_DUMP, "rb") as fh:
                return web.Response(body=fh.read(), content_type="application/sql")
        except OSError:
            return web.Response(text="-- dump unavailable\n", content_type="application/sql")
    if path == "/backup/nightly.log":
        return web.Response(text="2026-11-04 02:00:01 nightly: mysqldump corp_crm OK (svc_backup)\n"
                                 "2026-11-04 02:00:44 nightly: s3 sync s3://corp-prod-backups OK\n",
                            content_type="text/plain")
    raise web.HTTPNotFound(text="<html><body><h1>404 Not Found</h1><hr>nginx</body></html>", content_type="text/html")


async def h_health(_r):
    return web.Response(text="ok")


def main():
    try:  # create the log up front so the engine attaches before the first visitor
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        open(LOG, "a").close()
    except OSError as e:
        print(f"[decoy-web] cannot create {LOG}: {e}", flush=True)
    app = web.Application(middlewares=[log_mw])
    app.add_routes([
        web.get("/", h_index),
        web.get("/login", h_login_get),
        web.post("/login", h_login_post),
        web.get("/robots.txt", h_robots),
        web.get("/admin", h_admin),
        web.get("/admin/", h_admin),
        web.get("/backup/", h_backup_index),
        web.get("/__honeywall_health", h_health),
        web.get("/{tail:.*}", h_file),
    ])
    print(f"[decoy-web] {TITLE} listening on :{LISTEN_PORT}, honeytokens: {', '.join(TOKENS)}", flush=True)
    web.run_app(app, host="0.0.0.0", port=LISTEN_PORT, access_log=None, print=None)


if __name__ == "__main__":
    main()
