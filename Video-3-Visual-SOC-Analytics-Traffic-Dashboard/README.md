![FortiOS](https://img.shields.io/badge/FortiOS-7.4-EE2737?style=for-the-badge&logo=fortinet&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine_Linux-3.24-0D597F?style=for-the-badge&logo=alpine-linux&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-10.3-F46800?style=for-the-badge&logo=grafana&logoColor=white)

To finalize your Master Documentation Hub, I have removed the manual container deployment steps and streamlined both documents to leverage the automated quickstart shell script exclusively.

When preparing your **Fortinet Lab in Eve-NG**, remember that you can wipe all nodes to clean up HDD space and delete saved lab configurations if you need a fresh start. Alternatively, you can open the "Startup-config" window and press the red “Config Reset” button to set the lab to boot from none. If you are collaborating with other users, you can select the lab and move it to the Shared folder, which is recommended to set "any" Cluster Satellite.

Here are your final publication-ready repository documents.

```markdown
<!-- filepath: docs/main.md -->
# Fortinet Visual SOC Lab - Master Technical Manual

## 1. Architectural Overview
This environment simulates a real-time Security Operations Center (SOC) dashboard. A Kali Linux attacker node generates malicious web traffic and vulnerability exploits across a segmented network. The FortiGate NGFW intercepts, blocks, and logs this activity, streaming raw syslog events in real-time to a containerized Vector, Loki, and Grafana stack hosted on Alpine Linux.

## 2. FortiGate Perimeter Gateway Configuration
Before launching the SIEM stack, configure your FortiGate (`192.168.10.1`) to establish the routing and telemetry forwarding.

### Interface & VLANs
```text
config system interface
    edit "vlan10-siem"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh http
        set interface "port2"
        set vlanid 10
    next
    edit "vlan40-kali"
        set vdom "root"
        set ip 192.168.40.1 255.255.255.0
        set allowaccess ping https ssh
        set interface "port2"
        set vlanid 40
    next
end

```

### Syslog Telemetry Forwarding

```text
config log syslogd setting
    set status enable
    set server "192.168.10.2"
    set mode udp
    set port 514
    set facility local7
    set format default
end

config log syslogd filter
    set forward-traffic enable
    set local-traffic enable
    set severity information
end

```

### Traffic Generation Policies

```text
config firewall policy
    edit 1
        set name "Kali_To_Internet"
        set srcintf "vlan40-kali"
        set dstintf "port1" 
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set nat enable
    next
    edit 2
        set name "Kali_To_SIEM_Web"
        set srcintf "vlan40-kali"
        set dstintf "vlan10-siem"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "HTTP"
        set logtraffic all
    next
end

```

## 3. Alpine Linux Automated SIEM Deployment

Manual container builds are no longer required. The entire SIEM stack (Docker engine, OpenRC service registration, volume provisioning, and configuration downloads) is deployed via a single automated script pulled directly from the repository.

Execute the following on your Alpine Linux host (`192.168.10.2`):

```sh
curl -sL [https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh](https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh) | sh

```

## 4. Teardown & Rollback

To safely spin down the container stack, remove persistent local volumes, and clean up the downloaded configurations, run the rollback script:

```sh
curl -sL [https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/rollback.sh](https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/rollback.sh) | sh

```

```

```markdown
<!-- filepath: README.md -->
# Zero-Cost Visual SOC: FortiOS SIEM Analytics Dashboard



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

No manual git cloning or file building is required. Ensure your Alpine Linux node (`192.168.10.2`) has outbound internet access to reach GitHub, then run the automated setup script. This script installs Docker, configures the services, downloads the necessary configuration YAMLs, and launches the SIEM.

Run the following command directly in your Alpine Linux terminal:

```sh
curl -sL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh | sh

```

### Accessing the Dashboard

Once the script completes, allow 15-30 seconds for the containers to initialize.
Navigate to `http://192.168.10.2` from your Kali client (`192.168.40.3`) or any routed network device.

* **Default User:** `admin`
* **Default Password:** `VisualSocAdmin2026!`

## 🧹 Complete Teardown

To cleanly spin down the environment, wipe local volumes, prune the bridged network, and remove all downloaded files without leaving orphan data, execute the remote rollback script:

```sh
curl -sL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/rollback.sh | sh

```
