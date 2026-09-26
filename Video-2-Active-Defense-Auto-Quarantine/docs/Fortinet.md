```markdown
<!-- filepath: docs/Fortinet.md -->
# Fortinet Security Fabric Integration Guide

This guide details the end-to-end configuration for Node 1 (`FGT-CORE-01`, `192.168.10.1/24` on `port2`) to implement automated threat containment. It establishes REST API permissions, address infrastructure, edge firewall isolation policies, and native Automation Stitches that notify the containerized orchestrator on Node 2 (`192.168.10.2:80`).

---

## 1. Architectural Role & Topology Parameters

* **Interface**: `port2`
* **FortiGate IP**: `192.168.10.1/24`
* **Alpine Docker Host (SOAR)**: `192.168.10.2`
* **Attacker Host (Kali)**: `192.168.40.3`
* **API Administrator**: `soar-api-admin`
* **API Bearer Token**: `autoquarantine-sec-token-xyz123`
* **Isolation Address Group**: `GRP_ACTIVE_QUARANTINE`
```
---

## 2. CLI Configuration (Step-by-Step)

Execute the following commands sequentially via the FortiGate administrative console or SSH session:

## Configure VIPs
```fortios
config firewall vip
    edit "SSH-TO-N8N"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set extport 2222
        set mappedport 22
    next
end

config firewall vip
    edit "HTTP-TO-N8N"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set extport 8080
        set mappedport 80
    next
end

config firewall vip
    edit "SSH-TO-KALI"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set extport 2223
        set mappedport 22
    next
end
```

## How to SSH from VIPs
```bash
ssh root@172.24.66.58 -p 2222
ssh root@172.24.66.58 -p 2223
```

## Configure Interfaces
```fortios
config system interface
    edit "VLAN_QC_40"
        set vdom "root"
        set ip 192.168.40.1 255.255.255.0
        set allowaccess ping https ssh http
        set alias "USERS"
        set device-identification enable
        set role lan
        set ip-managed-by-fortiipam disable
        set interface "port2"
        set vlanid 40
    next
    edit "VLAN_QC_10"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh http
        set alias "SERVERS"
        set device-identification enable
        set role lan
        set ip-managed-by-fortiipam disable
        set interface "port2"
        set vlanid 10
    next
   edit "port2"
        set vdom "root"
        set allowaccess ping https ssh http
        set type physical
        set description "TRUNK-Internal"
        set alias "TRUNK"
    next
end
end
config system zone
    edit "WAN"
        set interface "port1"
    next
    edit "USERS"
        set interface "VLAN_QC_40"
    next
    edit "DMZ"
        set interface "port3"
    next
    edit "SERVERS"
        set interface "VLAN_QC_10"
    next
end
```
```fortios
## Configure Firewall Address
config system dhcp server
    edit 2
        set default-gateway 192.168.40.1
        set netmask 255.255.255.0
        set interface "VLAN_QC_40"
        config ip-range
            edit 1
                set start-ip 192.168.40.3
                set end-ip 192.168.40.254
            next
        end
        set dns-server1 1.1.1.1
        set dns-server2 8.8.8.8
    next
    edit 3
        set default-gateway 192.168.10.1
        set netmask 255.255.255.0
        set interface "VLAN_QC_10"
        config ip-range
            edit 1
                set start-ip 192.168.10.2
                set end-ip 192.168.10.254
            next
        end
        set dns-server1 1.1.1.1
        set dns-server2 8.8.8.8
    next
end
```

## Configure Firewall Address
```fortios
config firewall address
    edit "QUAR_PLACEHOLDER"
        set type ipmask
        set subnet 0.0.0.0 255.255.255.255
        set comment "Static anchor member for dynamic group initialization"
    next
    edit "HOST_ALPINE_SOAR"
        set type ipmask
        set subnet 192.168.10.2 255.255.255.255
        set comment "Container orchestration host"
    next
end

config firewall addrgrp
    edit "GRP_ACTIVE_QUARANTINE"
        set member "QUAR_PLACEHOLDER"
        set comment "Dynamic SOAR quarantine blocklist"
    next
end
```

