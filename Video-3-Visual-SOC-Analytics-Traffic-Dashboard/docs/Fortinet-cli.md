<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/Fortinet-cli.md -->
# FortiGate CLI — Visual SOC on FGTQC01 (FortiOS 7.4.12, zone-based)

Paste the blocks **in order**. Names, IPs and zones match `docs/Lab-Matrix.md` and the live FGTQC01 config:

| Item | Value |
|---|---|
| Zones | `SERVERS` (VLAN_QC_10, 192.168.10.1/24) · `USERS` (VLAN_QC_40, 192.168.40.1/24) · `WAN` (port1, DHCP 172.24.66.52/24) |
| Existing policies kept | 2 `SERVERS TO WAN` · 3 `USERS TO SERVERS` (narrowed in step 6) · 4 `VIP TO INTERNAL` (2 VIPs appended) |
| New policies | 100 `SOC_Quarantine_Block` (top) · 101 `Kali_To_Servers_Deny` · 102 `Kali_To_WAN_Deny` |
| Kali internet | **None.** Kali never initiates anything toward WAN; inbound SSH through `SSH-TO-KALI` still works |

> Every new policy uses a fixed ID from 100 up (IDs 2–4 are yours; nothing else exists), so no existing policy can be overwritten.

---

## 0. Before you start

**Back up the current config** (it is a work lab):

```text
execute backup config ftp fgtqc01-before-visual-soc.conf <FTP_SERVER_IP> <USER> <PASSWORD>
```

or GUI: user menu (top right) → **Configuration → Backup → Local PC**.

**Check VDOM mode and the IPS package:**

```text
get system status | grep -i "virtual domain"
diagnose autoupdate versions | grep -A4 "IPS Attack Signature"
get system settings | grep firewall-session-dirty
```

- `Virtual domain configuration: disable` → paste the blocks as they are (`multiple` → `config vdom` / `edit root` first).
- `firewall-session-dirty: check-all` (the default) → when Kali is quarantined, its **existing** sessions are re-checked and dropped too.

---

## 1. Pin the lab IPs (DHCP reservations)

**What/why:** Alpine (.10.2) and Kali (.40.3) currently get their addresses from the FortiGate DHCP pools. The VIPs, policies and the responder allowlist point at those exact IPs, so they must never change.

Get the MAC addresses:

```text
execute dhcp lease-list
```

Then reserve them (replace the two MACs with the ones from the lease list):

```text
config system dhcp server
    edit 3
        config reserved-address
            edit 0
                set ip 192.168.10.2
                set mac <ALPINE_MAC>
                set description "soc-alpine Visual SOC"
            next
        end
    next
    edit 2
        config reserved-address
            edit 0
                set ip 192.168.40.3
                set mac <KALI_MAC>
                set description "kali Visual SOC attacker"
            next
        end
    next
end
```

> port1 is also DHCP (172.24.66.52 is your Grafana VIP address). Ask whoever runs the 172.24.66.0/24 network to reserve that address for the FortiGate's port1 MAC (`get hardware nic port1 | grep -i hwaddr`), or every VIP breaks when the lease changes.

---

## 2. Admin access on the lab interfaces

**What/why:** the attacker VLAN must not see the firewall's login page. `VLAN_QC_10` keeps HTTPS (the responder calls the REST API on 192.168.10.1) and SSH; plain HTTP admin is removed from both.

```text
config system interface
    edit "VLAN_QC_10"
        set allowaccess ping https ssh
    next
    edit "VLAN_QC_40"
        set allowaccess ping
    next
end
```

> Make sure you manage FGTQC01 from port1/WAN (not from Kali) before pasting this.

---

## 3. Address objects and the quarantine group

**What/why:** `SOC-Host` lets policy 3 allow HTTP to exactly one server. `SOC-Quarantine` is the group the responder fills with `Q-<ip>` objects; FortiOS does not allow an empty group, so it permanently contains the built-in `none` (0.0.0.0/32).

