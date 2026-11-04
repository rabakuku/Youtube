<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/vt.md -->
# Verification & Troubleshooting — Visual SOC Stack (Alpine 3.24, 192.168.10.2)

All commands run as root on the Alpine host from the compose folder unless a section says otherwise:

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose
```

## 1. Docker engine

```sh
service docker status                     # * status: started
docker info --format '{{.ServerVersion}}'
rc-update show default | grep docker      # docker | default
```

## 2. Containers

```sh
docker compose ps                         # 5 rows, all "(healthy)"
for c in soc-loki soc-vector soc-grafana soc-ntfy soc-responder; do
  printf '%-14s %s\n' "$c" "$(docker inspect --format '{{.State.Health.Status}}' "$c")"
done
docker network inspect soc_net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # 10.89.0.0/24
```

`starting` is normal for the first ~30 s. The subnet must be `10.89.0.0/24` — anything in 172.24.x.x collides with the FortiGate WAN and breaks the VIPs.

## 3. Listeners

```sh
netstat -tulpn | grep -E ':(80|514|3100|8090|8091|8092)\b'
```

| Expect | Meaning |
|---|---|
| `0.0.0.0:80` tcp | Grafana (VIP 172.24.66.52:8080, and Kali via policy) |
| `0.0.0.0:514` udp | Vector syslog input |
| `127.0.0.1:3100` tcp | Loki — host-only debug port |
| `0.0.0.0:8090` tcp | ntfy (VIP 172.24.66.52:8090) |
| `0.0.0.0:8091` tcp | Responder button links (VIP 172.24.66.52:8091) |
| **no** `:8092` | Correct: the Grafana webhook port exists only inside soc_net |

## 4. HTTP checks (on Alpine)

```sh
curl -I http://127.0.0.1                          # HTTP/1.1 302 Found → /login
curl -s http://127.0.0.1/api/health               # "database": "ok"
curl -s http://127.0.0.1:3100/ready               # ready
curl -s http://127.0.0.1:8090/v1/health           # {"healthy":true}
curl -s http://127.0.0.1:8091/health              # {"ok": true, "dry_run": ..., "mode": "approve", ...}
```

## 5. Responder

Current settings and state:

```sh
grep -E '^(QUARANTINE_|PUBLIC_|FGT_HOST|FGT_QUARANTINE_GROUP|NTFY_TOPIC)' .env
curl -s http://127.0.0.1:8091/health              # dry_run, mode, quarantined[], pending[]
docker compose logs --tail=30 responder
```

`"dry_run": true` means no FortiGate token is stored — everything works except the FortiGate change. After Stage 4:

```sh
(cd /opt/visual-soc-analytics-traffic-dashboard && ./setup.sh --fgt-token <TOKEN>)
```

Test the token by hand (expect `200` once the group exists, `404` before Stage 4):

```sh
. ./.env 2>/dev/null; curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $FGT_API_TOKEN" \
  "https://$FGT_HOST/api/v2/cmdb/firewall/addrgrp/$FGT_QUARANTINE_GROUP?vdom=$FGT_VDOM"
```

Fire a fake alert at the responder from inside soc_net (shows the full approval flow in ntfy without attacking anything):

```sh
docker exec soc-responder wget -q -O- --header 'Content-Type: application/json' --post-data \
 '{"alerts":[{"status":"firing","labels":{"alertname":"Port scan detected","srcip":"192.168.40.3","severity":"high"},"annotations":{"description":"Manual test alert"}}]}' \
 http://127.0.0.1:8092/grafana
```

Release everything at once (also done automatically by `rollback.sh`):

```sh
docker exec soc-responder wget -q -O- --post-data='' http://127.0.0.1:8092/release-all
```

## 6. ntfy

On the admin PC open `http://172.24.66.52:8090/<NTFY_TOPIC>` (topic from `.env`), click **Subscribe**, allow browser notifications. Then on Alpine:

```sh
. ./.env; curl -s -H "Title: ntfy test" -d "Hello from Alpine" "http://127.0.0.1:8090/$NTFY_TOPIC"
```

## 7. Is FortiGate data arriving?

```sh
tcpdump -ni eth0 udp port 514 -c 5        # apk add tcpdump if missing
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (verdict) (count_over_time({source="fortigate"}[5m]))'
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (event) (count_over_time({source="responder"}[1h]))'   # responder audit
```

## 8. Logs, disk, kernel buffer

```sh
docker compose logs --tail=20 -f grafana        # also: loki, vector, ntfy, responder
cat /proc/sys/net/core/rmem_max                 # 8388608
df -h /var/lib/docker; docker system df
```

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Port 80/8090/8091 ... already in use` | Another service on the host | `netstat -tlnp \| grep ':<port> '` → stop it → re-run setup.sh |
| `UDP 514 is already in use` | Alpine syslogd/rsyslog listening remotely | Remove the remote-listen option or stop rsyslog |
| `Cannot connect to the Docker daemon` | Docker not running | `service docker start`; `rc-update add docker default` |
| `apk update` / image pull fails | No internet from SERVERS | FortiGate policy `SERVERS TO WAN`; DNS in `/etc/resolv.conf` |
| A container stays `unhealthy` | Config error or slow start | `docker compose logs --tail=50 <svc>`; re-run setup.sh |
| soc_net shows 172.x.x.x subnet | Created by an older version | Re-run setup.sh (it recreates soc_net, volumes kept) |
| Grafana "No data" everywhere | No syslog arriving | Section 7; FortiGate `get log syslogd setting` |
| Grafana panels show `429 too many outstanding requests` | Old Loki config | Re-run setup.sh (refreshes `loki/local-config.yaml` and restarts) |
| Alert fires in Grafana, nothing in ntfy | Contact point not provisioned, or wrong topic | Grafana → Alerting → Contact points shows **soc-responder**; `docker compose logs responder`; topic in browser = `NTFY_TOPIC` |
| Buttons do nothing in the ntfy web app | Admin PC cannot reach 172.24.66.52:8091, or wrong `PUBLIC_RESPONDER_URL` | Open `http://172.24.66.52:8091/health` on the PC; VIP RESPONDER-TO-SOC in policy VIP TO INTERNAL |
| "Link not valid: link expired / already used" | Links live 30 min and work once | Wait for the next alert, or raise `LINK_TTL_SECONDS` |
| "Quarantine FAILED … HTTP 401/403" | Token wrong, trusthost or profile | Stage 4 API-user section; `./setup.sh --fgt-token <TOKEN>` |
| "Quarantine FAILED … cannot read group" | Group SOC-Quarantine missing | Create it (Stage 4) |
| ntfy says quarantined but Kali still connects | Quarantine policy not at the top, or DRY-RUN | `curl -s :8091/health` (dry_run false); FortiGate policy order |
| Forgot the Grafana password | Printed once by setup.sh | `grep GRAFANA_ADMIN_PASSWORD .env` |
