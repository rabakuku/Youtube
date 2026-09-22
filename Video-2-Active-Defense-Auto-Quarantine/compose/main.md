## 🚀 Rapid Automated Deployment

### Step 1: Initialize Workspace on the Alpine Host (`192.168.10.2`)
Log into your Alpine Linux host as `root` and retrieve the automated scripts:

```sh
apk add curl
mkdir -p /opt/Active-Defense-Auto-Quarantine && cd /opt/Active-Defense-Auto-Quarantine
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/rollback.sh -o rollback.sh
chmod +x setup.sh rollback.sh
```

### Step 2: Run Automated Idempotent Setup
Execute the deployment script to prepare permissions, environment variables, and Docker containers:

```sh
./setup.sh
```

*Verification standard:* Both `n8n-automation-core` and `n8n-postgres-db` must report a status of `Up`, with `postgres` reporting `(healthy)`.

#### 2. Host Port 80 Listener Verification (Alpine - Node 2)

```sh
ss -tuln | grep :80

```

*Verification standard:* Output must show `LISTEN` on `0.0.0.0:80` and `[::]:80`.

#### 3. Container Initialization Logs (Alpine - Node 2)

```sh
docker compose logs --tail=30 n8n

```

*Verification standard:* The logs must show `Editor is now accessible via: [http://192.168.10.2:80/](http://192.168.10.2:80/)` without runtime exception backtraces.

#### 4. Cross-Subnet Ingress Curl Test (Kali - Node 3)

```bash
curl -I -s http://192.168.10.2:80/ | head -n 5

```

*Verification standard:* Must return `HTTP/1.1 200 OK` (or `HTTP/1.1 302 Found` redirecting to `/setup`).


