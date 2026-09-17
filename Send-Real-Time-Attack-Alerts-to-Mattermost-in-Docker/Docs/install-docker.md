### Alpine Linux Base & Docker Engine Setup

Configure the Alpine Linux host (`192.168.10.2/24`) to serve as the hardened container host for the Mattermost webhook alert architecture.

Execute these sequential commands in your Alpine terminal:

```bash
apk update

```

This updates the local package index against the remote Alpine repositories to ensure package resolution pulls the latest versions and dependency trees.

```bash
sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories

```

This uncomment command enables the official Alpine `community` repository in `/etc/apk/repositories`, which is required to install Docker and its associated compose plugins.

```bash
apk update

```

This re-synchronizes the package database so the package manager recognizes packages hosted within the newly enabled community repository.

```bash
apk add --no-cache docker docker-cli-compose containerd

```

This installs the Docker daemon, the Docker Compose CLI plugin, and the Containerd runtime directly without caching index files locally to save disk space.

```bash
addgroup <your_username> docker

```

This appends your unprivileged user to the `docker` system group, granting socket permissions to interact with `/var/run/docker.sock` without requiring `sudo` for every command.

```bash
rc-update add docker boot

```

This registers the Docker OpenRC service into the `boot` runlevel, ensuring the daemon initializes automatically across system reboots.

```bash
rc-service docker start

```

This starts the Docker daemon process immediately under OpenRC supervision.

---

### Implementation Guide Deliverable

```markdown
<!-- filepath: docs/install-docker.md -->
# Docker Engine Installation & Host Hardening on Alpine Linux

This document provides complete, standalone instructions for establishing a production-ready Docker runtime environment on Alpine Linux v3.19/v3.20 within the `192.168.10.0/24` network fabric.

---

## 1. Network Topology Placement
* **Host Role:** Security Automation / Mattermost Webhook Destination
* **IPv4 Address:** `192.168.10.2`
* **Subnet Mask:** `255.255.255.0` (`/24`)
* **Default Gateway:** `192.168.10.1` (FortiGate port2)
* **DNS Resolver:** `192.168.10.1` or enterprise upstream DNS

---

## 2. Prerequisites & Repository Enablement

Alpine Linux ships minimal by default. Docker packages reside within the `community` repository, which must be explicitly un-commented.

1. Verify existing network connectivity to the FortiGate gateway:
   ```bash
   ping -c 3 192.168.10.1

```

2. Enable the Alpine community repository:
```bash
sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories

```


3. Update the package index lists:
```bash
apk update

```



---

## 3. Package Installation

Install the container engine, OpenRC service dependencies, and Compose plugin:

```bash
apk add --no-cache \
    docker \
    docker-cli-compose \
    containerd \
    e2fsprogs \
    iptables \
    curl \
    net-tools

```

* `docker`: Core container engine and server daemon (`dockerd`).
* `docker-cli-compose`: Native Compose V2 integration (`docker compose`).
* `containerd`: Low-level container runtime.
* `iptables`: Required for Docker NAT and bridge network manipulation.
* `curl` & `net-tools`: Networking diagnostics (`netstat`, HTTP inspection).

---

## 4. User Group & Security Configurations

Grant administrative non-root users access to manage containers:

1. Add your standard administrative user to the `docker` and `wheel` groups:
```bash
addgroup <your_username> docker
addgroup <your_username> wheel

```


2. Optional daemon hardening via `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false
}

```


* `live-restore`: Keeps containers alive during Docker daemon updates or restarts.
* `userland-proxy: false`: Minimizes overhead by delegating container traffic forwarding directly to kernel `iptables` rules rather than user-space proxies.



---

## 5. OpenRC Service Management

Alpine Linux uses OpenRC instead of systemd. Manage the daemon state with `rc-update` and `rc-service`:

1. Register Docker to start automatically at boot:
```bash
rc-update add docker boot

```


2. Start the daemon process:
```bash
rc-service docker start

```


3. Confirm runlevel persistence:
```bash
rc-status boot

```


*(Verify `docker` is listed with state `started`)*

---

## 6. Diagnostic Reference Commands

* **Check daemon state:** `rc-service docker status`
* **Restart daemon:** `rc-service docker restart`
* **View system daemon logs:** `cat /var/log/docker.log` or run `rc-service docker status`
* **Verify control socket:** `ls -la /var/run/docker.sock`

```

---

### Zero-Trust Verification Blocker

Do not proceed until you execute and inspect the following diagnostic commands on `192.168.10.2`:

**1. Service Status Check:**
```bash
rc-service docker status

```

*Expected Output:*

```text
 * status: started

```

**2. Engine & Socket Validation:**

```bash
docker info

```

*Expected Output:*
Ensure `Server Version` is reported, `Storage Driver` is active (typically `overlay2`), and the command exits with `0` errors without permission denied failures.

Confirm completion of these steps by replying with:
`I am done with Stage 2`
