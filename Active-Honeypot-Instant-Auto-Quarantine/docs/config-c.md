```json
// filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/app/app.json
{
  "lab_metadata": {
    "project": "Active-Honeypot-Instant-Auto-Quarantine",
    "version": "1.0.0",
    "target_platform": "Alpine Linux 3.24 / FortiOS 7.4"
  },
  "tiers": {
    "tier_a_basic": {
      "name": "Basic Deception Pipeline",
      "description": "Direct JSON log file monitoring on the Alpine Docker host. Detects failed and unauthorized SSH authentications in cowrie.json and dispatches a Layer 3 quarantine POST payload via curl to FortiOS.",
      "cowrie": {
        "listen_port": 2222,
        "backend": "shell",
        "output_plugins": ["jsonlog"]
      },
      "webhook_endpoint": {
        "url": "https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine",
        "method": "POST",
        "headers": {
          "Content-Type": "application/json",
          "Authorization": "Bearer FortiGateSuperSecretToken2026"
        },
        "payload_template": {
          "srcip": "{{src_ip}}",
          "event": "{{eventid}}",
          "timestamp": "{{timestamp}}"
        }
      }
    },
    "tier_b_medium": {
      "name": "Intelligent Triage & Rate Thresholding",
      "description": "In-memory session state analysis. Evaluates failed attempt thresholds (>= 3 attempts within 30 seconds) or instant quarantine on high-risk username patterns (e.g., root, admin, support) before dispatching the webhook ban.",
      "thresholds": {
        "max_failed_attempts": 3,
        "window_seconds": 30,
        "instant_quarantine_users": [
          "root",
          "admin",
          "support",
          "ubnt",
          "cisco"
        ]
      },
      "rate_limit": {
        "cooldown_seconds": 300
      }
    },
    "tier_c_advanced": {
      "name": "Fabric-Wide Telemetry & Multi-Tier SOC Dispatch",
      "description": "Enterprise automated active defense loop. Combines zero-delay Layer 3 quarantine on the FortiGate kernel with asynchronous Syslog RFC-5424 generation, Mattermost/Slack SOC alert notifications, and automated honeypot session payload dumping.",
      "integrations": {
        "syslog": {
          "enabled": true,
          "host": "192.168.10.1",
          "port": 514,
          "facility": "local0",
          "severity": "alert"
        },
        "soc_notifications": {
          "enabled": true,
          "chat_webhook_url": "https://chat.corp.internal/hooks/fortigate-soc-alerts",
          "format": "markdown"
        },
        "forensics": {
          "capture_tty_logs": true,
          "dump_attacker_payload": true,
          "storage_directory": "/cowrie/cowrie-git/var/lib/cowrie/tty"
        }
      }
    }
  }
}

```

```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-a.md -->
# Stage 5A: Basic Honeypot Webhook Dispatch Walkthrough

This guide establishes the primary detection-to-mitigation pipeline between the Cowrie honeypot container on Alpine Linux (`192.168.10.2`) and the FortiOS Security Fabric (`192.168.10.1`).

---

### Step 1: Verify Cowrie Output Logging
1. Ensure the Cowrie container is running and actively outputting structured JSON logs:
   ```sh
   docker exec -it cowrie-honeypot tail -f /cowrie/cowrie-git/var/log/cowrie/cowrie.json

```

2. Trigger a test connection from Kali Linux (`192.168.40.3`):
```bash
ssh -p 2222 root@192.168.40.1

```


3. Verify that `cowrie.login.failed` or `cowrie.session.connect` appears in the log output with `src_ip: "192.168.40.3"`.

---

### Step 2: Configure the Alpine Event Watcher Script

Create a lightweight shell daemon on Alpine host (`192.168.10.2`) to monitor the log and invoke the FortiGate webhook:

1. Create `/opt/honeypot-quarantine/scripts/webhook-watcher.sh`:
```sh
#!/bin/sh
LOG_FILE="/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
FGT_URL="[https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine](https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine)"
TOKEN="FortiGateSuperSecretToken2026"

