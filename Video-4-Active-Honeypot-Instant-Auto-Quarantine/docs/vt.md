```markdown
# Zero-Trust Verification & Real-Time Diagnostics: FortiOS

Execute these commands in the FortiGate CLI to inspect packet translation, active sessions, and quarantine state.

---

### 1. VIP Configuration & Socket Verification
Confirm that the VIP is active and mapped correctly:
```fortios
get firewall vip VIP_COWRIE_HONEYPOT_2222
show firewall policy 10

```

*Expected Output:*
VIP entry showing `extip 192.168.40.1`, `mappedip 192.168.10.2`, `extport 2222`, and `mappedport 2222`. Policy 10 referencing the VIP as the destination address.

---

### 2. Real-Time Packet Sniffer

Verify arrival of TCP SYN packets on port 2222 from Kali (`192.168.40.3`) and translation toward Alpine (`192.168.10.2`):

```fortios
diagnose sniffer packet any 'host 192.168.40.3 and port 2222' 4 0 l

```

*Expected Output:*
Packets arriving on `port2.40` with `192.168.40.3:XXXXX -> 192.168.40.1:2222` and leaving `port2.10` translated to `192.168.40.3:XXXXX -> 192.168.10.2:2222`.

---
Please run this exact command directly in your Alpine terminal (Node 2) to manually fire the webhook with the -v (verbose) flag:
```fortios
curl -k -v -X POST "https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer Qzrqk80zhscqny1NsgNmgm4dcy1zjx" \
     -d '{"srcip":"192.168.40.3","event":"cowrie.login.failed"}'
```

### 3. Session Table Filtering

Inspect stateful firewall connection tracking for the honeypot session:

```fortios
diagnose sys session filter clear
diagnose sys session filter dport 2222
diagnose sys session list

```

*Expected Output:*
Session showing proto=6, state=ESTABLISHED, and original direction `192.168.40.3 -> 192.168.40.1` rewritten via DNAT to `192.168.10.2`.

---

### 4. Fabric Automation Trigger Validation

Verify incoming webhook registration and test triggering the automation stitch:

```fortios
diagnose automation stitch test STITCH_COWRIE_AUTO_QUARANTINE
diagnose test application autod 2

```

*Expected Output:*
Autod daemon output displaying successful trigger evaluation and execution of `ACT_QUARANTINE_ATTACKER_IP`.

---

### 5. Quarantine Kernel Drop Table

Inspect quarantined IP addresses and clear entries during testing:

```fortios
# List all currently banned/quarantined IPs
diagnose user banned-ip list
```
To delete a specific IP address from the banned list:

```fortios
diagnose user banned-ip delete src4 <IP_ADDRESS>
```



*Expected Output:*
`192.168.40.3` listed in the kernel quarantine table with status `banned`.

```

---

### Zero-Trust Verification Steps (Execute in Chat Before Transition)

Execute the following verification sequences directly on **Node 1 (FortiGate CLI)** before moving forward to Stage 5:

1. **Verify VIP and Policy Binding:**
   ```fortios
   diagnose firewall vip test
   show firewall policy 10

```

*Expected Output:* Policy 10 shows state enabled with source interface `port2.40`, destination interface `port2.10`, and target `VIP_COWRIE_HONEYPOT_2222`.

2. **Verify Automation Stitch Registration:**
```fortios
diagnose automation stitch show STITCH_COWRIE_AUTO_QUARANTINE

```


*Expected Output:* Shows trigger `TRIG_COWRIE_QUARANTINE` mapped to action `ACT_QUARANTINE_ATTACKER_IP` with status `enabled`.
