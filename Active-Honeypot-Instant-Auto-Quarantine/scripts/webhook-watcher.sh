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
