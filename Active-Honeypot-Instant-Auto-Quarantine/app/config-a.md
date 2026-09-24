<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-a.md -->
# Stage 5A: Basic Honeypot Webhook Dispatch Walkthrough

This guide establishes the primary detection-to-mitigation pipeline between the Cowrie honeypot container on Alpine Linux (`192.168.10.2`) and the FortiOS Security Fabric (`192.168.10.1`).

---

### Step 1: Verify Cowrie Output Logging
1. Ensure the Cowrie container is running and actively outputting structured JSON logs:
   ```sh
   docker exec -it cowrie-honeypot tail -f /cowrie/cowrie-git/var/log/cowrie/cowrie.json
