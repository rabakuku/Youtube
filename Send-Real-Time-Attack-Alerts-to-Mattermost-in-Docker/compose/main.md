### Container Compose Architecture

Deploy the Mattermost collaboration platform and dedicated PostgreSQL backend container on the Alpine Linux host (`192.168.10.2`), binding the application listener directly to host port `80`.

```yaml
# filepath: compose/docker-compose.yml
services:
  postgres:
    image: postgres:15-alpine
    container_name: mattermost-postgres
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 100
    read_only: false
    tmpfs:
      - /tmp
      - /var/run/postgresql
    volumes:
      - mattermost_db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    networks:
      backend_net:
        ipv4_address: 172.28.0.10
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost-app
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - mattermost_app_config:/mattermost/config
      - mattermost_app_data:/mattermost/data
      - mattermost_app_logs:/mattermost/logs
      - mattermost_app_plugins:/mattermost/plugins
      - mattermost_app_client_plugins:/mattermost/client/plugins
      - mattermost_app_bleve:/mattermost/bleve-indexes
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable&connect_timeout=10
      MM_SERVICESETTINGS_SITEURL: ${MM_SITE_URL}
      MM_SERVICESETTINGS_LISTENADDRESS: :8065
      MM_FILESETTINGS_DRIVERNAME: local
      MM_FILESETTINGS_DIRECTORY: /mattermost/data/
      MM_LOGSETTINGS_CONSOLELEVEL: INFO
      MM_LOGSETTINGS_ENABLECONSOLE: "true"
    ports:
      - "80:8065"
    networks:
      backend_net:
        ipv4_address: 172.28.0.20
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8065/api/v4/system/ping || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

volumes:
  mattermost_db_data:
    name: mattermost_db_data
  mattermost_app_config:
    name: mattermost_app_config
  mattermost_app_data:
    name: mattermost_app_data
  mattermost_app_logs:
    name: mattermost_app_logs
  mattermost_app_plugins:
    name: mattermost_app_plugins
  mattermost_app_client_plugins:
    name: mattermost_app_client_plugins
  mattermost_app_bleve:
    name: mattermost_app_bleve

networks:
  backend_net:
    name: mattermost_backend_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/24
          gateway: 172.28.0.1

```

```bash
# filepath: compose/.env.example
# ==============================================================================
# Database Configuration (PostgreSQL)
# ==============================================================================
POSTGRES_DB=mattermost
POSTGRES_USER=mmuser
POSTGRES_PASSWORD=SecurePassword_ChangeMe_19216810!

# ==============================================================================
# Mattermost Server Configuration
# ==============================================================================
# Site URL accessible across the 192.168.10.0/24 subnet and FortiGate VIP
MM_SITE_URL=http://192.168.10.2

# Mattermost Port Mapping (Bound to Host Port 80)
APP_PORT=80

```

```markdown
<!-- filepath: docs/Configuration.md -->
# Container Compose Architecture & Deployment Guide

This document details the deployment, volume persistence, and network topology for running Mattermost and PostgreSQL inside Docker on Alpine Linux (`192.168.10.2`).

---

## 1. Network & Port Mapping Schema

The container infrastructure uses an isolated Docker bridge network (`172.28.0.0/24`) for inter-service communication while exposing the Mattermost HTTP listener directly on the host interface.

* **Alpine Host IP:** `192.168.10.2`
* **Host Port Exposure:** Port `80` (HTTP) mapped to container internal port `8065`
* **Internal Docker Subnet:** `172.28.0.0/24`
* **PostgreSQL Address:** `172.28.0.10:5432` (Unexposed to host network)
* **Mattermost App Address:** `172.28.0.20:8065`

---

## 2. Persistent Storage Architecture

All stateful data is isolated to named volumes managed by the Docker storage driver:

* `mattermost_db_data`: Stores PostgreSQL transaction logs, user tables, and channel message histories.
* `mattermost_app_config`: Holds `config.json` containing runtime application settings.
* `mattermost_app_data`: Local storage driver directory for user-uploaded payloads and assets.
* `mattermost_app_logs`: Application error and access log outputs.
* `mattermost_app_plugins`: Installed integrations and webhook handlers.
* `mattermost_app_client_plugins`: Compiled web client plugin artifacts.
* `mattermost_app_bleve`: Fast local file and text indexing data.

---

## 3. Step-by-Step Deployment

1. Create directory structure on the Alpine host:
   ```bash
   mkdir -p /opt/mattermost-stack/compose
   cd /opt/mattermost-stack/compose

```

2. Populate the `.env` configuration file:
```bash
cp .env.example .env

```


3. Initialize the stack in detached mode:
```bash
docker compose -f docker-compose.yml up -d

```



---

## 4. Upstream Documentation References

* [Mattermost Team Edition Deployment Documentation](https://docs.mattermost.com/install/install-docker.html)
* [PostgreSQL Official Docker Library](https://hub.docker.com/_/postgres)
* [Docker Compose Specification](https://docs.docker.com/compose/compose-file/)

```

---

### Zero-Trust Verification Blocker

Before transitioning to Stage 4, execute the following operational checks directly on your hosts:

**1. Service Health & Status Verification (on Alpine `192.168.10.2`):**
```bash
docker compose ps

```

*Requirement:* Ensure both `mattermost-postgres` and `mattermost-app` show status `Up (healthy)`.

**2. Application Stream Logs (on Alpine `192.168.10.2`):**

```bash
docker compose logs --tail=50 -f

```

*Requirement:* Verify PostgreSQL reports `database system is ready to accept connections` and Mattermost reports `Starting Server...` without database connectivity errors. Press `Ctrl+C` to exit.

**3. Port Listener Validation (on Alpine `192.168.10.2`):**

```bash
netstat -tuln | grep :80

```

*Requirement:* Confirm that `0.0.0.0:80` (or `:::80`) is in state `LISTEN` by `docker-proxy`.

**4. End-to-End Subnet Connectivity (from Windows Client `192.168.10.3`):**
Open PowerShell or Command Prompt on `192.168.10.3` and execute:

```powershell
curl.exe -I http://192.168.10.2:80

```

*Requirement:* Verify an HTTP `200 OK` or `302 Found` response header is returned from the Mattermost server.
