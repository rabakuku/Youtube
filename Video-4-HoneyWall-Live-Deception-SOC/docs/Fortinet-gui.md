<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/Fortinet-gui.md -->
# FortiGate GUI — HoneyWall (FortiOS 7.4.13)

This is the same configuration as `docs/Fortinet-cli.md`, in the same order and with the same names. Menu paths are for the 7.4 GUI. "→" means *click*; `field = value` means *set the field*.

## 0. Back up

Admin menu (top right) → **Configuration** → **Backup** → Local PC → **OK**.

**Policy & Objects → Firewall Policy**: confirm that policy **3** is *USERS TO SERVERS* and **20** is *OUTBOUND_HONEYPOT_WEBHOOK_TO_FGT*. Use the ID column; enable it in the column settings if it's hidden.

## 1. Interfaces

**Network → Interfaces** → expand `port2`:

| Interface | Administrative access |
|---|---|
| `VLAN_QC_40` | PING ✔, HTTPS ✔, **SSH ✘**, **HTTP ✘** |
| `VLAN_QC_10` | PING ✔, HTTPS ✔, SSH ✘, HTTP ✘ |

Edit each interface, set the boxes, then **OK**. `port1` is not changed.

## 2. DHCP reservations (recommended)

**Network → Interfaces** → edit `VLAN_QC_10` → *DHCP Server* → expand **Advanced** → *IP address assignment rules* → **Create New**:
- `Type = MAC address`, `MAC = <ALPINE_MAC>`, `Action = Reserve IP`, `IP = 192.168.10.2`

Repeat on `VLAN_QC_40` for Kali: `<KALI_MAC>` → `192.168.40.3`.

An easier route: **Dashboard → Assets & Identities** (or **Network → DHCP monitor**), right-click the device → **Create/Edit DHCP Reservation**.

## 3. Addresses

**Policy & Objects → Addresses** — these already exist; check the values:

| Name | Type | Value | Comment |
|---|---|---|---|
| NET_SERVERS_VLAN10 | Subnet | 192.168.10.0/24 | |
| NET_USERS_VLAN40 | Subnet | 192.168.40.0/24 | |
| HOST_ALPINE_HONEYPOT | Subnet | 192.168.10.2/32 | alpine-docker: Cowrie + web decoy + HoneyWall |
| HOST_KALI_ATTACKER | Subnet | 192.168.40.3/32 | |

## 4. Virtual IPs

**Policy & Objects → Virtual IPs** → **Create New → Virtual IP**. For each row, set:
- `Name`, `Interface`, `Type = Static NAT`, `External IP address/range`, `Map to IPv4 address/range = 192.168.10.2`
- **Port Forwarding ✔**, `Protocol = TCP`, `External service port`, `Map to IPv4 port`

| Name | Interface | External IP | Ext port | Map to port | Comment |
|---|---|---|---|---|---|
| VIP_HONEYWALL_SSH22 | VLAN_QC_40 | 192.168.40.1 | 22 | 2222 | Decoy srv-corp-ssh01 |
| VIP_HONEYWALL_WEB80 | VLAN_QC_40 | 192.168.40.1 | 80 | 8088 | Decoy Corp Backup Console |
| VIP_WAN_HONEYWALL_DASH | port1 | 172.24.66.58 | 8080 | 80 | HoneyWall dashboard |
| VIP_WAN_HONEYWALL_NTFY | port1 | 172.24.66.58 | 8090 | 8090 | ntfy alert page |
| VIP_WAN_HONEYWALL_DOZZLE | port1 | 172.24.66.58 | 9999 | 9999 | Dozzle (full profile) |

Leave `SSH-TO-Honeypot` and `SSH-TO-KALI` as they are.

If the GUI warns that the external IP equals the interface IP, that's expected. The admin SSH and HTTP you removed in step 1 no longer compete for those ports.

## 5. Firewall policies

**Policy & Objects → Firewall Policy**:

1. **Edit policy 4** → `Name = WAN_TO_LAB_VIPS`. In *Destination*, keep only `SSH-TO-Honeypot`, `SSH-TO-KALI`, `VIP_WAN_HONEYWALL_DASH`, `VIP_WAN_HONEYWALL_NTFY` and `VIP_WAN_HONEYWALL_DOZZLE`. Set *Log Allowed Traffic = All Sessions*, then **OK**. Tip: set *Source* to your PC's subnet instead of `all`.
2. Right-click **policy 3** (*USERS TO SERVERS*) → **Delete**.
3. Right-click **policy 20** (*OUTBOUND_HONEYPOT_WEBHOOK_TO_FGT*) → **Delete**.
4. **Create New**, twice:

| Field | USERS_TO_DECOY_SSH | USERS_TO_DECOY_WEB |
|---|---|---|
| Incoming interface | USERS | USERS |
| Outgoing interface | SERVERS | SERVERS |
| Source | NET_USERS_VLAN40 | NET_USERS_VLAN40 |
| Destination | VIP_HONEYWALL_SSH22 | VIP_HONEYWALL_WEB80 |
| Schedule | always | always |
| Service | SSH | HTTP |
| Action | ACCEPT | ACCEPT |
| NAT | **off** | **off** |
| Security profiles | **none** (the decoy is the sensor) | **none** |
| Log Allowed Traffic | All Sessions | All Sessions |
| Comments | HoneyWall SSH decoy - no NAT, no profiles | HoneyWall web decoy - no NAT, no profiles |

Leave policy 2, `SERVERS TO WAN`, as it is.

## 6. Remove the previous Video-4 objects

- **Policy & Objects → Virtual IPs**: delete `HTTP-TO-Mattermost`, `HTTP-TO-Honeypot`, `HTTP-TO-Dozzle` and `VIP_COWRIE_HONEYPOT_2222`. The *Ref.* column must show 0; if not, open the reference and remove it first.
- **Security Fabric → Automation**: delete the stitch `STITCH_COWRIE_AUTO_QUARANTINE`. Then, on the *Action* and *Trigger* tabs, delete `ACT_QUARANTINE_ATTACKER_IP` and `TRIG_COWRIE_QUARANTINE`.

## 7. REST API admin

**System → Admin Profiles** → **Create New**:
- `Name = PROF_HONEYWALL_API`, `Comments = HoneyWall engine: status, banned IPs, attacker session close`
- *User & Authentication* = **Read/Write**
- *System* = **Read**
- *Firewall* = **Read**
- Every other category = **None**

**System → Administrators** → **Create New → REST API Admin**:
- `Username = api_honeywall`
- `Comments = HoneyWall engine on alpine-docker`
- `Administrator profile = PROF_HONEYWALL_API`
- *PKI Group* off
- *CORS Allow Origin* off
- **Trusted Hosts ✔** `192.168.10.2/32`
- **OK**

The GUI shows the **API key once**. Copy it straight into the Alpine step (CLI doc, block 8). To regenerate it later: edit the admin → **Regenerate**. The CLI equivalent is `execute api-user generate-key api_honeywall`.

**CLI-only:** the permission troubleshooting (`diagnose debug application httpsd -1`) is in CLI doc block 7.

## 8–9. Alpine and API tests

These run on Alpine; see CLI doc blocks 8 and 9.

## 10. Watch the ban (Act 4 receipt)

**Dashboard → Users & Devices** → **Quarantine** widget. If it's missing: **+** (add widget) → *Quarantine*. It lists `192.168.40.3` with source *Administrative* while HoneyWall holds the ban. The widget also offers a remove action, and HoneyWall notices that within `BAN_POLL_SEC` (3 s).

**Log & Report → Forward Traffic**: filter `Source = 192.168.40.3` to see the accepted decoy sessions before the ban.

## 11. Self-lockout test

See CLI doc block 11 (done from your PC, the Kali console and Alpine).
