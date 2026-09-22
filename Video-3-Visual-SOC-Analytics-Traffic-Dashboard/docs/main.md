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
4. **Subnet HTTP Test (From Windows PC):**
Open PowerShell on `192.168.10.3` and test the Grafana binding:
```powershell
Invoke-WebRequest -Uri http://192.168.10.2 -UseBasicParsing

```


*You should receive a `200 OK` response with Grafana HTML content.*