## Configure Firewall Policies
```Fortios
config firewall policy
   edit 1
        set name "POLICY_ACTIVE_QUARANTINE_DROP"
        set srcintf "any"
        set dstintf "any"
        set srcaddr "GRP_ACTIVE_QUARANTINE"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "SOAR automated isolation - drops attacking IPs instantly"
    next
    edit 2
        set name "SERVERS TO WAN"
        set srcintf "SERVERS"
        set dstintf "WAN"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set nat enable
    next
    edit 3
        set name "USERS TO SERVERS"
        set srcintf "USERS"
        set dstintf "SERVERS"
        set action accept
        set srcaddr "all"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
    edit 4
        set name "VIP TO INTERNAL"
        set srcintf "WAN"
        set dstintf "SERVERS"
        set action accept
        set srcaddr "all"
        set dstaddr "SSH-TO-N8N, HTTP-TO-N8N, SSH-TO-KALI"
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
end
```
## Configure DoS Policies
```fortios
config firewall DoS-policy
    edit 1
        set name "DOS_DETECT_SYN_SWEEP"
        set interface "USERS"
        set srcaddr "all"
        set dstaddr "all"
        set service "ALL"
        config anomaly
            edit "tcp_syn_flood"
                set status enable
                set log enable
                set threshold 10
            next
            edit "tcp_port_scan"
                set status enable
                set log enable
                set threshold 10
            next
            edit "tcp_src_session"
                set threshold 5000
            next
            edit "tcp_dst_session"
                set threshold 5000
            next
            edit "udp_flood"
                set threshold 2000
            next
            edit "udp_scan"
                set threshold 2000
            next
            edit "udp_src_session"
                set threshold 5000
            next
            edit "udp_dst_session"
                set threshold 5000
            next
            edit "icmp_flood"
                set threshold 250
            next
            edit "icmp_sweep"
                set threshold 100
            next
            edit "icmp_src_session"
                set threshold 300
            next
            edit "icmp_dst_session"
                set threshold 1000
            next
            edit "ip_src_session"
                set threshold 5000
            next
            edit "ip_dst_session"
                set threshold 5000
            next
            edit "sctp_flood"
                set threshold 2000
            next
            edit "sctp_scan"
                set threshold 1000
            next
            edit "sctp_src_session"
                set threshold 5000
            next
            edit "sctp_dst_session"
                set threshold 5000
            next
        end
    next
end
```

## Configure Automation Stitch
```fortios
config system automation-action
    edit "ACTION_NOTIFY_N8N_SOAR"
        set action-type webhook
        set minimum-interval 20
        set uri "192.168.10.2/webhook/quarantine"
        set http-body "{\"srcip\": \"%%log.srcip%%\", \"logid\": \"%%log.logid%%\", \"msg\": \"%%log.msg%%\", \"threat\": \"Port Scan / SYN Anomaly Detected\"}"
        set port 80
        config http-headers
            edit 1
                set key "Content-Type"
                set value "application/json"
            next
        end
    next
end

config system automation-trigger
    edit "TRIG_DOS_ANOMALY"
        set event-type anomaly-logs
    next
end

config system automation-stitch
    edit "STITCH_AUTO_QUARANTINE"
        set trigger "TRIG_DOS_ANOMALY"
        config actions
            edit 1
                set action "ACTION_NOTIFY_N8N_SOAR"
                set delay 15
                set required enable
            next
        end
    next
end
```

## Getting the profile, api user, & key for the api user:
```fortios
config system accprofile
    edit "prof_soar_automation"
        set comments "SOAR REST API Profile for Dynamic Quarantine"
        set sysgrp read-write
        set netgrp read-write
        set loggrp read
        set fwgrp read-write
    next
end

config system api-user
    edit "soar-api-admin"
        set comments "n8n SOAR API Integration"
        set api-key ENC SH2yEL0rQO3QE6WR2nIY/9EvR/J+5N+gMtnKGorTi8xfXY3QciIP4otvDrsr7M=
        set accprofile "prof_soar_automation"
        config trusthost
            edit 1
                set ipv4-trusthost 192.168.10.2 255.255.255.255
            next
        end
    next
en

execute api-user generate-key soar-api-admin
New API key: 9qq5nHxbxc80Nt7Nbb6dd5hGfzxjqn
NOTE: The bearer of this API key will be granted all access privileges assigned to the api-user soar-api-admin.
---
```

---

### Zero-Trust Verification Blocker (Stage 5)

Run these diagnostics from the FortiGate CLI (`192.168.10.1`) and Kali (`192.168.10.3`) to confirm end-to-end integration:

#### 1. Verify Neighbor Adjacency (FortiGate CLI)
```fortios
get system arp | grep 192.168.10.2

```

*Verification standard:* `192.168.10.2` must resolve with an active hardware MAC address on `port2`.

#### 2. Arm Real-Time Webhook Packet Sniffer (FortiGate CLI)

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```

*Verification standard:* Keep this terminal open to observe the outbound TCP SYN and HTTP POST packet dispatch when the attack occurs.

#### 3. Trigger Adversary Simulation (Kali CLI - `192.168.10.3`)

```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500

```

*Verification standard:* Initiates the SYN flood matching the DoS anomaly threshold.

#### 4. Confirm Session Drop & Dynamic Address Population (FortiGate CLI)

```fortios
diagnose sys session filter daddr 192.168.10.1
diagnose sys session list
get firewall addrgrp GRP_ACTIVE_QUARANTINE

```

*Verification standard:* `GRP_ACTIVE_QUARANTINE` must now contain `QUAR_192.168.10.3`, and subsequent traffic from `192.168.10.3` will match policy ID 100 (`action=deny`).

When the dynamic quarantine entry is confirmed on FortiOS, reply with:

`"I am done with Stage 5"`
