```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/vt.md -->
# Verification & Diagnostics: Node 2 (Alpine Docker Host)

Execute the following test sequences directly on **Node 2 (`192.168.10.2`)** to confirm that the Cowrie container is healthy, properly bound to the host network interface, and recording connection events.

---

### 1. Verify Container Runtime Status
Confirm that the `cowrie-honeypot` container is running and healthy.

```sh
docker ps --filter "name=cowrie-honeypot" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

```

*Expected Output:*
The container name `cowrie-honeypot` must show a status of `Up` and port mapping `0.0.0.0:2222->2222/tcp`.

---

### 2. Verify Host Socket Listening State

Verify that Alpine Linux has bound TCP port 2222 to the Docker proxy process.

```sh
ss -tuln | grep -E ':2222'

```

*Expected Output:*

```text
tcp   LISTEN 0      4096         0.0.0.0:2222       0.0.0.0:*
tcp   LISTEN 0      4096            [::]:2222          [::]:*

```

---

### 3. Inspect Live Cowrie Logs

Stream the honeypot startup output and verify the internal SSH listener is initialized.

```sh
docker compose -f /opt/honeypot-quarantine/compose/docker-compose.yml logs --tail=30 cowrie

```

*Expected Output:*
Log entries indicating `Loaded output engine: jsonlog` and `Ready to accept SSH connections on 0.0.0.0:2222`.

---

### 4. Local Deception Loopback Test

Execute a connection attempt directly against the honeypot port from the host terminal.

```sh
ssh -p 2222 root@127.0.0.1

```

*Expected Output:*
A password prompt disguised as an Ubuntu/OpenSSH server (e.g., `root@127.0.0.1's password:`). Enter any fake password and abort with `Ctrl+C`.

Confirm the event was logged to JSON storage:

```sh
docker exec cowrie-honeypot tail -n 5 /cowrie/cowrie-git/var/log/cowrie/cowrie.json

```

```

---

### Zero-Trust Verification Steps (Execute in Chat Before Transition)

Execute the following commands on **Node 2 (`192.168.10.2`)** and inspect the outputs before moving forward:

1. **Verify Docker Daemon & Container State:**
   ```sh
   rc-service docker status
   docker ps -a

```

*Expected Output:* `status: started`, container `cowrie-honeypot` has status `Up`.

2. **Verify Port 2222 Socket State:**
```sh
ss -tulpn | grep ':2222'

```


*Expected Output:* `docker-proxy` listening on port `2222`.

