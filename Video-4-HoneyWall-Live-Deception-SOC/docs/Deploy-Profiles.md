<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/Deploy-Profiles.md -->
# Deploying HoneyWall different ways

HoneyWall is one lab. You can change how much of it runs, where the LLM lives, and how it behaves, all without touching code. Everything is driven by `compose/.env` and `setup.sh`.

## Profiles

| Profile | Services | RAM (approx.) | What it shows |
|---|---|---|---|
| `lite` | cowrie, engine | ~300 MB | Pure auto-quarantine. Watch it in `docker compose logs -f engine` and on the FortiGate. No UI |
| `standard` (**video default**) | lite + dashboard + ntfy + web decoy | ~550 MB | The full on-camera experience: SSH and web decoys, HoneyWall, alerts |
| `full` | standard + Dozzle | ~650 MB | Adds live container logs in the browser (`http://172.24.66.58:9999`) |
| add-on `llm-tailscale` | + tailscale sidecar | +60 MB | Only for the Tailscale LLM mode (setup.sh adds it automatically) |

Each profile serves these ports and URLs:

| | lite | standard | full |
|---|---|---|---|
| SSH decoy `192.168.40.1:22` | ✔ | ✔ | ✔ |
| Web decoy `192.168.40.1:80` | — | ✔ | ✔ |
| HoneyWall `:8080` | — | ✔ | ✔ |
| ntfy `:8090` | — | ✔ | ✔ |
| Dozzle `:9999` | — | — | ✔ |

### Switching profiles

```sh
cd /opt/honeywall
./setup.sh --profile lite        # or standard / full
```

`setup.sh` updates `COMPOSE_PROFILES`, stops services that aren't in the new profile, and starts the rest. The manual equivalent:

```sh
cd /opt/honeywall/compose
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=full/' .env
docker compose up -d --remove-orphans
```

Note that `lite` has no web decoy. The FortiGate VIP `:80` then simply has nothing behind it, which is harmless.

## Feature switches

| Feature | Switch | Values | Where else |
|---|---|---|---|
| AI incident reports | `LLM_ENABLED` | `true` / `false` | `./setup.sh --llm on\|off`; the dashboard **AI reports** button (live) |
| LLM access path | `LLM_ACCESS_MODE` | `cloudflare` (default), `tailscale`, `direct` | `docs/LLM-Setup.md` |
| Rehearsal (simulated FortiGate) | `FGT_SIMULATE` | `true` / `false` | `./setup.sh --simulate on\|off` |
| Web decoy rules | `WEB_DECOY_ENABLED` | `true` / `false` | Container on/off via the profile |
| Ban duration | `BAN_EXPIRY` | `0` = until Unban, or seconds | — |
| Close the attacker's open sessions | `FGT_CLOSE_SESSIONS` | `true` / `false` | Needs the session-close permission (`docs/Fortinet-cli.md` block 7) |
| Never ban | `NEVER_BAN` | CIDRs, comma-separated | Protects 192.168.10.0/24 and the FortiGate WAN IP by default |
| Brute-force rule | `BRUTE_THRESHOLD`, `BRUTE_WINDOW_SEC` | default `5` in `30` s | SSH and web failures count together |
| SSH honeytokens | `HONEYTOKENS` | file paths | Files must exist under `compose/honeyfs/` |
| Web honeytokens | `WEB_HONEYTOKENS` | URL paths | `/.env,/backup/.env.bak,/backup/db_dump.sql` |
| Risky commands (raise the score) | `HIGH_RISK_COMMANDS` | substrings | — |
| Dashboard look | `DASHBOARD_THEME`, `DASHBOARD_LAYOUT`, `DASHBOARD_SOUND`, `DASHBOARD_FLASH` | `hollywood`/`enterprise`, `full`/`split`, `true`/`false` | Viewer keys `T`, `L`, `S`, `F` override these per browser |
| Dashboard access token | `DASHBOARD_TOKEN` | empty = open inside the lab | Open `http://172.24.66.58:8080/?token=<value>` once; the browser remembers it |
| Alerts | `NTFY_ENABLED`, `NTFY_TOPIC` | — | — |

