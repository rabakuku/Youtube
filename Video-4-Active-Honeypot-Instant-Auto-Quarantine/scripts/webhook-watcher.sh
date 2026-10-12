#!/bin/sh
LOG_FILE="/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
FGT_URL="https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE"
ENV_FILE="/opt/honeypot-quarantine/compose/.env"

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Sourcing FortiGate API token
if [ -f "$ENV_FILE" ]; then
    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi
TOKEN="${TOKEN:-PASTE_YOUR_COPIED_KEY_HERE}"

clear
printf "${CYAN}===============================================================${NC}\n"
printf " 🛡️  ACTIVE DEFENSE ENGINE: COWRIE TO FORTIOS WEBHOOK WATCHER\n"
printf "${CYAN}===============================================================${NC}\n"
printf "${GREEN}[+] Streaming telemetry from: ${LOG_FILE}${NC}\n\n"

tail -Fn0 "$LOG_FILE" | while read -r line; do
    EVENT=$(echo "$line" | grep -o '"eventid":"[^"]*' | cut -d'"' -f4)

    if [ "$EVENT" = "cowrie.login.failed" ] || [ "$EVENT" = "cowrie.login.success" ]; then
        ATTACKER_IP=$(echo "$line" | grep -o '"src_ip":"[^"]*' | cut -d'"' -f4)
        USERNAME=$(echo "$line" | grep -o '"username":"[^"]*' | cut -d'"' -f4)

        printf "${RED}[ ⚠️  CRITICAL BREACH ATTEMPT ]${NC}\n"
        printf "${YELLOW} ├─ Target:  Decoy SSH Service (Port 2222)${NC}\n"
        printf "${YELLOW} ├─ Source:  ${ATTACKER_IP}${NC}\n"
        printf "${YELLOW} └─ Payload: Username '%s'${NC}\n" "$USERNAME"

        printf "${CYAN}[⚡] Dispatching Layer 3 Quarantine Webhook to FortiGate...${NC}\n"

        # Execute Webhook to FortiGate Automation Stitch
        HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -X POST "$FGT_URL" \
             -H "Content-Type: application/json" \
             -H "Authorization: Bearer $TOKEN" \
             -d "{\"srcip\":\"$ATTACKER_IP\",\"event\":\"$EVENT\"}")

        if [ "$HTTP_STATUS" = "200" ]; then
            printf "${GREEN}[✔] API Response (HTTP 200): Fabric Quarantine Enforced. Attacker Isolated.${NC}\n\n"
        else
            printf "${RED}[✖] API Error (HTTP %s): Webhook execution rejected by firewall.${NC}\n\n" "$HTTP_STATUS"
        fi
    fi
done
