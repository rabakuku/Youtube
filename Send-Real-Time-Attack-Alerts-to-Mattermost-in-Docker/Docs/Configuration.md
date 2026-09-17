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