After editing `.env`, apply it with `cd /opt/honeywall/compose && docker compose up -d`. Settings are read at container start.

### Changing the decoy story

| Change | Edit | Then |
|---|---|---|
| Leaked password | `compose/userdb.txt`, and `LEAKED_PASS` in `scripts/kali-attack-campaign.sh` | `docker compose restart cowrie` |
| Decoy hostname | `DECOY_HOSTNAME` in `.env` | `docker compose up -d` |
| Add an SSH bait file | Drop it under `compose/honeyfs/<path>` and add `<path>` to `HONEYTOKENS` | `docker compose up -d --force-recreate cowrie-fsbuild cowrie engine` |
| Web portal name | `WEB_DECOY_TITLE`, `WEB_DECOY_HOSTNAME` | `docker compose up -d decoy-web` |

## LLM placement

| Mode | GPU box | Lab side | Internet exposure |
|---|---|---|---|
| **Cloudflare** (default) | `llm-host-setup.sh --mode cloudflare --allow-ip <work-ip>` | Nothing extra: `LLM_BASE_URL=https://llm.ccdtt.com` | Tunnel only, WAF allows the work IP, bearer key required |
| **Tailscale** | `llm-host-setup.sh --mode tailscale` | `COMPOSE_PROFILES=standard,llm-tailscale` + `TS_AUTHKEY` | None (private tailnet) |
| **Direct** | `llm-host-setup.sh --mode direct --allow-ip <work-ip>` + router port-forward 8443 | `LLM_VERIFY_TLS=false` | One port, ufw allowlist, bearer key |
| **Off** | — | `LLM_ENABLED=false` | — (template reports) |

## Other hosts

| Host | Supported how | Notes |
|---|---|---|
| **Alpine 3.24** (lab default) | `setup.sh` / `rollback.sh` | Fully automated (OpenRC, apk) |
| **Debian / Ubuntu / Rocky** with Docker Engine + Compose v2 | Manual (below) | setup.sh refuses non-Alpine on purpose; the stack itself is plain Compose |
| **Different IPs** | Change the lab identity block in `.env` (`ALPINE_IP`, `KALI_IP`, `DECOY_VIP_IP`, `FGT_HOST`, …) and the FortiGate objects | The topology labels follow `.env` |
| **Kali alternatives** (any Linux with nmap/hydra/sshpass) | `kali-attack-campaign.sh` | The preflight installs tools with apt; the target must stay in 192.168.40.0/24 |

Manual install on any Docker Linux:

```bash
sudo mkdir -p /opt/honeywall && cd /opt/honeywall
git clone --depth 1 --filter=blob:none --sparse https://github.com/rabakuku/Youtube.git src
cd src && git sparse-checkout set Video-4-HoneyWall-Live-Deception-SOC && cd ..
cp -r src/Video-4-HoneyWall-Live-Deception-SOC/{compose,engine,dashboard,decoy-web,scripts} .
cd compose && cp -n .env.example .env && chmod 600 .env
nano .env                                    # FGT_API_TOKEN, TZ, IPs if different
docker compose build && docker compose up -d && docker compose ps
```

Teardown on a non-Alpine host is `docker compose --profile '*' down -v --rmi all` in `/opt/honeywall/compose`.

## What stays the same in every setup

- The FortiGate is always the enforcement point, through the REST ban (`ENFORCEMENT_MODE=rest-ban`), confirmed by read-back.
- Kali only ever reaches the decoy VIPs. HoneyWall, ntfy, Dozzle and the API are reachable only from the WAN side.
- Secrets live only in `compose/.env`. The repo ships placeholders.
- Bans are released only by **Unban** (or by hand on the FortiGate). HoneyWall follows either way.
