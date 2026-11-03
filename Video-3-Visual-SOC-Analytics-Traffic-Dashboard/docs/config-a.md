<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/config-a.md -->
# Config A (Basic) — First Login, the Wallboard, and LogQL in 4 Queries

**Goal:** log in, understand the pre-built wallboard, add the Quickstart dashboard, and prove the full chain FortiGate → Vector → Loki → Grafana with one command.

## Prerequisites

- Stages 1–4 done: `docker compose ps` shows three `(healthy)` containers, FortiGate syslog points to 192.168.10.2:514.
- The Grafana password printed by `setup.sh` (or `grep GRAFANA_ADMIN_PASSWORD /opt/visual-soc-analytics-traffic-dashboard/compose/.env` on Alpine).
- Kali browser at 192.168.40.3.

## Steps

### 1. First login

1. On Kali open `http://192.168.10.2`.
2. Username `admin`, password from `.env`.
3. You land directly on **Fortinet Visual SOC — Live Wallboard** (it is the home dashboard). If not: **Dashboards → Visual SOC → Fortinet Visual SOC — Live Wallboard**.
4. Optional for recording: press **`d` then `k`** (kiosk mode) to hide the Grafana menus. `Esc` exits.

### 2. Tour of the wallboard (top to bottom)

| Panel | What it answers | Built from |
|---|---|---|
| THREAT LEVEL | Are we under attack *right now*? | blocked events in the last 60 s → ALL CLEAR / ELEVATED / UNDER ATTACK |
| Events / Blocked / IPS / Attackers / Ports / Allowed | Volume of each verdict | `count_over_time` on Loki labels |
| Attack Timeline | When did it start, how big is it? | stacked bars per `verdict` |
| Top Attacker IPs | Who? | `topk(5, sum by (srcip) ...)` |
| Top Scanned Ports | What were they looking for? | denied `dstport` |
| Top IPS Signatures | What exploits did they try? | IPS `attack` field |
| Traffic by Firewall Policy | Which rule did the work? | `policyname` |
| Live SOC Event Stream | The raw evidence, color-coded | red = blocked, yellow = detected, green = allowed |

### 3. Add the Quickstart (teaching) dashboard

On **Alpine** (192.168.10.2):

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/app/app-basic.json \
  -o grafana/dashboards/app-basic.json
```

No restart needed: the dashboard provider rescans the folder every 30 seconds. Open **Dashboards → Visual SOC → Visual SOC 1 · Quickstart (4 LogQL queries)**.

### 4. The four LogQL building blocks (great on camera)

Open **Explore** (compass icon), choose datasource **Loki**, switch the query editor to **Code**, and run:

| # | Query | Teaches |
|---|---|---|
| 1 | `{source="fortigate"}` | Stream selector — raw JSON lines as Vector stored them |
| 2 | `{source="fortigate", verdict="blocked"}` | Label filter — only the blocks |
| 3 | `{source="fortigate", verdict="blocked"} \| json \| dstport="22"` | Parse JSON, filter on any FortiOS field |
| 4 | `sum by (verdict) (count_over_time({source="fortigate"}[1m]))` | Turn logs into a metric you can graph |

In the Explore table, labels in `{...}` are indexed by Loki (`source`, `log_type`, `action`, `verdict`). Everything else (IPs, ports, signatures) lives in the JSON body and is extracted at query time with `| json` — that is why Loki stays light enough to run on a small Alpine VM.

## Verification

1. On the **FortiGate**: `diagnose log test`
2. Within ~5 s on the wallboard: **Events (5m)** increases and the Live SOC Event Stream shows new lines.
3. From **Kali**: `curl -m 3 telnet://192.168.10.2:22` (it times out — that is the point).
4. Within ~5 s: **Blocked (5m)** ≥ 1, THREAT LEVEL shows **ELEVATED**, the stream shows `BLOCKED 192.168.40.3:… → 192.168.10.2:22 … policy=3 (Kali_To_Servers_Deny)`.

## Common mistakes

| Mistake | Fix |
|---|---|
| Typing `http://192.168.10.2:3000` | Grafana is published on port **80** — use `http://192.168.10.2` |
| "Invalid username or password" | The password is the generated one in `.env`, not the old README's `VisualSocAdmin2026!` |
| Quickstart dashboard does not appear | Wait 30 s; check the file landed in `compose/grafana/dashboards/` and is readable (`ls -l`) |
| Explore shows "No logs found" | Time picker too narrow or nothing sent yet — run `diagnose log test` and set *Last 15 minutes* |
| Editing a provisioned panel and losing changes | Provisioned dashboards are read-only by design; use **Save as** to make your own copy |
