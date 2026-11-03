<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/vt.md -->
# Verification & Troubleshooting — Visual SOC Stack (Alpine 3.24, 192.168.10.2)

All commands run as root on the Alpine host from `/opt/visual-soc-analytics-traffic-dashboard/compose` unless a section says otherwise.

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose
```

## 1. Docker engine

```sh
service docker status          # expect: * status: started
docker info --format '{{.ServerVersion}}'
rc-update show default | grep docker   # expect: docker | default
```

## 2. Containers

```sh
docker ps                      # running containers only
docker ps -a                   # includes exited / restarting ones
docker compose ps              # expect 3 rows, STATUS "Up ... (healthy)"
```

Health of each container:

```sh
for c in soc-loki soc-vector soc-grafana; do
  printf '%-12s %s\n' "$c" "$(docker inspect --format '{{.State.Health.Status}}' "$c")"
done
```

Good output: all three print `healthy`. `starting` is normal for the first ~30 s.

## 3. Listeners

```sh
netstat -tulpn | grep -E ':(80|514|3100)\b'
# or, with iproute2 installed (apk add iproute2):
ss -tulpn | grep -E ':(80|443|514|3100)\b'
```

| Expect | Meaning |
|---|---|
| `0.0.0.0:80` TCP, process `docker-proxy` | Grafana wallboard reachable from VLAN 40 |
| `0.0.0.0:514` UDP, process `docker-proxy` | Vector syslog input for the FortiGate |
| `127.0.0.1:3100` TCP | Loki API — host-only debug port, never exposed to the network |

Port 443 is intentionally unused in this lab (HTTP only).

## 4. HTTP checks (on Alpine)

```sh
curl -I http://127.0.0.1                         # expect HTTP/1.1 302 Found → /login
curl -s http://127.0.0.1/api/health              # expect "database": "ok"
curl -s http://127.0.0.1:3100/ready              # expect: ready
curl -s http://127.0.0.1:3100/loki/api/v1/labels # expect: action, log_type, source, verdict (after first logs)
```

## 5. Logs

```sh
docker compose logs --tail=20 -f grafana
docker compose logs --tail=20 -f loki
docker compose logs --tail=20 -f vector
```

Turn on parse-failure messages in Vector:

```sh
sed -i 's/^VECTOR_LOG=.*/VECTOR_LOG=debug/' .env && docker compose up -d vector
docker compose logs -f vector | grep -i unparseable
# revert afterwards: VECTOR_LOG=info
```

## 6. Is FortiGate data arriving?

Raw packets on the wire (`apk add tcpdump` if missing):

```sh
tcpdump -ni eth0 udp port 514 -c 5
```

Logs stored in Loki in the last 5 minutes, by verdict:

```sh
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (verdict) (count_over_time({source="fortigate"}[5m]))'
```

Newest three log lines:

```sh
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={source="fortigate"}' --data-urlencode 'limit=3'
```

## 7. Disk & volumes

```sh
df -h /var/lib/docker
docker system df
docker volume ls | grep visual-soc
docker run --rm -v visual-soc_loki_data:/d alpine du -sh /d
```

Loki keeps 7 days (`LOKI_RETENTION_PERIOD=168h`); the compactor deletes older chunks automatically. Vector's disk buffer can use up to ~256 MiB in `visual-soc_vector_data` while Loki is down.

## 8. From Kali (192.168.40.3)

```sh
curl -I http://192.168.10.2        # expect 302 Found (policy 2 Kali_To_SOC_Web)
curl -m 3 telnet://192.168.10.2:22 # expect timeout (policy 3 deny) — and a red line on the wallboard
```

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `TCP 80 is already in use` from setup.sh | Another web server (lighttpd, nginx) on the host | `netstat -tlnp \| grep ':80 '` → stop it: `rc-service <name> stop; rc-update del <name>` → re-run setup.sh |
| `UDP 514 is already in use` | Alpine's own syslogd listening remotely (`-R`/`-l` options) or rsyslog | `netstat -ulnp \| grep ':514 '` → remove the remote-listen option or `rc-service rsyslog stop` |
| `Cannot connect to the Docker daemon` | Docker service not running | `service docker start`; check `/var/log/docker.log`; `rc-update add docker default` |
| `permission denied` on `/var/run/docker.sock` | Running as a non-root user | Run as root, or `addgroup <user> docker` and log in again |
| `apk update` / image pull fails | Alpine has no internet — FortiGate policy 4 (SOC_To_Internet) missing, or no DNS | `ping -c2 1.1.1.1`, `nslookup registry-1.docker.io`; add policy 4 and set DNS in `/etc/resolv.conf` |
| A container stays `unhealthy` | Wrong config file or Loki still starting | `docker compose logs --tail=50 <svc>`; Loki needs ~15–30 s after "ready" wait; re-run setup.sh to refresh configs |
| Grafana shows "No data" everywhere | No syslog arriving | Section 6: no packets → FortiGate `config log syslogd setting` (server 192.168.10.2, udp, 514); packets but no data → Vector debug logs |
| IPS panels empty, deny panels work | FortiGate IPS package unlicensed/outdated, or no IPS sensor on policy 2 | FortiGate: `diagnose autoupdate versions`; check `set ips-sensor` on policy 2 (Stage 4) |
| Kali cannot open http://192.168.10.2 | No policy 2, wrong address object, or Kali gateway not 192.168.40.1 | FortiGate: `diagnose debug flow` (see Stage 4); Kali: `ip route` |
| Forgot the Grafana password | Generated by setup.sh, printed once | `grep GRAFANA_ADMIN_PASSWORD .env` (changing it later needs `docker compose down -v` or `docker exec -it soc-grafana grafana cli admin reset-admin-password <new>`) |
| Wallboard is not the home page | Old `grafana_data` volume from a previous lab | `docker compose down -v` (deletes data) then `docker compose up -d` |
