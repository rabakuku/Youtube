<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/config-c.md -->
# Config C (Advanced) — Detection Rules, Alerts and Attacker Forensics

**Goal:** turn the dashboard into a detection system. Three provisioned Grafana alert rules fire automatically during the attack, and the **Detections & Forensics** dashboard shows the scan-detector math, IPS annotations, and a per-attacker profile.

## Prerequisites

- Config B done (campaign runs, wallboard reacts).
- Shell on Alpine 192.168.10.2 as root.

## The detection rules (`app/alert-rules.yaml`)

| Rule | Logic (evaluated every 30 s) | Severity | MITRE ATT&CK |
|---|---|---|---|
| **Port scan detected** | One source hits **> 20 distinct denied ports** in 60 s | high | T1046 Network Service Discovery |
| **Web attack blocked by IPS** | **Any** IPS signature match in 60 s (one alert per source + signature) | critical | T1190 Exploit Public-Facing Application |
| **FortiGate log feed silent** | **No** FortiGate logs for 5 min | warning | — (pipeline health) |

The port-scan rule is the classic *distinct ports per source* heuristic, written in LogQL:

```text
count by (srcip) (
  sum by (srcip, dstport) (
    count_over_time({source="fortigate", log_type="traffic", verdict="blocked"} | json [1m])
  )
) > 20
```

## Steps

### 1. Install the alert rules (on Alpine)

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose
mkdir -p grafana/provisioning/alerting
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/app/alert-rules.yaml \
  -o grafana/provisioning/alerting/alert-rules.yaml
chmod a+r grafana/provisioning/alerting/alert-rules.yaml
docker compose restart grafana
```

Alert provisioning is read only at Grafana start-up, hence the restart (≈ 20 s).

### 2. Install the Detections & Forensics dashboard

```sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/app/app-advanced.json \
  -o grafana/dashboards/app-advanced.json
```

Open **Dashboards → Visual SOC → Visual SOC 3 · Detections & Forensics**.

### 3. Confirm the rules loaded

In Grafana: **Alerting → Alert rules → folder Visual SOC → group visual-soc-detections**. Three rules, each with a *Provisioned* badge, state **Normal**.

### 4. (Optional) Send alerts to Discord, Slack or Teams

Without this step alerts are visible in Grafana but not delivered anywhere (the default email contact point has no SMTP server).

1. **Alerting → Contact points → + Add contact point**
2. Name `soc-chat`, Integration **Discord** (or Slack / Microsoft Teams / Webhook), paste your webhook URL, **Test**, **Save**.
3. **Alerting → Notification policies → Default policy → ⋯ → Edit** → Default contact point = `soc-chat` → **Update default policy**.

Keep the webhook URL private — treat it like a password.

### 5. Trigger the detections (on Kali)

```sh
sudo ./kali-attack-campaign.sh --phase 2   # port scan → "Port scan detected"
sudo ./kali-attack-campaign.sh --phase 3   # web attacks → "Web attack blocked by IPS"
```

## Reading the Detections & Forensics dashboard

| Panel | Shows |
|---|---|
| Detections — firing & pending | Live list of the rules above with the attacker IP in the labels |
| Port-scan score (60 s) | The number the port-scan rule compares to 20 |
| IPS hits (60 s) | The number the IPS rule compares to 0 |
| Scan detector timeline | Distinct denied ports per source, red threshold band at 20, **red markers** for each IPS event (annotation) |
| Attacker profile | Per source: every blocked port, service and IPS signature — the forensic summary you would hand to an incident responder |
| Kill chain | Blocked events split into *Recon (port scan)* and *Exploit (IPS)* |

## Verification

1. During phase 2 the **Port-scan score** goes above 20 and within ≤ 60 s **Port scan detected** shows as **Firing** with label `srcip=192.168.40.3`.
2. During phase 3 (with IPS working) **Web attack blocked by IPS** fires once per signature, and red annotation markers appear on the timeline.
3. ~1–2 minutes after the attack stops, both rules return to **Normal** (`noDataState: OK`).
4. If you configured step 4, the chat channel receives a *Firing* and later a *Resolved* message.

## Common mistakes

| Mistake | Fix |
|---|---|
| Rules not listed after copying the file | Grafana was not restarted, or the file is not under `compose/grafana/provisioning/alerting/` |
| Rule state **Error** | Datasource UID mismatch — it must be `loki-fortigate` (from `grafana-datasource.yaml`) |
| Port-scan rule never fires | Scan too small or too slow: fewer than 21 ports inside 60 s. Use `--phase 2` (top 1000 ports) |
| "Log feed silent" fires while the lab is idle | Expected when nothing generates logs for 5 min (policies 1 and 4 only log security events). Keep the wallboard open or pause the rule: Alerting → Alert rules → ⋯ → **Pause evaluation** |
| Can't edit a rule in the UI | Provisioned rules are read-only on purpose; edit `alert-rules.yaml` and restart Grafana |
| Email errors in `docker compose logs grafana` | The default email contact point has no SMTP — do step 4 or ignore |

## Next level (teaser for the follow-up video)

Detection is half the job. The natural next step is **response**: point the contact point at a webhook (n8n or a small script on Alpine) that calls the FortiGate REST API to add the attacker IP to a quarantine address group — closing the loop from *detect* to *block automatically*.
