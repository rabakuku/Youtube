<!-- filepath: docs/Configuration.md -->
# Container Compose Architecture & Deployment Walkthrough

## 1. Architectural Overview
This phase deploys the core observability and SIEM analytics engine for the Fortinet Zero-Cost Visual SOC. The stack is composed of three interconnected containers running on Alpine Linux (`192.168.10.2`), leveraging a dedicated bridged Docker network (`soc_net`).

*   **Vector (Port 514/UDP):** The ultra-fast, memory-safe data router. It receives raw syslogs directly from the FortiGate VM (`192.168.10.1`), parses the FortiOS key-value pair formatting, enriches the data (GeoIP mapping, threat tagging), and forwards it.
*   **Loki (Port 3100/TCP):** A highly efficient, horizontally scalable log aggregation system inspired by Prometheus. It indexes the enriched logs from Vector based on labels rather than full-text indexing, drastically reducing memory and storage overhead.
*   **Grafana (Port 80/TCP):** The visualization layer. Mapped to host port 80 for seamless HTTP access from the Windows PC (`192.168.10.3`). It queries Loki via LogQL to render live NOC/SOC visual dashboards, bandwidth utilization, and threat geo-mapping.

## 2. Persistent Volumes Strategy
To ensure log data and dashboard configurations survive container restarts and updates, we map specific internal paths to Docker-managed local volumes:

*   `vector_data`: Stores Vector's internal state and buffers, preventing data loss during temporary Loki outages.
*   `loki_data`: Stores the chunked log data and indices. Crucial for retaining historical SIEM data.
*   `grafana_data`: Retains user accounts, imported JSON dashboards, and UI preferences.

*Note: Configuration files (`vector.yaml`, `local-config.yaml`, and Grafana provisioning) are mapped as read-only bind mounts (`:ro`) to ensure immutable infrastructure enforcement.*

## 3. Deployment Walkthrough
Follow these steps on the Alpine Docker Host (`192.168.10.2`) to initialize the stack:

1.  **Prepare the Environment:**
    Navigate to the project root directory and copy the environment template.
    ```bash
    cp compose/.env.example compose/.env
    # Optional: Edit .env to customize GRAFANA_ADMIN_PASSWORD
    ```

2.  **Create Configuration Directories:**
    Before launching, create the required bind mount directories to prevent Docker from auto-creating them as root-owned directories.
    ```bash
    mkdir -p compose/vector compose/loki compose/grafana/provisioning
    ```
    *(Note: The exact configuration files for these directories will be populated in Stage 4).*

3.  **Launch the Stack:**
    Deploy the containers in detached mode.
    ```bash
    cd compose
    docker compose up -d
    ```

## 4. Official Container Documentation Links
For advanced tuning, reference the official upstream documentation:
*   [Vector Documentation](https://vector.dev/docs/)
*   [Grafana Loki Documentation](https://grafana.com/docs/loki/latest/)
*   [Grafana Visualization Documentation](https://grafana.com/docs/grafana/latest/)
