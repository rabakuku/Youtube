---

### Zero-Trust Verification Steps (Execute in Chat Before Transition)

Execute the following commands on **Node 2 (Alpine: `192.168.10.2`)** to verify the configuration syntax and socket readiness prior to generating the automated scripts in Stage 3:

1. **Validate Compose File Syntax:**
```sh
# Verify YAML structure and environment variable interpolation
docker compose --env-file .env.example config

```


*Expected Output:* Fully resolved YAML configuration showing service `cowrie`, port binding `2222:2222`, and network `172.28.10.0/24` with exit code `0`.
2. **Verify Port Availability on Alpine Host:**
```sh
# Ensure host port 2222 is free and not conflicting with host OpenSSH
ss -tuln | grep ':2222'

```


*Expected Output:* No output returned (port 2222 is vacant and ready for container binding).