```text
config firewall address
    edit "SOC-Host"
        set comment "Alpine Docker host - Vector/Loki/Grafana/ntfy/responder"
        set subnet 192.168.10.2 255.255.255.255
    next
    edit "Kali-Attacker"
        set comment "Kali traffic generator"
        set subnet 192.168.40.3 255.255.255.255
    next
end

config firewall addrgrp
    edit "SOC-Quarantine"
        set comment "Managed by soc-responder - members Q-<ip> are blocked everywhere"
        set member "none"
    next
end
```

---

## 4. IPS sensor `SOC-Demo-IPS`

**What/why:** policy 3 already uses this sensor. This block (re)applies the demo settings — block and log every low-to-critical signature on the one allowed port. Lab-only: production would use the `default` sensor.

```text
config ips sensor
    edit "SOC-Demo-IPS"
        set comment "Visual SOC demo - block and log web attacks against SOC-Host"
        set extended-log enable
        set block-malicious-url enable
        config entries
            edit 1
                set severity low medium high critical
                set status enable
                set log enable
                set log-packet enable
                set action block
            next
        end
    next
end
```

---

## 5. Two new VIPs for the admin PC

**What/why:** your PC reaches ntfy (alerts + buttons) and the responder (where the buttons send their request) through port1, next to the existing `HTTP-TO-Grafana` (8080). Same port inside and out.

```text
config firewall vip
    edit "NTFY-TO-SOC"
        set comment "ntfy web app on SOC-Host"
        set extip 172.24.66.52
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set extport 8090
        set mappedport 8090
    next
    edit "RESPONDER-TO-SOC"
        set comment "soc-responder signed button links"
        set extip 172.24.66.52
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set extport 8091
        set mappedport 8091
    next
end

config firewall policy
    edit 4
        append dstaddr "NTFY-TO-SOC" "RESPONDER-TO-SOC"
    next
end
```

**Recommended:** `VIP TO INTERNAL` accepts source `all` from the 172.24.66.x side, so anyone there can reach SSH on Alpine/Kali, ntfy and the responder. Lock it to your PC (replace the IP):

```text
config firewall address
    edit "ADMIN-PC"
        set comment "Admin workstation for the Visual SOC lab"
        set subnet <YOUR_PC_IP> 255.255.255.255
    next
end
config firewall policy
    edit 4
        set srcaddr "ADMIN-PC"
    next
end
```

---

## 6. Policies

### 6a. Narrow policy 3 → `Kali_To_SOC_Web`

**What/why:** today policy 3 accepts **everything** from USERS to SERVERS, so a port scan produces no denies and the *Port scan detected* rule can never fire. It becomes the single door: HTTP to `SOC-Host`, still IPS-inspected. The name changes to match the dashboards.

```text
config firewall policy
    edit 3
        set name "Kali_To_SOC_Web"
        set dstaddr "SOC-Host"
        set service "HTTP"
        set comments "Only door into SERVERS - HTTP to Grafana, IPS inspected"
    next
end
```

### 6b. New policies 100–102

| ID | Name | From → To | Action | Why |
|---|---|---|---|---|
| 100 | SOC_Quarantine_Block | any → any, source `SOC-Quarantine` | deny + log | Quarantine — must be the **first** policy |
| 101 | Kali_To_Servers_Deny | USERS → SERVERS | deny + log | Everything except policy 3 — feeds the wallboard |
| 102 | Kali_To_WAN_Deny | USERS → WAN | deny + log | Kali never reaches WAN; attempts are visible and auditable |

```text
config firewall policy
    edit 100
        set name "SOC_Quarantine_Block"
        set srcintf "any"
        set dstintf "any"
        set action deny
        set srcaddr "SOC-Quarantine"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "Visual SOC quarantine - members are added/removed by soc-responder"
    next
    edit 101
        set name "Kali_To_Servers_Deny"
        set srcintf "USERS"
        set dstintf "SERVERS"
        set action deny
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "Explicit logged deny - port scans show on the wallboard"
    next
    edit 102
        set name "Kali_To_WAN_Deny"
        set srcintf "USERS"
        set dstintf "WAN"
        set action deny
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "Kali is never allowed to reach WAN (work-lab rule)"
    next
end
```

