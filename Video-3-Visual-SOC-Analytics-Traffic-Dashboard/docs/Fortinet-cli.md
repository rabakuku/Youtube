<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/Fortinet-cli.md -->
# FortiGate CLI — Visual SOC "I Attacked My Own SOC" (FortiOS 7.4.12)

Paste the blocks **in order** into the FortiGate CLI (SSH or the GUI CLI console). Every name, IP, and policy ID matches `docs/Lab-Matrix.md`.

| Item | Value |
|---|---|
| Parent interface | `port2` (802.1Q trunk) |
| VLAN 10 — SIEM enclave | `vlan10-siem` 192.168.10.1/24 → Alpine 192.168.10.2 |
| VLAN 40 — attack zone | `vlan40-kali` 192.168.40.1/24 → Kali 192.168.40.3 |
| WAN | `port1` |
| Syslog target | 192.168.10.2 UDP 514 (Vector) |

> **VDOM mode?** If `get system status` shows `Virtual domain configuration: multiple`, run `config vdom` → `edit root` before each block below, and `end` after it. With VDOMs disabled (the default on a lab VM), paste the blocks as they are.

---

## 0. Check the IPS package (decides whether the IPS half of the demo works)

**What/why:** The deny-based demo (port scan) works on any license. The web-attack demo needs IPS signatures. A VM without a FortiGuard subscription still has the signature set bundled with the firmware, which is enough for well-known attacks such as Log4Shell, SQL injection and directory traversal.

```text
get system status
diagnose autoupdate versions | grep -A4 "IPS Attack Engine"
diagnose autoupdate versions | grep -A4 "IPS Attack Signature"
```

Optional, only if you have a valid subscription:

```text
execute update-now
```

---

## 1. VLAN sub-interfaces on port2

**What/why:** Two trust boundaries on one trunk. All VLAN 40 → VLAN 10 traffic is forced through a firewall policy. Admin access is limited: no HTTP management anywhere, and only `ping` on the attack-zone interface so Kali cannot reach the FortiGate GUI/SSH.

```text
config system interface
    edit "vlan10-siem"
        set vdom "root"
        set alias "SIEM-Enclave"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh
        set role lan
        set interface "port2"
        set vlanid 10
    next
    edit "vlan40-kali"
        set vdom "root"
        set alias "Attack-Zone"
        set ip 192.168.40.1 255.255.255.0
        set allowaccess ping
        set role lan
        set interface "port2"
        set vlanid 40
    next
end
```

> If you manage the FortiGate from Kali today, keep `https ssh` on `vlan40-kali` while you build the lab, then remove them before recording — or manage it from port1 / the EVE-NG console.

---

## 2. Address objects

**What/why:** Policy 2 must allow HTTP to exactly one host, not the whole VLAN. Named objects also make the log lines and the wallboard easier to read.

```text
config firewall address
    edit "SOC-Host"
        set comment "Alpine Docker host - Vector/Loki/Grafana"
        set subnet 192.168.10.2 255.255.255.255
    next
    edit "Kali-Attacker"
        set comment "Kali traffic generator"
        set subnet 192.168.40.3 255.255.255.255
    next
    edit "NET-VLAN10-SIEM"
        set subnet 192.168.10.0 255.255.255.0
    next
    edit "NET-VLAN40-KALI"
        set subnet 192.168.40.0 255.255.255.0
    next
end
```

---

## 3. IPS sensor `SOC-Demo-IPS`

**What/why:** Inspects the one port Kali is allowed to reach (HTTP 80) and **blocks** every low-to-critical signature match. `set status enable` forces on signatures that are disabled by default (several scanner signatures are), which makes the demo reliable. `log-packet` stores the offending packet for the FortiGate GUI.

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

> Forcing every low-and-above signature on is a **lab-only** setting. In production use the `default` sensor or tune by severity/target to avoid false positives.

---

## 4. Firewall policies (IDs 1–4)

**What/why:**

