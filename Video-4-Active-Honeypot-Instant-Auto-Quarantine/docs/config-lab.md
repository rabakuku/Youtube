To support this workflow, the three files currently in your GitHub `scripts/` directory (`webhook-watcher.sh`, `triage_engine.py`, and `active_defense_engine.py`) along with the compose artifacts from Stage 2 are sufficient. No additional files need to be hosted on GitHub because `config-lab.sh` writes the native OpenRC service definitions dynamically into `/etc/init.d/`.


---

### How to Deploy and Verify `config-lab.sh` on Node 2 (Alpine)

1. **Download and grant execution rights:**
```sh
cd /opt/honeypot-quarantine/scripts
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/config-lab.sh -o config-lab.sh
chmod +x config-lab.sh

```


2. **Execute directly via arguments or interactive menu:**
```sh
# Deploy Config-A
./config-lab.sh setup config-a

# Deploy Config-B (automatically decommissions Config-A first)
./config-lab.sh setup config-b

# Deploy Config-C (automatically spins up Mattermost and registers active-defense daemon)
./config-lab.sh setup config-c

# Inspect active profile, open ports, and running daemons
./config-lab.sh status

```


3. **Verify the active tier:**
When you run `./config-lab.sh status`, inspect the final verdict banner:
```text
ACTIVE LAB PROFILE: Config-C (Enterprise ChatOps & TTY Forensics)

```
