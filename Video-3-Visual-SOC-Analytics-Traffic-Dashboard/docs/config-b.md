<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/config-b.md -->
# Config B (Medium) — Run the Attack Campaign and Hunt It Down

**Goal:** launch the scripted three-phase attack from Kali, watch the wallboard react, then investigate it with the **Threat Hunting** dashboard (filters for verdict, source IP and port).

## Prerequisites

- Config A verified (a single denied connection shows on the wallboard).
- Kali 192.168.40.3 with `nmap` and `curl` (preinstalled), `nikto` optional: `sudo apt install -y nikto`.
- Two windows side by side: Kali terminal + wallboard (`http://192.168.10.2`, kiosk mode `d` `k`).

> ⚠️ **Authorised targets only.** The campaign script refuses any target outside 192.168.10.0/24. Never point these tools at systems you do not own.

## Steps

### 1. Install the Threat Hunting dashboard (on Alpine)

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/app/app-medium.json \
  -o grafana/dashboards/app-medium.json
```

After ≤ 30 s: **Dashboards → Visual SOC → Visual SOC 2 · Threat Hunting**.

### 2. Get the campaign script (on Kali)

```sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/kali-attack-campaign.sh -o kali-attack-campaign.sh
chmod +x kali-attack-campaign.sh
./kali-attack-campaign.sh --help
```

### 3. Launch the campaign

```sh
sudo ./kali-attack-campaign.sh
```

It pauses after each phase (ENTER to continue) so you can narrate the wallboard:

| Phase | What Kali does | What the FortiGate does | What the wallboard shows |
|---|---|---|---|
| 1 · Recon | `nmap -sn 192.168.10.0/24` | Policy 3 denies + logs every probe | THREAT LEVEL → ELEVATED, Attacker IPs = 1 |
| 2 · Port scan | `nmap --top-ports 1000` + UDP sample | Policy 3 denies ~1,000 connections | UNDER ATTACK, Ports Probed jumps, Top Scanned Ports fills |
| 3 · Web attacks | SQLi, traversal, Log4Shell, Shellshock, XSS, command injection, Nikto on port 80 | Policy 2 allows HTTP, **IPS** blocks the payloads | IPS Detections climbs, Top IPS Signatures lists named attacks, `000 BLOCKED` in the terminal |

Flags: `--no-pause` (runs straight through), `--phase 2` (one phase only, ideal for retakes).

### 4. Hunt it (Threat Hunting dashboard)

Set the time picker to **Last 15 minutes**, then use the variables at the top:

| Question | Set | Read |
|---|---|---|
| What did the attacker *succeed* at? | Verdict = `allowed`, Source IP = `192\.168\.40\.3` | **Conversations** shows only `→ 192.168.10.2:80 Kali_To_SOC_Web` |
| What did they try and fail? | Verdict = `blocked` | **Conversations** lists every port with `Kali_To_Servers_Deny` |
| Did they try RDP? | Verdict = All, Dest port = `3389` | Matching events > 0, all blocked |
| Which exploits? | (any) | **IPS hits by signature and source** table |
| Who used the most bandwidth? | Verdict = All | **Bandwidth hogs** (bytes from allowed sessions) |

The Source IP and Dest port boxes are **regular expressions**: escape dots (`192\.168\.40\.3`), use `|` for several values (`22|3389`), `.*` for everything.

## Verification

- Wallboard during phase 2: THREAT LEVEL = **UNDER ATTACK**, Ports Probed ≥ 100.
- Wallboard ~60 s after the script ends: THREAT LEVEL back to **ALL CLEAR**.
- Threat Hunting with Verdict = `allowed` and Source IP = `192\.168\.40\.3`: the only destination port in **Conversations** is **80**. That single row is the proof that segmentation works.
- If IPS is licensed/bundled: **IPS hits by signature and source** has ≥ 1 row.

## Common mistakes

| Mistake | Fix |
|---|---|
| Ran nmap without `sudo` | Works, but uses slower connect scans — run with `sudo` for the clean SYN-scan demo |
| Ports Probed stays low | Policy 3 below another allow rule, or scanning the wrong IP — check `TARGET` |
| Every web payload returns `302`/`404`, never `000` | IPS not attached to policy 2, or signatures too old — see `docs/vt.md` section 5 |
| Source IP filter `192.168.40.3` matches nothing odd | Unescaped dots are wildcards; harmless here, but use `192\.168\.40\.3` for exact matches |
| Tables empty but stats show numbers | Time picker shorter than the attack — widen to *Last 1 hour* |
| Kali loses the wallboard during the scan | Normal under heavy nmap on a tiny VM; reduce speed with `-T3` in the script if needed |