| ID | Name | From → To | Action | Logging | Purpose |
|---|---|---|---|---|---|
| 1 | Kali_To_Internet | vlan40-kali → port1 | accept + NAT | security events only | Kali tool updates — keeps internet noise off the wallboard |
| 2 | Kali_To_SOC_Web | vlan40-kali → vlan10-siem | accept, **IPS** | all + session start | Dashboard access; the only door into VLAN 10, and it is inspected |
| 3 | Kali_To_Servers_Deny | vlan40-kali → vlan10-siem | **deny** | all | Explicit, logged deny — the FortiGate's implicit deny does not log by default |
| 4 | SOC_To_Internet | vlan10-siem → port1 | accept + NAT | security events only | apk, Docker image pulls, GitHub raw downloads |

If policies 1, 2 or 4 already exist from the old repo or Stage 3, these `edit` commands overwrite them in place.

```text
config firewall policy
    edit 1
        set name "Kali_To_Internet"
        set srcintf "vlan40-kali"
        set dstintf "port1"
        set action accept
        set srcaddr "NET-VLAN40-KALI"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic utm
        set nat enable
        set comments "Tool updates only - never aim attacks at internet targets"
    next
    edit 2
        set name "Kali_To_SOC_Web"
        set srcintf "vlan40-kali"
        set dstintf "vlan10-siem"
        set action accept
        set srcaddr "NET-VLAN40-KALI"
        set dstaddr "SOC-Host"
        set schedule "always"
        set service "HTTP"
        set utm-status enable
        set inspection-mode flow
        set ssl-ssh-profile "certificate-inspection"
        set ips-sensor "SOC-Demo-IPS"
        set logtraffic all
        set logtraffic-start enable
        set comments "Only door into VLAN 10 - HTTP to Grafana, IPS inspected"
    next
    edit 3
        set name "Kali_To_Servers_Deny"
        set srcintf "vlan40-kali"
        set dstintf "vlan10-siem"
        set action deny
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "Explicit logged deny - feeds the wallboard"
    next
    edit 4
        set name "SOC_To_Internet"
        set srcintf "vlan10-siem"
        set dstintf "port1"
        set action accept
        set srcaddr "SOC-Host"
        set dstaddr "all"
        set schedule "always"
        set service "DNS" "HTTP" "HTTPS" "NTP" "PING"
        set logtraffic utm
        set nat enable
        set comments "Alpine updates and container image pulls"
    next
end
```

**Order matters:** policy 2 must sit **above** policy 3, otherwise the deny catches the dashboard traffic too. New policies are appended at the bottom, so check the order and fix it if needed:

```text
show firewall policy | grep -E "edit|set name"
config firewall policy
    move 2 before 3
end
```

If you have any older allow-all policy between `vlan40-kali` and `vlan10-siem`, delete or disable it — it would hide the deny events.

---

## 5. Syslog to Vector (192.168.10.2 UDP 514)

**What/why:** Streams traffic and security (IPS) logs to the SIEM in the FortiOS default `key=value` format, which `vector.yaml` parses. `source-ip` pins the sender to the VLAN 10 address so the logs always arrive from 192.168.10.1. Local-traffic logs (sessions to the FortiGate itself) are turned off to keep the wallboard focused on the attack.

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

> Security-profile logs (IPS) are always forwarded once syslog is enabled; there is no separate toggle for them in the filter. If a keyword is rejected on your exact build, type `set ?` inside that block to list what your firmware supports.

---

## 6. Smoke test — generate sample logs

**What/why:** Makes the FortiGate send a burst of sample traffic, event and UTM logs to every log target. Within seconds the wallboard's **Events (5m)** counter should move. Sample logs use made-up IPs; they age out of the 15-minute panels on their own.

```text
diagnose log test
```

---

## 7. Save a backup of the finished config

```text
execute backup config tftp visual-soc-lab.conf <TFTP_SERVER_IP>
```

Or from the GUI: user menu (top right) → **Configuration → Backup**. Replace `<TFTP_SERVER_IP>` with your own TFTP server, or use the GUI method.
