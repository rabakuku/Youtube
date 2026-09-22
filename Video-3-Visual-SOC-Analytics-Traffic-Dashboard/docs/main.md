### Zero-Trust Verification Blocker

Before proceeding to Stage 4, execute the following commands on your Alpine host (`192.168.10.2`) and Windows PC (`192.168.10.3`) to verify the deployment:

1. **Container Status Check:**
```bash
cd compose
docker compose ps

```


*Ensure `soc-vector`, `soc-loki`, and `soc-grafana` all show a status of "Up".*
2. **Port Listener Validation:**
```bash
netstat -tuln | grep -E ':80|:514'

```


*Verify Alpine is actively listening on `0.0.0.0:80` (TCP) and `0.0.0.0:514` (UDP).*
3. **Container Logs Stream:**
```bash
docker compose logs --tail=20 -f

```


*Check for any immediate fatal crash loops or permission errors.*
4. **Subnet HTTP Test (From Kali):**
Open your terminal on Kali Linux (192.168.40.3) in VLAN 40 and test the routing through the FortiGate gateway (192.168.40.1 -> 192.168.10.2):
```bash
curl -I http://192.168.10.2
```


*You should receive a HTTP/1.1 200 OK or 302 Found response indicating you have successfully reached the Grafana web interface.*
