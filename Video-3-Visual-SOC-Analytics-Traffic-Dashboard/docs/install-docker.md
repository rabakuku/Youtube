Because Alpine Linux is an ultra-lightweight distribution, it uses OpenRC instead of systemd for service management. Below is the sequential command execution you need to run on your Alpine host, followed by the official documentation file for your repository.

### Setup Commands & Operational Purpose

`apk update && apk upgrade`
This synchronizes the local package repository with Alpine's upstream servers and upgrades any outdated system packages. It ensures you have the latest security patches and package manifests before installing new software.

`apk add docker docker-cli-compose openrc`
This installs the core Docker engine, the official Docker Compose CLI plugin, and OpenRC. OpenRC is essential because Alpine Linux uses it as its native init system to manage background services.

`addgroup root docker` *(Note: Replace `root` with your username if running a non-root account like `alpine`)*
This assigns your user account to the Docker group, granting the necessary socket permissions to interact with the Docker daemon. It prevents permission denied errors when running container commands.

`rc-update add docker boot`
This registers the Docker daemon to Alpine's boot runlevel. It guarantees that your SIEM containers will automatically start up if the Alpine host in your "Fortinet Lab in Eve-NG" topology is rebooted.

`rc-service docker start`
This immediately initializes and starts the Docker daemon in the current session. It transitions the engine from a stopped state to an active listener, ready to pull and run your SIEM containers.

---

```markdown
<!-- filepath: docs/install-docker.md -->
# Stage 2: Alpine Linux & Docker Base Setup

## 1. Objective
Provision the container runtime environment on Alpine Linux 3.24 (Node 2 - `192.168.10.2`). This host will act as the data processing and visualization engine for the Fortinet Zero-Cost Visual SOC, running the Vector, Loki, and Grafana stack.

## 2. Prerequisites
* Booted Alpine Linux 3.24 instance in your "Fortinet Lab in Eve-NG" environment.
* Internet access via the FortiGate gateway (`192.168.10.1`) to pull `apk` packages.
* Administrative shell access (root or sudo).

## 3. Package Installation
Execute the following commands to update the local package index and install the Docker engine, Docker Compose plugin, and OpenRC.

```bash
# Update package repositories
apk update && apk upgrade

# Install Docker, Docker Compose, and OpenRC
apk add docker docker-cli-compose openrc

```

## 4. User Permissions

To execute Docker commands without encountering socket permission errors, add your user to the `docker` group.

```bash
# Replace 'root' with your actual non-root username if applicable (e.g., 'alpine')
addgroup root docker

```

## 5. Service Management (OpenRC)

Alpine Linux uses OpenRC. Configure the Docker daemon to start automatically on system boot and initiate the service immediately.

```bash
# Add Docker to the boot runlevel for persistence
rc-update add docker boot

# Start the Docker service
rc-service docker start

```

```

### Zero-Trust Verification Blocker
Before we move on to Stage 3 and deploy the SIEM Compose stack, you must verify that the Docker daemon is actively running and properly listening on the Alpine host. 

Execute the following commands on `192.168.10.2`:

1. **Check OpenRC Service Status:**
   ```bash
   rc-service docker status

```

*Expected output: `status: started`.*

2. **Validate Engine Readiness:**
```bash
docker info

```


*Expected output: A detailed readout of the Docker engine version, storage driver, and system resources without any "Cannot connect to the Docker daemon" socket errors.*
