```markdown
<!-- filepath: docs/Fortinet.md -->
# FortiGate Configuration: Network, Policy, and Syslog Telemetry

## 1. Objective
This stage configures the FortiGate VM (running FortiOS 7.4) inside your "Fortinet Lab in Eve-NG" environment. We will establish the VLAN 10 and VLAN 40 interfaces on `port2`, configure the security policies to allow Kali Linux (`192.168.40.3`) to attack outbound networks and access the SIEM dashboard, and critically, configure the FortiOS logging daemon to stream all event data to our containerized Vector instance (`192.168.10.2:514`).

## 2. Interface and VLAN Configuration
First, we construct the 802.1Q VLAN sub-interfaces on `port2` as mandated by the architecture.

**Execution (CLI):**
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

## 3. Syslog Forwarding to Vector

To build the real-time visual SIEM, FortiOS must forward its internal logs to our Alpine Docker host. Vector is listening on UDP port 514.

**Execution (CLI):**

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

Note: In the FortiGate GUI, you can verify these log settings and targets under the Log and Report section.

## 4. Firewall Policies & Attack Path

We must allow the Kali Linux traffic generator to reach both the internet (for outbound exploit simulation) and the SIEM web interface. We ensure `logtraffic all` is set so every connection generates a syslog event.

**Execution (CLI):**

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

## 5. EVE-NG Packet Capture & Troubleshooting (Optional)

If you need to verify syslog packets are leaving the FortiGate at the hypervisor level, your "Fortinet Lab in Eve-NG" includes an integrated Wireshark capture feature. EVE-NG Filtering uses PACP expression syntax.

* To capture only syslog traffic leaving the FortiGate, you can apply a PACP filter like `udp port 514` in the EVE-NG traffic filter details.


* EVE log files can also be obtained from the System Logs page under the System dropdown menu if you encounter node issues.



```

### Zero-Trust Verification Blocker
Before we move to Stage 6 (Automation & Teardown Shell Scripts), you must verify that the FortiGate is successfully routing traffic and forwarding syslogs to your SIEM host. 

Execute the following commands from your **FortiGate CLI**:

1. **Verify Session Flow to the SIEM:**
   Check if the FortiGate recognizes active sessions directed to your Alpine host.
   ```text
   diagnose sys session filter clear
   diagnose sys session filter daddr 192.168.10.2
   diagnose sys session list

```

*You should see active sessions for UDP 514 (Syslog) and TCP 80 (Grafana Web).*

2. **Verify Packet Level Forwarding:**
Run a real-time sniffer on the trunk port to ensure packets destined for the SIEM web interface are actively traversing the link.
```text
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```


*Generate HTTP traffic from Kali Linux (`192.168.40.3`) to Grafana (`192.168.10.2:80`) while this runs. You should see the TCP handshake and payload data.*
