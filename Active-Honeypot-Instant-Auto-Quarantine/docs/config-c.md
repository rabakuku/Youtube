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


