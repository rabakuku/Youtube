<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/Fortinet-gui.md -->
# FortiGate GUI — Visual SOC "I Attacked My Own SOC" (FortiOS 7.4.12)

The same configuration as `docs/Fortinet-cli.md`, in the same order, as click-paths. Names must match exactly — the wallboard and the Vector parser depend on them. Settings marked **CLI-only** cannot be set in the GUI; paste the CLI snippet from `Fortinet-cli.md` for those.

> **Before you start:** if **Security Profiles → Intrusion Prevention** is missing from the menu, enable it under **System → Feature Visibility → Security Features → Intrusion Prevention = ON → Apply**.

---

## 0. Check the IPS package

**System → FortiGuard → License Information**

- **Intrusion Prevention** row: note the *IPS Definitions* version and date.
- Unlicensed VM: the definitions bundled with the firmware still match common attacks. Deny-based panels work regardless.

---

## 1. VLAN sub-interfaces

**Network → Interfaces → Create New → Interface**

| Field | vlan10-siem | vlan40-kali |
|---|---|---|
| Name | `vlan10-siem` | `vlan40-kali` |
| Alias | `SIEM-Enclave` | `Attack-Zone` |
| Type | VLAN | VLAN |
| Interface | `port2` | `port2` |
| VLAN ID | `10` | `40` |
| Role | LAN | LAN |
| Addressing mode | Manual | Manual |
| IP/Netmask | `192.168.10.1/255.255.255.0` | `192.168.40.1/255.255.255.0` |
| Administrative Access | PING, HTTPS, SSH | PING only |

Click **OK** for each. If they already exist, double-click to edit and match the table.

---

## 2. Address objects

**Policy & Objects → Addresses → Create New → Address**

| Name | Type | IP/Netmask | Comments |
|---|---|---|---|
| `SOC-Host` | Subnet | `192.168.10.2/32` | Alpine Docker host - Vector/Loki/Grafana |
| `Kali-Attacker` | Subnet | `192.168.40.3/32` | Kali traffic generator |
| `NET-VLAN10-SIEM` | Subnet | `192.168.10.0/24` | |
| `NET-VLAN40-KALI` | Subnet | `192.168.40.0/24` | |

---

## 3. IPS sensor

**Security Profiles → Intrusion Prevention → Create New**

| Field | Value |
|---|---|
| Name | `SOC-Demo-IPS` |
| Comments | Visual SOC demo - block and log web attacks against SOC-Host |
| Block malicious URLs | ON |

Under **IPS Signatures and Filters → Create New**:

| Field | Value |
|---|---|
| Type | Filter |
| Severity | Low, Medium, High, Critical (select all four) |
| Action | Block |
| Packet logging | Enable |
| Status | Enable |

Click **OK**, then **OK** again to save the sensor.

**CLI-only:** `set extended-log enable` (adds more fields to IPS logs) and forcing the filter's `status enable` override on some builds — paste section 3 of `Fortinet-cli.md` afterwards to be sure.

---

## 4. Firewall policies

**Policy & Objects → Firewall Policy → Create New** (or double-click an existing ID to edit)

### Policy 1 — `Kali_To_Internet`

| Field | Value |
|---|---|
| Incoming Interface | `vlan40-kali` |
| Outgoing Interface | `port1` |
| Source | `NET-VLAN40-KALI` |
| Destination | `all` |
| Schedule | `always` |
| Service | `ALL` |
| Action | ACCEPT |
| NAT | ON |
| Log Allowed Traffic | Security Events |
| Comments | Tool updates only - never aim attacks at internet targets |

### Policy 2 — `Kali_To_SOC_Web`

| Field | Value |
|---|---|
| Incoming Interface | `vlan40-kali` |
| Outgoing Interface | `vlan10-siem` |
| Source | `NET-VLAN40-KALI` |
| Destination | `SOC-Host` |
| Schedule | `always` |
| Service | `HTTP` |
| Action | ACCEPT |
| NAT | OFF |
| Inspection Mode | Flow-based |
| Security Profiles → IPS | ON → `SOC-Demo-IPS` |
| SSL Inspection | `certificate-inspection` |
| Log Allowed Traffic | All Sessions |
| Generate Logs when Session Starts | ON |
| Comments | Only door into VLAN 10 - HTTP to Grafana, IPS inspected |

### Policy 3 — `Kali_To_Servers_Deny`

| Field | Value |
|---|---|
| Incoming Interface | `vlan40-kali` |
| Outgoing Interface | `vlan10-siem` |
| Source | `all` |
| Destination | `all` |
| Schedule | `always` |
| Service | `ALL` |
| Action | DENY |
| Log Violation Traffic | ON |
| Comments | Explicit logged deny - feeds the wallboard |

### Policy 4 — `SOC_To_Internet`

| Field | Value |
|---|---|
| Incoming Interface | `vlan10-siem` |
| Outgoing Interface | `port1` |
| Source | `SOC-Host` |
| Destination | `all` |
| Schedule | `always` |
| Service | `DNS`, `HTTP`, `HTTPS`, `NTP`, `PING` |
| Action | ACCEPT |
| NAT | ON |
| Log Allowed Traffic | Security Events |
| Comments | Alpine updates and container image pulls |

### Order

Switch the list to **Sequence Grouping** (or **By Sequence**) view and drag **Kali_To_SOC_Web (2)** above **Kali_To_Servers_Deny (3)**. Disable or delete any older allow-all policy between `vlan40-kali` and `vlan10-siem`.

---

## 5. Syslog to Vector

**Log & Report → Log Settings → Remote Logging and Archiving**

| Field | Value |
|---|---|
| Send logs to syslog | ON |
| IP Address/FQDN | `192.168.10.2` |

Click **Apply**.

**CLI-only** (paste section 5 of `Fortinet-cli.md`): `mode udp`, `port 514`, `facility local7`, `source-ip 192.168.10.1`, `format default`, and the whole `config log syslogd filter` block (`severity information`, `forward-traffic enable`, `local-traffic disable`, `multicast-traffic disable`, `sniffer-traffic disable`, `anomaly enable`, `voip disable`).

Also on the same page, under **Log Settings**: set **Event Logging** and **Local Traffic Log** as you like for the GUI; the syslog filter above decides what reaches Vector.

---

## 6. Smoke test

**CLI-only:** open the CLI console (top-right `>_` icon) and run `diagnose log test`. Watch **Events (5m)** on the wallboard move within a few seconds.

---

## 7. Backup

User menu (top right) → **Configuration → Backup → Local PC → OK**. Store it next to the repo as your known-good lab config.
