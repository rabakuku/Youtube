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

*The script verifies Docker Engine prerequisites, auto-generates a 32-character hexadecimal encryption key in `.env`, pulls official container images, maps container port `5678` to host port `80`, and waits for PostgreSQL health convergence.*
---

### Step-by-Step Terminal Execution Guide

Execute these steps on the Alpine host (`192.168.10.2`) as `soaradmin`:

1. **Create the compose directory and enter it:**
```sh
mkdir -p ~/soar-stack/compose && cd ~/soar-stack/compose

```


*Creates an isolated working directory for the application configuration and enters it.*
2. **Save the configuration files:**
Paste the two deliverables above into `docker-compose.yml` and `.env.example`. Then generate your live `.env` from the example:
```sh
cp .env.example .env

```


*Duplicates the template to provide active runtime variable definitions for the Compose runtime.*
3. **Generate a random encryption key and inject it:**
```sh
HEX_KEY=$(head -c 16 /dev/urandom | xxd -p)
sed -i "s/replace_with_a_secure_32_character_hex_encryption_key_here/$HEX_KEY/" .env

```


*Creates a cryptographic seed value required by n8n to encrypt stored REST API tokens on disk.*
4. **Launch the container pipeline in the background:**
```sh
docker compose up -d

```


*Pulls the PostgreSQL and n8n images, builds the bridge network, initializes the database, and maps container port 5678 to host port 80.*

---

### Zero-Trust Verification Blocker (Stage 3)

Execute the following commands directly on Node 2 (`192.168.10.2`) and Node 3 (`192.168.10.3`):

#### 1. Container Status & Health Check (Alpine - Node 2)

```sh
cd ~/soar-stack/compose
docker compose ps

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

When all four checks pass, reply with:

`"I am done with Stage 3"`