### 6c. Order

New policies are appended at the bottom. Put the quarantine on top and the deny right after the allow:

```text
config firewall policy
    move 100 before 2
    move 101 after 3
end
show firewall policy | grep -E "^    edit|set name"
```

Expected order: **100, 2, 3, 101, 4, 102** (101 must come after 3; 102's position does not matter because nothing else matches USERS → WAN).

> Policies with `any` interfaces switch the GUI policy list to **By Sequence** view. That is normal.

---

## 7. Syslog to Vector

**What/why:** the stack already receives logs; this block makes sure the settings match what Vector parses (default key=value, UDP 514, sent from 192.168.10.1).

```text
config log syslogd setting
    set status enable
    set server "192.168.10.2"
    set mode udp
    set port 514
    set facility local7
    set source-ip "192.168.10.1"
    set format default
end

config log syslogd filter
    set severity information
    set forward-traffic enable
    set local-traffic disable
    set multicast-traffic disable
    set sniffer-traffic disable
    set anomaly enable
    set voip disable
end
```

---

## 8. REST API admin for the responder

**What/why:** the responder needs exactly one permission — create/delete address objects and edit the `SOC-Quarantine` group. It gets a dedicated profile with **firewall address read-write and nothing else**, and its token is only accepted from 192.168.10.2.

```text
config system accprofile
    edit "soc-quarantine"
        set comments "Visual SOC responder - firewall address objects only"
        set fwgrp custom
        config fwgrp-permission
            set policy none
            set address read-write
            set service none
            set schedule none
            set others none
        end
    next
end

config system api-user
    edit "soc-responder"
        set comments "Visual SOC responder on 192.168.10.2"
        set accprofile "soc-quarantine"
        set vdom "root"
        config trusthost
            edit 1
                set ipv4-trusthost 192.168.10.2 255.255.255.255
            next
        end
    next
end

execute api-user generate-key soc-responder
```

The last command prints **`New API key: …`** once. Copy it, then on **Alpine**:

```sh
cd /opt/visual-soc-analytics-traffic-dashboard
./setup.sh --fgt-token <PASTE_KEY_HERE>
```

Expected line: `[+] FortiGate API token works and group SOC-Quarantine exists — quarantine is LIVE.`

> If any `fwgrp-permission` keyword is rejected on your build, type `set ?` inside that block: only `address` must be `read-write`.

---

## 9. Getting scripts onto Kali (no internet)

Kali has no WAN access, so copy files through the existing `SSH-TO-KALI` VIP from your PC or the git box:

```sh
scp -P 2223 Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/kali-attack-campaign.sh <kali-user>@172.24.66.58:~/
```

`nmap`, `curl` and `nikto` ship with the standard Kali image, so nothing has to be installed.

---

## 10. Smoke test

```text
diagnose log test
```

The wallboard's **Events (5m)** moves within seconds (sample logs with fake IPs; they age out of the 15-minute panels).

---

## 11. Rollback — remove everything this guide added

```text
config firewall policy
    delete 100
    delete 101
    delete 102
    edit 3
        set name "USERS TO SERVERS"
        set dstaddr "all"
        set service "ALL"
        unset comments
    next
    edit 4
        unselect dstaddr "NTFY-TO-SOC" "RESPONDER-TO-SOC"
        set srcaddr "all"
    next
end
config system api-user
    delete "soc-responder"
end
config system accprofile
    delete "soc-quarantine"
end
config firewall vip
    delete "NTFY-TO-SOC"
    delete "RESPONDER-TO-SOC"
end
config firewall addrgrp
    delete "SOC-Quarantine"
end
config firewall address
    delete "SOC-Host"
    delete "Kali-Attacker"
    delete "ADMIN-PC"
end
```

Run `./rollback.sh` on Alpine **first** — it releases active quarantines and removes their `Q-<ip>` objects. Any `Q-…` object left over can be deleted with `config firewall address` → `delete "Q-<ip>"`. DHCP reservations and interface admin access are left as they are (remove in `config system dhcp server` / `config system interface` if wanted).
