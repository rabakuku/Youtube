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
FGT_URL="https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine"
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