tail -Fn0 "$LOG_FILE" | while read -r line; do
    EVENT=$(echo "$line" | grep -o '"eventid":"[^"]*' | cut -d'"' -f4)
    if [ "$EVENT" = "cowrie.login.failed" ] || [ "$EVENT" = "cowrie.login.success" ]; then
        ATTACKER_IP=$(echo "$line" | grep -o '"src_ip":"[^"]*' | cut -d'"' -f4)
        echo "[!] Rogue access detected from: $ATTACKER_IP. Dispatching quarantine webhook..."
        curl -k -X POST "$FGT_URL" \
             -H "Content-Type: application/json" \
             -H "Authorization: Bearer $TOKEN" \
             -d "{\"srcip\":\"$ATTACKER_IP\",\"event\":\"$EVENT\"}"
    fi
done

```


2. Mark the watcher script executable and start it in the background:
```sh
chmod +x /opt/honeypot-quarantine/scripts/webhook-watcher.sh
nohup /opt/honeypot-quarantine/scripts/webhook-watcher.sh > /opt/honeypot-quarantine/scripts/watcher.log 2>&1 &

```



---

### Step 3: Verify the Basic Trigger Loop

1. Generate an unauthorized authentication attempt from Kali Linux (`192.168.40.3`):
```bash
ssh -o StrictHostKeyChecking=no -p 2222 testuser@192.168.40.1

```


2. Verify watcher log output on Alpine:
```sh
cat /opt/honeypot-quarantine/scripts/watcher.log

```


3. Verify quarantine enforcement on FortiOS:
```fortios
diagnose user quarantine list

```



```



```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-c.md -->
# Stage 5C: Advanced Configuration - Fabric-Wide Telemetry & SOC Dispatch

Tier C completes the enterprise integration loop by adding real-time Syslog telemetry, ChatOps incident notifications, and automatic forensic session extraction.

---

### 1. Dual-Action Automation Architecture
When an attacker breaches the deception boundary:
1. **Primary Action:** FortiOS drops all Layer 3 sessions from the offending IP.
2. **Secondary Action:** Alpine Linux uploads terminal playback logs (`.tty`) to centralized forensic storage.
3. **Tertiary Action:** Alpine formats a ChatOps card and delivers an instant alert to the SOC webhook.

---

### 2. Mattermost/Slack ChatOps Notification Payload
The triage engine expands to push an incident card upon trigger:

```json
{
  "username": "FortiGate Honeypot Fabric",
  "icon_emoji": ":shield:",
  "attachments": [
    {
      "color": "#ee2737",
      "title": "CRITICAL: Layer 3 Perimeter Quarantine Activated",
      "fields": [
        {
          "title": "Attacker IP",
          "value": "192.168.40.3",
          "short": true
        },
        {
          "title": "Target VIP",
          "value": "192.168.40.1:2222",
          "short": true
        },
        {
          "title": "Trigger Reason",
          "value": "High-risk user probe: root",
          "short": false
        },
        {
          "title": "Firewall Action",
          "value": "Kernel Quarantine (Drop Table) Enforced",
          "short": false
        }
      ]
    }
  ]
}

```

---

### 3. Cowrie TTY Forensics Extraction

To inspect recorded attacker keystrokes and session inputs after isolation:

1. Identify the session ID from `/cowrie/cowrie-git/var/log/cowrie/cowrie.json`.
2. Locate the corresponding session record inside `/cowrie/cowrie-git/var/lib/cowrie/tty/`.
3. Replay the attacker's interactive session inside the Docker container:
```sh
docker exec -it cowrie-honeypot playlog /cowrie/cowrie-git/var/lib/cowrie/tty/<session_id>.log

```



```

---

All Stage 5 application configuration files and multi-tiered implementation guides are generated.

Wait for the explicit exit trigger before advancing to Stage 6:
`"I am done with Stage 5"`

```
