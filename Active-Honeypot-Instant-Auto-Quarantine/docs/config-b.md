
# Stage 5B: Medium Configuration - In-Memory Triage & Rate Limiting

To prevent accidental quarantines caused by single mistyped passwords or scanning probes, the Tier B pipeline introduces an in-memory triage buffer and high-risk username filters.

---

### 1. Architectural Logic
* **Instant Quarantine:** Any connection attempting credentials with accounts defined in `instant_quarantine_users` (`root`, `admin`, `support`, `ubnt`, `cisco`) bypasses thresholds and triggers immediate quarantine.
* **Brute-Force Rate Limiting:** Routine failed authentications require **3 attempts within 30 seconds** from the same source IP before dispatching the FortiOS webhook.
* **Alert Deduplication:** Once quarantined, subsequent triggers for the same source IP are suppressed for a 300-second cooldown period.

---

### 2. Triage Engine Deployment
Deploy the Python-based lightweight triage script inside Alpine:

1. Create `/opt/honeypot-quarantine/scripts/triage_engine.py`:
   ```python
   #!/usr/bin/env python3
   import json
   import subprocess
   import time
   from collections import defaultdict

   LOG_PATH = "/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
   FGT_WEBHOOK = "[https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine](https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine)"
   TOKEN = "FortiGateSuperSecretToken2026"

   HIGH_RISK_USERS = {"root", "admin", "support", "ubnt", "cisco"}
   FAILED_LOGINS = defaultdict(list)
   QUARANTINED_IPS = {}

   def trigger_quarantine(ip, reason):
       now = time.time()
       if ip in QUARANTINED_IPS and (now - QUARANTINED_IPS[ip]) < 300:
           return
       QUARANTINED_IPS[ip] = now
       print(f"[ACTION] Triggering quarantine for {ip} - Reason: {reason}")
       payload = json.dumps({"srcip": ip, "reason": reason})
       cmd = [
           "curl", "-k", "-s", "-X", "POST", FGT_WEBHOOK,
           "-H", "Content-Type: application/json",
           "-H", f"Authorization: Bearer {TOKEN}",
           "-d", payload
       ]
       subprocess.run(cmd)

   def process_event(event):
       event_id = event.get("eventid")
       ip = event.get("src_ip")
       user = event.get("username", "")

       if not ip or not event_id:
           return

       if user in HIGH_RISK_USERS:
           trigger_quarantine(ip, f"High-risk user probe: {user}")
           return

       if event_id == "cowrie.login.failed":
           now = time.time()
           FAILED_LOGINS[ip] = [t for t in FAILED_LOGINS[ip] if now - t <= 30]
           FAILED_LOGINS[ip].append(now)
           if len(FAILED_LOGINS[ip]) >= 3:
               trigger_quarantine(ip, "Threshold exceeded: 3 failed attempts in 30s")

   def follow():
       with open(LOG_PATH, "r") as f:
           f.seek(0, 2)
           while True:
               line = f.readline()
               if not line:
                   time.sleep(0.5)
                   continue
               try:
                   data = json.loads(line.strip())
                   process_event(data)
               except json.JSONDecodeError:
                   continue

   if __name__ == "__main__":
       follow()

```

2. Run the triage daemon:
```sh
python3 /opt/honeypot-quarantine/scripts/triage_engine.py &

```



