<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/docs/vt.md -->
# FortiGate Verification — Visual SOC on FGTQC01 (FortiOS 7.4.12)

Run after `docs/Fortinet-cli.md`. Each check says where to run it and what good output looks like. Container checks live in `scripts/vt.md`.

---

## 1. Configuration review (FortiGate)

```text
show firewall policy | grep -E "^    edit|set name"
show firewall addrgrp SOC-Quarantine
show firewall vip NTFY-TO-SOC
show firewall vip RESPONDER-TO-SOC
show system api-user soc-responder
get log syslogd setting
execute dhcp lease-list
```

**Expect:**
- Policy order **100 SOC_Quarantine_Block → 2 → 3 Kali_To_SOC_Web → 101 Kali_To_Servers_Deny → 4 VIP TO INTERNAL → 102 Kali_To_WAN_Deny**.
- `SOC-Quarantine` → `set member "none"` (plus `Q-<ip>` only while someone is quarantined).
- api-user has `set accprofile "soc-quarantine"` and trusthost `192.168.10.2 255.255.255.255`.
- syslog `status: enable`, `server: 192.168.10.2`, `port: 514`, `source-ip: 192.168.10.1`.
- Lease list: 192.168.10.2 and 192.168.40.3 marked as reserved.

---

## 2. Kali: what it can and cannot reach (run on Kali)

```sh
curl -sI -m 5 http://192.168.10.2 | head -1          # HTTP/1.1 302 Found        (policy 3)
nmap -Pn -p 22,443,3100,8090,8091 192.168.10.2       # all filtered              (policy 101)
curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://1.1.1.1   # 000 (timeout)   (policy 102)
ping -c 2 -W 2 8.8.8.8                                # 100% packet loss          (policy 102)
curl -sk -m 5 https://192.168.40.1                    # no answer: no admin GUI on USERS
```

On the **FortiGate**, prove which policy blocked the WAN attempt:

```text
diagnose debug flow filter clear
diagnose debug flow filter saddr 192.168.40.3
diagnose debug flow filter daddr 1.1.1.1
diagnose debug flow show function-name enable
diagnose debug flow trace start 5
diagnose debug enable
```

Run `curl -m 3 http://1.1.1.1` on Kali, then:

```text
diagnose debug disable
diagnose debug flow trace stop
diagnose debug reset
```

**Expect:** `Denied by forward policy check (policy 102)`. Repeating with `daddr 192.168.10.2` and `nmap -p 22` gives `policy 101`.

---

## 3. Admin PC: the three VIPs

From your PC browser:

| URL | Expect |
|---|---|
| `http://172.24.66.52:8080` | Grafana login → wallboard |
| `http://172.24.66.52:8090/<NTFY_TOPIC>` | ntfy web app; click **Subscribe**, allow notifications |
| `http://172.24.66.52:8091/health` | `{"ok": true, "dry_run": false, ...}` |

(`NTFY_TOPIC` = `grep NTFY_TOPIC /opt/visual-soc-analytics-traffic-dashboard/compose/.env` on Alpine.)

---

## 4. REST API token (run on Alpine)

```sh
cd /opt/visual-soc-analytics-traffic-dashboard/compose && . ./.env
curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $FGT_API_TOKEN" \
  "https://$FGT_HOST/api/v2/cmdb/firewall/addrgrp/SOC-Quarantine?vdom=root"      # 200
curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $FGT_API_TOKEN" \
  "https://$FGT_HOST/api/v2/cmdb/firewall/policy?vdom=root"                      # 403 (profile has no policy rights)
```

The `403` is the least-privilege proof: the token can manage address objects and nothing else.

---

## 5. End-to-end quarantine test

1. On Alpine, fire a test alert (no attack needed):
   ```sh
   docker exec soc-responder wget -q -O- --header 'Content-Type: application/json' --post-data \
    '{"alerts":[{"status":"firing","labels":{"alertname":"Port scan detected","srcip":"192.168.40.3","severity":"high"},"annotations":{"description":"Manual test alert"}}]}' \
    http://127.0.0.1:8092/grafana
   ```
2. On the PC, the ntfy tab shows the alert → click **Quarantine 15 minutes**.
3. ntfy shows **192.168.40.3 quarantined for 15 minutes**.
4. FortiGate:
   ```text
   show firewall addrgrp SOC-Quarantine        # member "none" "Q-192.168.40.3"
   show firewall address Q-192.168.40.3        # subnet 192.168.40.3 255.255.255.255
   ```
5. Kali: `curl -sI -m 5 http://192.168.10.2` now **times out** (it worked in section 2). Flow debug shows `Denied by forward policy check (policy 100)`. Your SSH session to Kali stays up.
6. Wallboard: blocked events with `policy=100 (SOC_Quarantine_Block)` in the live stream.
7. Click **Release now** (or wait 15 min) → ntfy **192.168.40.3 released**; `show firewall addrgrp SOC-Quarantine` is back to `"none"`; `Q-192.168.40.3` is gone; Kali's curl works again.

---

## 6. Real detection

On Kali: `sudo ./kali-attack-campaign.sh --phase 2`. Within ~60 s Grafana's **Port scan detected** fires and the ntfy approval arrives on your PC — same flow as section 5 from step 2.

---

## 7. Symptom → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Port scan alert never fires | Policy 3 still allows ALL, or 101 sits above 3 | Step 6a; order `move 101 after 3` |
| Kali reaches the internet | An older USERS → WAN accept policy exists, or 102 missing | `show firewall policy` — only 102 may match USERS → WAN |
| Quarantine shown in ntfy, Kali still connects | 100 is not first, or responder in DRY-RUN | `move 100 before 2`; `curl :8091/health` → `"dry_run": false` |
| Existing Kali sessions survive the quarantine | `firewall-session-dirty` not `check-all` | `config system settings` → `set firewall-session-dirty check-all` |
| setup.sh: token rejected (401/403) | Wrong key, trusthost, or profile | Re-run `execute api-user generate-key soc-responder`; trusthost 192.168.10.2/32 |
| "Quarantine FAILED … cannot read group" | `SOC-Quarantine` missing | Step 3 |
| ntfy / responder not reachable from the PC | VIP not in policy 4, or source restricted to a different PC IP | `show firewall policy 4`; `diagnose sniffer packet port1 'port 8090 or port 8091' 4 10 l` |
| Buttons work in Kali's browser only | `PUBLIC_RESPONDER_URL` wrong | `.env` must say `http://172.24.66.52:8091` |
| Wallboard empty | Syslog off or wrong source | `diagnose sniffer packet any 'udp and port 514' 4 5 l` |
| VIPs stop working one day | port1 DHCP lease changed | Reserve 172.24.66.52 for port1 on the upstream DHCP server |
