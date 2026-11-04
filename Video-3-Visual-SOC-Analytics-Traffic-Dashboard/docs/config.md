<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/config.md -->
# Config — Wallboard, Attack Campaign, Detection & One-Click Quarantine

**Goal:** log in from the admin PC, subscribe to ntfy, run the attack campaign from Kali, approve the quarantine from the alert, and watch FGTQC01 cut the attacker off — then read the evidence on the dashboards.

## Prerequisites

- `setup.sh` finished with 5 healthy containers and `quarantine is LIVE` (FortiGate token stored).
- `docs/Fortinet-cli.md` applied: policy order **100, 2, 3, 101, 4, 102**, VIPs NTFY-TO-SOC and RESPONDER-TO-SOC in `VIP TO INTERNAL`.
- `kali-attack-campaign.sh` copied to Kali (Kali has no internet):
  ```sh
  scp -P 2223 Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/kali-attack-campaign.sh <kali-user>@172.24.66.58:~/
  ```
- On Alpine, note two values: `grep -E 'NTFY_TOPIC|GRAFANA_ADMIN_PASSWORD' /opt/visual-soc-analytics-traffic-dashboard/compose/.env`

---

## 1. Open the two screens on the admin PC

| Window | URL | Do this |
|---|---|---|
| Wallboard | `http://172.24.66.52:8080` | Log in as `admin`. You land on **Fortinet Visual SOC — Live Wallboard**. Press `d` then `k` for kiosk mode |
| Alerts | `http://172.24.66.52:8090/<NTFY_TOPIC>` | Click **Subscribe**, then allow browser notifications. You see the "Visual SOC is live" test message |

Put them side by side, with the Kali SSH session (`ssh -p 2223 <kali-user>@172.24.66.58`) as the third window.

### Reading the wallboard

| Panel | Answers |
|---|---|
| THREAT LEVEL | Under attack right now? Blocks in the last 60 s → ALL CLEAR / ELEVATED / UNDER ATTACK |
| Events · Blocked · IPS · Attacker IPs · Ports Probed | How big is it, who, what are they looking for |
| **QUARANTINED** | How many IPs the responder holds in `SOC-Quarantine` now (NONE / number, purple) |
| Attack Timeline | Allowed / blocked / detected over time; **purple markers** = quarantine and release |
| Top Attacker IPs · Top Scanned Ports · Top IPS Signatures | The attacker's profile at a glance |
| Traffic by Firewall Policy | Which rule did the work — green Kali_To_SOC_Web, red Kali_To_Servers_Deny, purple SOC_Quarantine_Block, dark red Kali_To_WAN_Deny |
| Live SOC Event Stream | Every decision, color-coded |
| **Response Actions** | What the responder did: APPROVAL_REQUESTED, QUARANTINE, RELEASE, IGNORED, failures |

---

## 2. The detection rules

Provisioned by `setup.sh` (`app/alert-rules.yaml`), evaluated every 30 s, every alert routed to the responder:

| Rule | Fires when | Severity | MITRE ATT&CK |
|---|---|---|---|
| **Port scan detected** | One source hits **> 20 distinct denied ports** in 60 s | high | T1046 Network Service Discovery |
| **Web attack blocked by IPS** | **Any** IPS match in 60 s (one alert per source + signature) | critical | T1190 Exploit Public-Facing Application |
| **FortiGate log feed silent** | **No** FortiGate logs for 5 minutes | warning | pipeline health |

Port-scan logic in LogQL:

```text
count by (srcip) (
  sum by (srcip, dstport) (
    count_over_time({source="fortigate", log_type="traffic", verdict="blocked"} | json [1m])
  )
) > 20
```

Check in Grafana: **Alerting → Alert rules → Visual SOC → visual-soc-detections** (3 rules, *Provisioned*, *Normal*) and **Alerting → Contact points → soc-responder**.

---

## 3. How the response works

```text
Grafana alert ─► responder ─► ntfy: "Port scan detected: 192.168.40.3"  [Quarantine 15 minutes] [Ignore] [Wallboard]
                     │                       click Quarantine
                     ▼
         FortiGate API: create Q-192.168.40.3, add it to SOC-Quarantine
                     ▼
         policy 100 SOC_Quarantine_Block denies every new connection from 192.168.40.3
                     ▼
ntfy: "192.168.40.3 quarantined for 15 minutes"  [Release now]  …  "192.168.40.3 released"
```

Settings live in `compose/.env` on Alpine:

| Setting | Default | Meaning |
|---|---|---|
| `QUARANTINE_MODE` | `approve` | `approve` = buttons in ntfy · `auto` = quarantine at once (still sends *quarantined* and *released*) |
| `QUARANTINE_MINUTES` | `15` | Ban length; released automatically, or earlier with **Release now** |
| `QUARANTINE_ALLOWLIST` | `192.168.10.0/24,192.168.40.1/32,172.24.66.0/24` | Never quarantined: the SOC VLAN, the USERS gateway, the admin side |
| `LINK_TTL_SECONDS` | `1800` | Approval buttons expire after 30 minutes and work once |

Change a setting, then apply it:

```sh
cd /opt/visual-soc-analytics-traffic-dashboard
sed -i 's/^QUARANTINE_MODE=.*/QUARANTINE_MODE=auto/' compose/.env
./setup.sh
```

---

## 4. Run the attack and approve the quarantine

