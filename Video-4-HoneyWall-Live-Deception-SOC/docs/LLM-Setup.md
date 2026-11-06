<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/LLM-Setup.md -->
# Optional AI incident reports — home LLM setup

HoneyWall can have a local LLM write a plain-English incident report after every quarantine. The model runs on your own GPU (Ubuntu 26.04 + RTX 3060 + Ollama). No data leaves your hardware except over your own tunnel.

The feature is **off by default**, and the lab works fully without it. When it's off, or the LLM is unreachable, HoneyWall still writes a template report from the raw facts.

```text
 Lab (work, EVE-NG)                         Internet                    Home (Ubuntu + RTX 3060)
 ┌───────────────────────┐   HTTPS 443   ┌────────────────────┐  outbound  ┌──────────────────────────┐
 │ HoneyWall engine      │──────────────▶│ Cloudflare edge     │◀──────────│ cloudflared (tunnel)      │
 │ 192.168.10.2          │  Bearer key   │ WAF: only your work │  no open  │   ↓ http://127.0.0.1:8081 │
 │ via FortiGate WAN NAT │               │ public IP allowed   │  ports    │ Caddy gate (checks key)   │
 └───────────────────────┘               └────────────────────┘            │   ↓ 127.0.0.1:11434       │
                                                                           │ Ollama  llama3.1:8b (GPU) │
                                                                           └──────────────────────────┘
```

There are three layers of protection, so a single mistake doesn't open the door:

1. **Ollama is bound to `127.0.0.1` only.** It's never reachable from the network directly.
2. **Caddy requires `Authorization: Bearer <LLM_API_KEY>`.** Anything else gets a 401. Caddy also rewrites the Host header, because Ollama refuses non-local Host headers.
3. **A Cloudflare WAF custom rule blocks every source IP except your work's public IP.** No port is opened on your home router; the tunnel dials out.

## Choose an access mode

| Mode | How the lab reaches the GPU | Needs | Best for |
|---|---|---|---|
| **cloudflare** (default) | `https://llm.ccdtt.com` through a Cloudflare Tunnel, with a WAF IP allowlist | `ccdtt.com` on Cloudflare DNS (free plan is fine) | The video: a real HTTPS URL, nothing opened at home |
| **tailscale** | Private tailnet; the lab runs the `tailscale` sidecar (`COMPOSE_PROFILES=standard,llm-tailscale`) | A Tailscale account and an auth key | Most private: nothing public at all |
| **direct** | `https://<home-public-ip>:8443` with a self-signed certificate and a ufw allowlist | A router port-forward, and a stable home IP or DDNS | When neither of the others is possible |

## 1. Find your work's public IP (from Alpine)

```sh
curl -s https://ifconfig.me; echo
```

That's the address the lab uses on the internet, after the FortiGate's WAN NAT and your work firewall. You pass it to `--allow-ip`.

## 2. Run the setup script on the Ubuntu GPU box

```bash
curl -fsSLO https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/llm-host-setup.sh
chmod +x llm-host-setup.sh

# Cloudflare (default). Add --cf-api-token to create the WAF allowlist rule automatically.
sudo ./llm-host-setup.sh --mode cloudflare --hostname llm.ccdtt.com --allow-ip <work-public-ip> \
     --cf-api-token <CLOUDFLARE_API_TOKEN>

# or Tailscale
sudo ./llm-host-setup.sh --mode tailscale

# verify any time (changes nothing)
sudo ./llm-host-setup.sh --check
```

The script checks everything itself before touching anything: the OS, the GPU and NVIDIA driver, Ollama and its service, the model, Caddy, cloudflared, Tailscale and ufw. It then installs only what's missing:

| Component | Detected with | If missing |
|---|---|---|
| NVIDIA driver | `nvidia-smi` | `ubuntu-drivers install`, then asks you to reboot and rerun (or use `--skip-gpu` to run on CPU) |
| Ollama | `ollama --version`, service state | Official installer. Adds a systemd override with `OLLAMA_HOST=127.0.0.1:11434` and `OLLAMA_KEEP_ALIVE=24h`, so the model stays warm for fast reports |
| Model | `ollama list` | `ollama pull llama3.1:8b` (about 4.9 GB; fits the 3060's 12 GB), then warms it up |
| Caddy | `caddy version` | Ubuntu package, falling back to the official Caddy repo. Writes `/etc/caddy/honeywall-llm.caddy` and imports it |
| cloudflared | `cloudflared --version` | Cloudflare's apt repo, `cloudflared tunnel login` (one browser click), creates tunnel `honeywall-llm`, sets DNS for `llm.ccdtt.com`, and installs the service |
| Tailscale | `tailscale version`, backend state | Official installer, then `tailscale up` |
| ufw | `ufw status` | Installed for direct mode (OpenSSH is allowed first, so you can't lock yourself out) |

**Cloudflare API token (optional).** Create it in the Cloudflare dashboard under My Profile → API Tokens → Create Token → Custom token, with permissions *Zone · Zone · Read* and *Zone · Zone WAF · Edit*, scoped to `ccdtt.com`. The script only adds or updates **one** rule named `honeywall-llm-allowlist`; your other WAF rules are never touched.

If you skip the token, the script prints the exact rule to paste in by hand:

```text
ccdtt.com → Security → WAF → Custom rules → Create rule
Name:        honeywall-llm-allowlist
Expression:  (http.host eq "llm.ccdtt.com" and not ip.src in {<work-public-ip>})
Action:      Block
```

**Self-tests** at the end of every run:

| Test | Expected |
|---|---|
| Ollama answers on 127.0.0.1:11434 | PASS |
| Ollama is bound to localhost only | PASS |
| Local chat completion with the model | PASS, with a latency figure |
| Gate with the key | 200 |
| Gate without a key, or with a wrong key | 401 |
| cloudflared service active | PASS (cloudflare mode) |
| `https://llm.ccdtt.com` with the key, from the GPU box | 200 if your home IP is allowed; **403 is expected** when the WAF allowlist only allows work. Test from Alpine instead |
| `https://llm.ccdtt.com` without a key | 401 or 403 |

The script finishes by printing the exact `.env` lines. The key is generated once and saved in `/etc/honeywall-llm/state.env` (root only). Re-running the script keeps the same key.

## 3. Turn it on in the lab

Paste the printed lines into `/opt/honeywall/compose/.env`. For Cloudflare they look like this:

```ini
LLM_ENABLED=true
LLM_ACCESS_MODE=cloudflare
LLM_BASE_URL=https://llm.ccdtt.com
LLM_API_KEY=<printed by the script>
LLM_MODEL=llama3.1:8b
LLM_VERIFY_TLS=true
LLM_HTTP_PROXY=
```

Then restart the stack and test from Alpine:

```sh
cd /opt/honeywall/compose && docker compose up -d
curl -s https://llm.ccdtt.com/v1/models -H "Authorization: Bearer <LLM_API_KEY>" | head -c 200; echo   # 200 + model list
curl -s -XPOST http://127.0.0.1/api/test/llm; echo                                                      # {"ok": true, "latency_ms": ...}
```

For Tailscale, also set `COMPOSE_PROFILES=standard,llm-tailscale` and `TS_AUTHKEY` (a reusable key from Tailscale admin → Settings → Keys). In your tailnet policy, allow only the lab node to reach the GPU on port 8081:

```json
{ "acls": [ { "action": "accept", "src": ["honeywall-lab"], "dst": ["honeywall-gpu:8081"] } ] }
```

## Turning AI reports on and off

You can switch it in any of three places:

| Where | How |
|---|---|
| `.env` | `LLM_ENABLED=true` or `false`, then `docker compose up -d` |
| setup.sh (Stage 4) | `./setup.sh --llm on` or `--llm off` |
| Dashboard | The **AI reports** button in the header. It takes effect immediately and survives restarts |

## Where to read the reports

Each quarantine produces one report, a few seconds after the ban:

- **HoneyWall dashboard → Incident reports panel → Read.** It opens in a viewer with a **Download .md** button. An "AI" badge means the LLM wrote it; "template" means it didn't.
- **ntfy** (`http://172.24.66.58:8090/honeywall`). A "Incident report ready" message with the summary; click it to open the report.
- **On Alpine**, as files: `docker compose exec engine ls /data/reports` gives `<time>-<ip>.md` and `.json`. Copy one out with `docker compose cp engine:/data/reports/<file>.md .`

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/api/test/llm` → `HTTP 403` with an HTML page | The WAF blocked the lab: your work's public IP changed, or it's a different egress IP | `curl ifconfig.me` on Alpine again, then rerun the script with the new `--allow-ip` |
| 403 with "challenge" in the HTML | Cloudflare Bot Fight Mode is challenging the engine | Turn off Bot Fight Mode for the zone, or add a WAF *Skip* rule for `llm.ccdtt.com` from your work IP |
| `HTTP 401` | Wrong or missing `LLM_API_KEY` | Copy it again from `/etc/honeywall-llm/state.env` |
| `HTTP 530` or `1033` | The tunnel is down | `sudo systemctl status cloudflared`, `journalctl -u cloudflared -n 50` |
| `HTTP 502` | Caddy is up but Ollama is down | `systemctl status ollama`, `journalctl -u ollama -n 50` |
| A report takes more than 30 s | The model was unloaded, or it's running on CPU | `nvidia-smi` should show `ollama` using VRAM; `OLLAMA_KEEP_ALIVE=24h` keeps it loaded |
| Tailscale mode: timeout | The sidecar isn't logged in, or the ACL blocks it | `docker compose logs tailscale`; check the ACL; `tailscale ping honeywall-gpu` from the GPU box |
| Script exits with code 3 | The NVIDIA driver was just installed | Reboot, then run the same command again |

To remove everything: `sudo ./llm-host-setup.sh --uninstall`. Add `--purge` to also remove Ollama and its models. The Cloudflare tunnel, DNS record and WAF rule are listed for you to delete in the dashboard.
