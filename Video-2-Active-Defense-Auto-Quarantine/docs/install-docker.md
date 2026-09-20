```markdown
<!-- filepath: docs/install-docker.md -->
# Alpine Linux 3.24 Base & Docker Engine Provisioning Guide

This guide details the complete provisioning process to prepare an Alpine Linux 3.24 node (`192.168.10.2`) as a production-grade Docker container host managed via OpenRC.

---

## 1. Prerequisites & System Validation

Ensure your Alpine instance has an active default route through the FortiGate gateway (`192.168.10.1`), functional DNS resolution, and synchronized system time before pulling upstream packages.

### Verify Network & Time Synchronization
```sh
ip route show
ping -c 3 1.1.1.1
chronyc tracking || ntpd -d -q -n -p pool.ntp.org

```

---

## 2. Package Repository Configuration

Alpine Linux separates official packages into `main` and `community` branches. Docker and `docker-cli-compose` reside in the `community` repository.

### Enable the Community Repository

Edit `/etc/apk/repositories` to ensure the repository mirror is active:

```sh
sed -i 's/^#\(.*\/community\)$/\1/' /etc/apk/repositories

```

Alternatively, append the repository path matching your current release branch:

```sh
echo "[https://dl-cdn.alpinelinux.org/alpine/v3.24/community](https://dl-cdn.alpinelinux.org/alpine/v3.24/community)" >> /etc/apk/repositories

```

Update local package indexes:

```sh
apk update

```

---

## 3. Package Installation

Install Docker Engine, the CLI interface, the Compose plugin, and prerequisite networking and core utilities.

```sh
apk add --no-cache \
    docker \
    docker-cli \
    docker-cli-compose \
    e2fsprogs \
    iptables \
    ip6tables \
    ca-certificates \
    curl \
    sudo

```

* `docker`, `docker-cli`, `docker-cli-compose`: Core daemon, CLI, and multi-container orchestration plugin.
* `iptables`, `ip6tables`: Required by the Docker daemon to configure container bridge NAT and host forwarding rules.
* `ca-certificates`, `curl`: Required for encrypted TLS communication and payload testing.

---

## 4. Kernel Modules & Sysctl Forwarding

Docker requires IPv4 packet forwarding and bridge netfilter support to manage bridge traffic and interface with the physical LAN.

### Load Kernel Modules

```sh
modprobe bridge
modprobe br_netfilter

cat <<EOF> /etc/modules-load.d/docker.conf
bridge
br_netfilter
EOF

```

### Enable IPv4 Forwarding

Enable packet routing across host interfaces:

```sh
cat <<EOF> /etc/sysctl.d/docker.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl -p /etc/sysctl.d/docker.conf

```

---

## 5. User Account & Permissions Management

To manage Docker securely without operating exclusively as `root`, assign an administrative user to the `wheel` and `docker` groups.

### Create Non-Root Automation User

```sh
adduser -s /bin/sh -D soaradmin
echo "soaradmin:ChangeMeSecurePass123!" | chpasswd

```

### Configure Group Memberships

Grant `soaradmin` access to the Docker UNIX socket and administrative execution via `sudo`:

```sh
addgroup soaradmin docker
addgroup soaradmin wheel

echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

```

---

## 6. OpenRC Service Configuration & Startup

Alpine uses OpenRC rather than Systemd. Configure the Docker daemon to automatically start during system boot.

### Register Docker with the Default Runlevel

```sh
rc-update add docker default

```

### Start the Docker Daemon

```sh
rc-service docker start

```

---

## 7. Socket Verification & Base Smoke Test

Confirm that the UNIX domain socket is available and that rootless group execution succeeds:

```sh
# Verify the daemon status
rc-service docker status

# Execute smoke test as non-root user
su - soaradmin -c "docker run --rm hello-world"

```

```

---

### Step-by-Step Terminal Execution Guide

Execute the following commands sequentially on the Alpine host (`192.168.10.2`) as `root`:

1. **Update package index repositories:**
   ```sh
   sed -i 's/^#\(.*\/community\)$/\1/' /etc/apk/repositories && apk update

```

*Enables the community repository branch containing Docker and pulls the current package metadata lists.*

2. **Install Docker Engine and the Compose runtime plugin:**
```sh
apk add --no-cache docker docker-cli docker-cli-compose iptables curl sudo

```


*Installs the container runtime, Docker Compose CLI v2 plugin, and packet filtering dependencies needed for container networking.*
3. **Configure system networking and packet routing parameters:**
```sh
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/docker.conf && sysctl -p /etc/sysctl.d/docker.conf

```


*Enables kernel-level IPv4 packet forwarding so traffic can route cleanly between the physical `eth0` interface and internal Docker bridge networks.*
4. **Register the Docker daemon with the OpenRC boot system:**
```sh
rc-update add docker default

```


*Configures the Docker init script to launch automatically during the system boot sequence.*
5. **Start the Docker engine service:**
```sh
rc-service docker start

```


*Initializes the daemon process, mounts containerd namespaces, and instantiates the `/var/run/docker.sock` UNIX socket.*
6. **Create an operations user and assign group access:**
```sh
adduser -s /bin/sh -D soaradmin && addgroup soaradmin docker

```


*Creates a dedicated operational user and grants read/write permissions to the Docker socket group without requiring interactive root escalation.*

---

### Zero-Trust Verification Blocker (Stage 2)

Before advancing to Stage 3, execute these validation commands directly on Node 2 (`192.168.10.2`):

#### 1. OpenRC Service State

```sh
rc-service docker status

```

*Expected Output:*
The output must report `status: started`.

#### 2. Docker Engine & Socket Integrity

```sh
su - soaradmin -c "docker info"

```

*Expected Output:*
The output must display the active Docker server version, storage driver (`overlay2`), and show zero socket connectivity errors.