On **Kali**:

```sh
chmod +x kali-attack-campaign.sh
sudo ./kali-attack-campaign.sh            # pauses between phases; --phase 2 / --phase 3 for retakes
```

| Phase | Kali does | FGTQC01 does | You see |
|---|---|---|---|
| 1 · Recon | `nmap -sn 192.168.10.0/24` | 101 denies + logs | THREAT LEVEL **ELEVATED** |
| 2 · Port scan | top 1000 TCP + UDP sample | 101 denies ~1,000 connections, only 80/tcp open | **UNDER ATTACK**, Ports Probed jumps; within ~60 s ntfy shows **Port scan detected: 192.168.40.3** with buttons |
| **Approve** | — | — | Click **Quarantine 15 minutes** → ntfy **192.168.40.3 quarantined for 15 minutes**; wallboard **QUARANTINED 1**, purple marker on the timeline |
| 3 · Web attacks | SQLi, traversal, Log4Shell, Shellshock, XSS, Nikto on port 80 | **100 SOC_Quarantine_Block** denies every request | Every request prints `BLOCKED` / times out; stream shows `policy=100 (SOC_Quarantine_Block)` |
| Release | — | `Q-192.168.40.3` removed | Click **Release now** (or wait 15 min) → ntfy **192.168.40.3 released**; QUARANTINED back to NONE |

**Variant — IPS first:** run `--phase 3` *without* approving a quarantine: the IPS blocks the payloads on the allowed port and **Web attack blocked by IPS** arrives in ntfy (priority 5). Approve it and repeat `--phase 3` — now even the clean requests time out.

> Your SSH session to Kali stays up during the quarantine: it is an inbound session you opened through the `SSH-TO-KALI` VIP. Kali itself cannot open any new connection — not to the SOC, other servers or WAN.

---

## 5. Investigate: Visual SOC · Detections & Response

Open it from the wallboard's top-right link, or the **Wallboard** button in any ntfy alert.

| Panel | Shows |
|---|---|
| Detections — firing & pending | Live alert list with `srcip` labels |
| Port-scan score · IPS hits · QUARANTINED | The numbers the rules compare (20 and 0) and the current quarantine count |
| Scan detector | Distinct denied ports per source, red band at 20, purple quarantine markers |
| Quarantine at work | Connections a quarantined IP tried after the ban (policy 100 hits) |
| Response Actions | Audit trail of every responder decision, including failures |
| Attacker profile | Per source: blocked ports, services, IPS signatures and which policy stopped each |
| Kill chain | Recon (port scan) → Exploit (IPS) → Contained (quarantine) → Egress attempts (WAN) |
| Conversations | Every source → destination:port pair with its policy and verdict |

---

## 6. Verification checklist

1. ntfy approval arrives ≤ 60 s after phase 2 starts.
2. After **Quarantine**: FortiGate `show firewall addrgrp SOC-Quarantine` lists `"none" "Q-192.168.40.3"`; Kali `curl -sI -m 5 http://192.168.10.2` times out.
3. Wallboard **QUARANTINED = 1**; Response Actions shows `QUARANTINE 192.168.40.3 · Port scan detected · by admin via ntfy (…)`.
4. After **Release now**: group back to `"none"`, Kali's curl returns `302`, ntfy says **released**, QUARANTINED = NONE.
5. Detections & Response → Kill chain shows *Contained (quarantine)* > 0.

---

## 7. Under the hood — LogQL in four steps (Explore → Loki → Code)

| # | Query | Teaches |
|---|---|---|
| 1 | `{source="fortigate"}` | Stream selector — raw JSON lines from Vector |
| 2 | `{source="fortigate", verdict="blocked"}` | Label filter |
| 3 | `{source="fortigate", verdict="blocked"} \| json \| dstport="22"` | Parse JSON, filter on any FortiOS field |
| 4 | `sum by (verdict) (count_over_time({source="fortigate"}[1m]))` | Logs → metric |

Responder audit lines live under `{source="responder"}` (`event` = quarantine, release, ignored, approval_requested, state…).

---

## Common mistakes

| Mistake | Fix |
|---|---|
| No ntfy alert after the scan | Grafana → Alerting: rule *Firing*? Contact point **soc-responder** present? `docker compose logs responder` |
| ntfy tab shows nothing at all | Wrong topic in the URL — it must equal `NTFY_TOPIC` exactly |
| Buttons do nothing | PC cannot reach `http://172.24.66.52:8091/health`; check VIP RESPONDER-TO-SOC in policy 4 |
| "Link not valid: link expired / already used" | Buttons last 30 min and work once — wait for the next alert |
| ntfy says *DRY RUN* | No token stored: `./setup.sh --fgt-token <KEY>` |
| Quarantined, but Kali still reaches port 80 | Policy 100 is not first: `move 100 before 2` |
| Port-scan rule never fires | Policy 3 still allows ALL, or 101 is above 3 (see Fortinet-cli.md step 6) |
| QUARANTINED tile shows NONE although someone is quarantined | It updates every 30 s; check `curl -s http://127.0.0.1:8091/health` on Alpine |
| "FortiGate log feed silent" fires while idle | Expected after 5 min without any logs; keep the wallboard open or pause the rule in Alerting |
| Can't edit a provisioned dashboard or rule | By design; **Save as** a copy, or edit the file in the repo and re-run `setup.sh` |
