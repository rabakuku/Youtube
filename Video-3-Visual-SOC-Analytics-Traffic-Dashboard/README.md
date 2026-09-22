Here is the complete Master Documentation Hub. This stage consolidates the entire technical deployment into your final production manuals and prepares the front page for your repository, as featured on `@ccnadailytips`.

When working within your **Fortinet Lab in Eve-NG**, ensure that you unlock the workspace by pressing the red “Unlock Lab” button, as a locked lab restricts all operational changes. If you are utilizing the countdown timer, remember that stopping it via the unlock button does not stop the nodes or disconnect active sessions. You can also track your deployment progress by creating items in the “Lab Task(s)” sidebar.



```markdown
<!-- filepath: README.md -->
# Zero-Cost Visual SOC: FortiOS SIEM Analytics Dashboard

![FortiOS](https://img.shields.io/badge/FortiOS-7.4-EE2737?style=for-the-badge&logo=fortinet&logoColor=white)
![Alpine](https://img.shields.io/badge/Alpine_Linux-3.24-0D597F?style=for-the-badge&logo=alpine-linux&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Engine-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-10.3-F46800?style=for-the-badge&logo=grafana&logoColor=white)

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

1. **Verify Lab State:** Ensure your environment is active. If using an EVE-NG environment, confirm the lab is unlocked prior to executing setup tasks.


2. **Clone and Execute:**
Run the following on your Alpine Linux host (`192.168.10.2`):
```bash
git clone [https://github.com/rabakuku/Youtube.git](https://github.com/rabakuku/Youtube.git)
cd Youtube/Video-3-Visual-SOC-Analytics-Traffic-Dashboard
chmod +x scripts/setup.sh
./scripts/setup.sh

```


3. **Access the Dashboard:**
Navigate to `http://192.168.10.2` from your Kali client or any device on the routed network. The default credentials are defined in `compose/.env.example`.

## 🧹 Complete Teardown

To cleanly spin down the environment, wipe local volumes, and prune the bridged network without leaving orphan data:

```bash
chmod +x scripts/rollback.sh
./scripts/rollback.sh

```

```

Once you have secured these deliverables, reply exactly with:
**"I am done with Stage 7"**

```
