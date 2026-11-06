<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/vt.md -->
# HoneyWall — verification & troubleshooting (Alpine 192.168.10.2)

Run everything from `/opt/honeywall/compose` unless noted. The fastest overall check is:

```sh
/opt/honeywall/scripts/setup.sh --status
```

## 1. Containers

```sh
docker ps                                   # running containers
docker ps -a                                # includes exited ones (cowrie-fsbuild exits 0 - that is normal)
docker compose ps                           # this project only, with health
docker inspect --format '{{.State.Health.Status}}' honeywall-engine     # healthy
docker inspect --format '{{.State.Health.Status}}' honeywall-cowrie
docker compose logs cowrie-fsbuild          # "... wrote ... with 4 honeytoken file(s)"
```

The standard profile should show these containers:

| Container | Expected state |
|---|---|
| honeywall-cowrie-fsbuild | Exited (0) |
| honeywall-cowrie | healthy |
| honeywall-engine | healthy |
| honeywall-dashboard | healthy |
| honeywall-ntfy | healthy |
| honeywall-decoy-web | healthy |

## 2. Listeners on the host

```sh
ss -tulpn | grep -E ':(22|80|2222|8088|8090|9999)\b'
```

| Port | Service | Reached through |
|---|---|---|
| 22 | Alpine sshd (real management) | WAN VIP 2222 |
| 2222 | Cowrie SSH decoy | Users VIP 192.168.40.1:22 |
| 8088 | Web decoy (Corp Backup Console) | Users VIP 192.168.40.1:80 |
| 80 | HoneyWall dashboard + `/api` | WAN VIP 8080 |
| 8090 | ntfy | WAN VIP 8090 |
| 9999 | Dozzle (full profile) | WAN VIP 9999 |

## 3. Service checks

```sh
curl -sI http://127.0.0.1/ | head -n 1                    # HTTP/1.1 200 OK (dashboard)
curl -s  http://127.0.0.1/api/health; echo                # {"ok": true, "fgt_online": ..., "simulate": ...}
curl -s  http://127.0.0.1/healthz                         # ok
curl -sI http://127.0.0.1:8088/login | grep -i server     # Server: nginx/1.22.1  (web decoy)
curl -s  http://127.0.0.1:8090/v1/health; echo            # {"healthy":true}  (ntfy)
ssh -p 2222 -o PreferredAuthentications=password svc_backup@127.0.0.1   # Summer2026! -> svc_backup@srv-corp-ssh01
curl -s -XPOST http://127.0.0.1/api/test/alert; echo      # test message on the ntfy page
curl -s -XPOST http://127.0.0.1/api/test/llm; echo        # only if LLM_ENABLED=true
```

Rehearsal mode only (`FGT_SIMULATE=true`) — play an act without Kali:

```sh
curl -s -XPOST -d '{"act":"2"}' http://127.0.0.1/api/test/simulate    # 1, 2, 3 or 3b
```

## 4. Logs

```sh
docker compose logs --tail=20 -f engine        # the on-camera log: TRIGGER / QUARANTINE / RELEASE lines
docker compose logs --tail=20 -f cowrie
docker compose logs --tail=20 -f decoy-web
docker compose logs --tail=20 dashboard ntfy
tail -n 5 /var/lib/docker/volumes/honeywall_cowrie-var/_data/log/cowrie/cowrie.json
tail -n 5 /var/lib/docker/volumes/honeywall_decoy-web-log/_data/web.json
```

## 5. Docker daemon, disk and volumes

```sh
service docker status
rc-update show default | grep docker
df -h /var/lib/docker
docker system df
docker volume ls | grep honeywall
docker compose exec engine ls /data/reports    # incident reports (.md + .json)
```

## 6. FortiGate path (after Stage 5)

```sh
curl -sk -H "Authorization: Bearer $(sed -n 's/^FGT_API_TOKEN=//p' .env)" \
  "https://192.168.10.1/api/v2/monitor/system/status?vdom=root" | head -c 300; echo
curl -sk -H "Authorization: Bearer $(sed -n 's/^FGT_API_TOKEN=//p' .env)" \
  "https://192.168.10.1/api/v2/monitor/user/banned?vdom=root"; echo
```

From Kali:

```sh
nc -zv -w 3 192.168.40.1 22 && nc -zv -w 3 192.168.40.1 80
```

## 7. Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| `bind: address already in use` on 80, 2222, 8088 or 8090 | Another service (old lab container, nginx) holds the port | `ss -tulpn \| grep :<port>`; stop it, or `docker ps` and remove the old container. The old Video-4 stack: `docker rm -f $(docker ps -aq --filter name=cowrie)` |
| `Cannot connect to the Docker daemon` | Docker isn't running | `service docker start && rc-update add docker default` |
| `permission denied` running scripts or docker | Not root, or the script isn't executable | Run as root (`doas`/`su`); `chmod +x scripts/*.sh` |
| `pull access denied` / `manifest unknown` | No internet from Alpine, or a wrong image tag | `curl -sI https://registry-1.docker.io/v2/`; check the `*_IMAGE` tags in `.env`; FortiGate `SERVERS TO WAN` policy |
| `honeywall-engine` unhealthy | Python error, or `.env` syntax | `docker compose logs --tail=50 engine` |
| `honeywall-cowrie` unhealthy | Bad `cowrie.cfg`, or the fsbuild failed | `docker compose logs cowrie-fsbuild cowrie` |
| Dashboard pill says *FortiGate unreachable* | Token not set, wrong trusthost or profile, or HTTPS not allowed on VLAN_QC_10 | Check section 6 above. Stage 5 `trusthost 192.168.10.2/32`; `set allowaccess ping https` on VLAN_QC_10 |
| Dashboard pill says *Simulation mode* | `FGT_SIMULATE=true` | `./setup.sh --simulate off` after Stage 5 |
| Kali: `192.168.40.1:22` or `:80` times out (not banned) | VIPs or policies missing; `ssh`/`http` still in VLAN_QC_40 allowaccess | Stage 5 VIP + policy; `set allowaccess ping https` on VLAN_QC_40 |
| Kali: times out right after an act | It's banned — working as designed | Click **Unban** on HoneyWall, then `./kali-attack-campaign.sh --reset-check` |
| Events from Kali show source 172.28.10.1 | Docker's userland proxy rewrote the source | Make sure traffic arrives on the host IP, not `localhost`; `dockerd` defaults keep the source IP for external traffic |
| No ban, though the rule fired | Token lacks permission, or the IP is in `NEVER_BAN` | `docker compose logs engine \| grep -E 'FORTIGATE\|guard'` |
| Siren silent | Browsers need one click before audio | Click anywhere on the dashboard (the "arm the siren" button) |
| Old files after `--update` | GitHub raw cache | Wait ~5 minutes after publishing, then rerun |
