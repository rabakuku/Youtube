Here is the complete Master Documentation Hub. This stage consolidates the entire technical deployment into your final production manuals and prepares the front page for your repository, as featured on `@ccnadailytips`.

When working within your **Fortinet Lab in Eve-NG**, ensure that you unlock the workspace by pressing the red “Unlock Lab” button, as a locked lab restricts all operational changes. If you are utilizing the countdown timer, remember that stopping it via the unlock button does not stop the nodes or disconnect active sessions. You can also track your deployment progress by creating items in the “Lab Task(s)” sidebar.

```markdown
<!-- filepath: docs/main.md -->
# Fortinet Visual SOC Lab - Master Technical Manual

## 1. Alpine Linux & Docker Initialization
Provision the container runtime environment on Alpine Linux 3.24 (Node 2 - `192.168.10.2`).

```bash
# Update local package repositories
apk update && apk upgrade

# Install Docker engine, Compose plugin, and OpenRC
apk add docker docker-cli-compose openrc

# Assign user to the docker group to prevent socket permission errors
addgroup root docker

# Register Docker to the boot runlevel for persistence across reboots
rc-update add docker boot

# Start the Docker daemon immediately
rc-service docker start

```

## 2. Container Compose Architecture

Deploy the multi-container SIEM stack. The architecture relies on Vector for high-speed syslog ingestion, Loki for low-overhead indexed storage, and Grafana for the visual wallboard.

**File:** `compose/docker-compose.yml`

```yaml
services:
  vector:
    image: timberio/vector:0.36.0-alpine
    container_name: soc-vector
    restart: unless-stopped
    ports:
      - "514:514/udp" # FortiGate Syslog Ingestion Port
    volumes:
      - ./vector/vector.yaml:/etc/vector/vector.yaml:ro
      - vector_data:/var/lib/vector
    environment:
      - VECTOR_ENVIRONMENT=${VECTOR_ENVIRONMENT:-production}
    depends_on:
      - loki
    networks:
      - soc_net

  loki:
    image: grafana/loki:2.9.4
    container_name: soc-loki
    restart: unless-stopped
    ports:
      - "3100:3100"
    volumes:
      - ./loki/local-config.yaml:/etc/loki/local-config.yaml:ro
      - loki_data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - soc_net

  grafana:
    image: grafana/grafana:10.3.3
    container_name: soc-grafana
    restart: unless-stopped
    ports:
      - "80:3000" # Web GUI bound to host port 80
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-FortinetLab2026!}
      - GF_USERS_ALLOW_SIGN_UP=false
    depends_on:
      - loki
    networks:
      - soc_net

volumes:
  vector_data:
    driver: local
  loki_data:
    driver: local
  grafana_data:
    driver: local

networks:
  soc_net:
    driver: bridge

```

**File:** `compose/.env.example`

```env
# -----------------------------------------------------------------------------
# Fortinet Visual SOC Lab - Environment Variables
# -----------------------------------------------------------------------------
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=VisualSocAdmin2026!
VECTOR_ENVIRONMENT=production
LOKI_RETENTION_PERIOD=168h

```

## 3. SIEM Data Pipeline Configuration

Establish the internal data routing, indexing, and storage behavior for the SIEM stack.

**File:** `compose/vector/vector.yaml`

```yaml
sources:
  fortigate_syslog:
    type: "syslog"
    address: "0.0.0.0:514"
    mode: "udp"

transforms:
  fortigate_parser:
    type: "remap"
    inputs:
      - "fortigate_syslog"
    source: |
      . = parse_key_value!(.message)
      .timestamp = now()

sinks:
  loki_destination:
    type: "loki"
    inputs:
      - "fortigate_parser"
    endpoint: "http://soc-loki:3100"
    encoding:
      codec: "json"
    labels:
      source: "fortigate"
      type: "syslog"
      action: "{{action}}"

```

**File:** `compose/loki/local-config.yaml`

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 1h
  max_chunk_age: 1h
  chunk_target_size: 1048576
  chunk_retain_period: 30s

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /loki/boltdb-shipper-active
    cache_location: /loki/boltdb-shipper-cache
    cache_ttl: 24h
    shared_store: filesystem
  filesystem:
    directory: /loki/chunks

compactor:
  working_directory: /loki/boltdb-shipper-compactor
  shared_store: filesystem

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h

```

**File:** `compose/grafana/provisioning/datasources/loki.yaml`

```yaml
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://soc-loki:3100
    isDefault: true
    version: 1
    editable: false

```

```

```markdown
<!-- filepath: README.md -->
# Zero-Cost Visual SOC: FortiOS SIEM Analytics Dashboard

![FortiOS](https://img.shields.io/badge/FortiOS-7.4-EE2737?style=for-the-badge&logo=fortinet&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine_Linux-3.24-0D597F?style=for-the-badge&logo=alpine-linux&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-10.3-F46800?style=for-the-badge&logo=grafana&logoColor=white)

## 📌 Executive Summary
This repository contains the complete automation and configuration stack to build a real-time, zero-cost Security Operations Center (SOC) dashboard. By streaming raw FortiOS 7.4 syslogs into a lightweight, containerized Vector, Loki, and Grafana stack, this lab visualizes geo-IP threat origins, bandwidth hogs, and blocked attacks in real-time. 

## 🏗️ Architectural Topology

```text
       [ VLAN 40: Attack Generation ]
                   |
             (192.168.40.3)
             Kali Linux Node
                   |
                   ▼
  +-----------------------------------+
  |       FortiGate NGFW (VM)         |
  |  (192.168.40.1 / 192.168.10.1)    |
  |    (port2 802.1Q Trunked L3)      |
  +-----------------------------------+
                   |   (Syslog UDP 514 / Dashboard TCP 80)
                   ▼
       [ VLAN 10: SIEM Enclave ]
                   |
             (192.168.10.2)
           Alpine Linux 3.24
                   |
      +-------------------------+
      |      Docker Bridge      |
      | - Vector (Log Router)   |
      | - Loki (Index Storage)  |
      | - Grafana (Visual GUI)  |
      +-------------------------+

```

## 🚀 Quickstart Deployment

1. **Verify Lab State:** Ensure your environment is active. If using an EVE-NG environment, confirm the lab is unlocked prior to executing setup tasks.


2. **Clone and Execute:**
Run the following on your Alpine Linux host (`192.168.10.2`):
```bash
git clone [https://github.com/rabakuku/Youtube.git](https://github.com/rabakuku/Youtube.git)
cd Youtube/Video-3-Visual-SOC-Analytics-Traffic-Dashboard
chmod +x scripts/setup.sh
./scripts/setup.sh

```


3. **Access the Dashboard:**
Navigate to `http://192.168.10.2` from your Kali client or any device on the routed network. The default credentials are defined in `compose/.env.example`.

## 🧹 Complete Teardown

To cleanly spin down the environment, wipe local volumes, and prune the bridged network without leaving orphan data:

```bash
chmod +x scripts/rollback.sh
./scripts/rollback.sh

```

```

Once you have secured these deliverables, reply exactly with:
**"I am done with Stage 7"**

```
