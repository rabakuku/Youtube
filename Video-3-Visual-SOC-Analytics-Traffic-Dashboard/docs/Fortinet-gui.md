<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/Fortinet-gui.md -->
# FortiGate GUI — Visual SOC on FGTQC01 (FortiOS 7.4.12, zone-based)

The same configuration as `docs/Fortinet-cli.md`, in the same order, as click-paths. Names must match exactly. Items marked **CLI-only** have no GUI field — paste that snippet from `Fortinet-cli.md`.

> Back up first: user menu (top right) → **Configuration → Backup → Local PC → OK**.

---

## 1. DHCP reservations

**Dashboard → Network → DHCP** (widget) → **Expand** → right-click the lease for **192.168.10.2** → **Create DHCP Reservation**. Repeat for **192.168.40.3**.
Check: **Network → Interfaces → VLAN_QC_10 / VLAN_QC_40 → DHCP Server → Advanced → IP Address Assignment Rules** shows the reserved MAC.

## 2. Admin access

**Network → Interfaces**:

| Interface | Administrative Access |
|---|---|
| SERVERS (VLAN_QC_10) | PING, HTTPS, SSH (untick HTTP) |
| USERS (VLAN_QC_40) | PING only |

## 3. Addresses and quarantine group

**Policy & Objects → Addresses → Create New → Address**

| Name | Type | IP/Netmask | Comments |
|---|---|---|---|
| `SOC-Host` | Subnet | 192.168.10.2/32 | Alpine Docker host |
| `Kali-Attacker` | Subnet | 192.168.40.3/32 | Kali traffic generator |

**Create New → Address Group**: Name `SOC-Quarantine`, Members **none**, Comments *Managed by soc-responder*.

## 4. IPS sensor

**Security Profiles → Intrusion Prevention → SOC-Demo-IPS** (already exists): one filter with **Severity** Low/Medium/High/Critical, **Action** Block, **Packet logging** Enable, **Status** Enable; **Block malicious URLs** ON. **CLI-only:** `set extended-log enable`.

## 5. VIPs

**Policy & Objects → Virtual IPs → Create New → Virtual IP**

| Field | NTFY-TO-SOC | RESPONDER-TO-SOC |
|---|---|---|
| Interface | any | any |
| External IP address | 172.24.66.52 | 172.24.66.52 |
| Map to IPv4 address | 192.168.10.2 | 192.168.10.2 |
| Port Forwarding | ON, TCP | ON, TCP |
| External service port | 8090 | 8091 |
| Map to IPv4 port | 8090 | 8091 |

Then **Policy & Objects → Firewall Policy → VIP TO INTERNAL** → **Destination** `+` → add **NTFY-TO-SOC** and **RESPONDER-TO-SOC** → **OK**.
Recommended: create address `ADMIN-PC` (your PC IP /32) and set it as the **Source** of VIP TO INTERNAL instead of `all`.

## 6. Policies

**6a. Edit policy `USERS TO SERVERS`** → Name `Kali_To_SOC_Web`, Destination `SOC-Host`, Service `HTTP` (keep IPS `SOC-Demo-IPS`, SSL `certificate-inspection`, Log Allowed Traffic *All Sessions*).

**6b. Create New** policies (switch the list to **By Sequence**):

| Field | SOC_Quarantine_Block | Kali_To_Servers_Deny | Kali_To_WAN_Deny |
|---|---|---|---|
| Incoming Interface | any | USERS | USERS |
| Outgoing Interface | any | SERVERS | WAN |
| Source | SOC-Quarantine | all | all |
| Destination | all | all | all |
| Service | ALL | ALL | ALL |
| Action | DENY | DENY | DENY |
| Log Violation Traffic | ON | ON | ON |

The GUI assigns its own IDs; the names are what matter (the CLI guide uses 100–102).

**6c. Order:** drag **SOC_Quarantine_Block** to the very top; drag **Kali_To_Servers_Deny** directly below **Kali_To_SOC_Web**.

## 7. Syslog

**Log & Report → Log Settings → Remote Logging and Archiving → Send logs to syslog** ON, IP `192.168.10.2` → Apply. **CLI-only:** mode/port/facility/`source-ip 192.168.10.1`/format and the whole `config log syslogd filter` block.

## 8. REST API admin

1. **System → Admin Profiles → Create New**: Name `soc-quarantine`, set **everything to None** except **Firewall → Custom → Address = Read/Write**.
2. **System → Administrators → Create New → REST API Admin**: Username `soc-responder`, Administrator profile `soc-quarantine`, **Trusted Hosts** ON → `192.168.10.2/32`, PKI group off → **OK**.
3. The **API key is shown once** — copy it, then on Alpine: `./setup.sh --fgt-token <KEY>`.

## 9. Smoke test

CLI console (`>_` top right): `diagnose log test` → wallboard **Events (5m)** moves.
