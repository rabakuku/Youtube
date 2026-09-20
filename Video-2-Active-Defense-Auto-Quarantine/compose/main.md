```yaml
# filepath: compose/docker-compose.yml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION:-1.80.0}
    container_name: n8n-automation-core
    restart: unless-stopped
    ports:
      - "80:5678"
    environment:
      - N8N_HOST=${N8N_HOST:-192.168.10.2}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL:-http}
      - WEBHOOK_URL=${WEBHOOK_URL:-http://192.168.10.2/}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-UTC}
      - NODE_ENV=production
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n_db}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n_user}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      backend:
        ipv4_address: 172.28.10.10

  postgres:
    image: postgres:${POSTGRES_VERSION:-16-alpine}
    container_name: n8n-postgres-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB:-n8n_db}
      - POSTGRES_USER=${POSTGRES_USER:-n8n_user}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-n8n_user} -d ${POSTGRES_DB:-n8n_db}"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 10s
    networks:
      backend:
        ipv4_address: 172.28.10.11

volumes:
  n8n_data:
    name: n8n_enterprise_data
  postgres_data:
    name: n8n_enterprise_postgres

networks:
  backend:
    name: soar_internal_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.10.0/24
          gateway: 172.28.10.1

```

```env
# filepath: compose/.env.example
# ==============================================================================
# Pipeline & Orchestrator Environment Configuration
# ==============================================================================

# n8n Core Application Settings
N8N_VERSION=1.80.0
N8N_HOST=192.168.10.2
N8N_PROTOCOL=http
WEBHOOK_URL=http://192.168.10.2/
GENERIC_TIMEZONE=UTC
N8N_ENCRYPTION_KEY=replace_with_a_secure_32_character_hex_encryption_key_here

# PostgreSQL Database Backend Configuration
POSTGRES_VERSION=16-alpine
POSTGRES_DB=n8n_db
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=replace_with_a_strong_database_password_xyz789

# FortiGate Target API Credentials (Consumed by SOAR Worker Node)
FGT_HOST=192.168.10.1
FGT_PORT=443
FGT_API_TOKEN=autoquarantine-sec-token-xyz123
FGT_QUARANTINE_GROUP=GRP_ACTIVE_QUARANTINE

```

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
