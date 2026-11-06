<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/vt.md -->
# FortiGate verification & troubleshooting — HoneyWall

These are the FortiGate-side checks for every flow in `docs/Lab-Matrix.md` §6. Alpine and container checks are in `scripts/vt.md`.

## 1. Configuration at a glance

```fortios
get system interface | grep -E "VLAN_QC_(10|40)|port1"
show system interface VLAN_QC_40          # allowaccess ping https  (no ssh/http)
show firewall vip VIP_HONEYWALL_SSH22
show firewall vip VIP_HONEYWALL_WEB80
show firewall policy | grep -f "DECOY"     # USERS_TO_DECOY_SSH / _WEB: nat disable, no profiles
show firewall policy 4                     # WAN_TO_LAB_VIPS with the 5 VIPs
show system api-user api_honeywall         # trusthost 192.168.10.2/32, accprofile PROF_HONEYWALL_API
show system automation-stitch              # empty (the old stitch is gone)
get router info routing-table all          # connected 192.168.10.0/24 + 192.168.40.0/24, default via port1
```

## 2. Sessions (flows F1, F1b)

Start a decoy connection from Kali (`nc -zv 192.168.40.1 22`), then:

```fortios
diagnose sys session filter clear
diagnose sys session filter src 192.168.40.3
diagnose sys session list
```

Expected: `proto=6`, `src 192.168.40.3 → dst 192.168.40.1:22`, `hook=pre dir=org act=dnat 192.168.40.3:x->192.168.40.1:22(192.168.10.2:2222)`, and a `policy_id` that matches `USERS_TO_DECOY_SSH`. **No `act=snat`** — the decoy must see the real IP. Port 80 shows the same pattern with `(192.168.10.2:8088)`.

To see what reached Alpine, use `diagnose sys session filter daddr 192.168.10.2`.

## 3. Packet sniffer

```fortios
diagnose sniffer packet any 'host 192.168.40.3 and (port 22 or port 2222)' 4 20 l
diagnose sniffer packet any 'host 192.168.40.3 and (port 80 or port 8088)' 4 20 l
diagnose sniffer packet VLAN_QC_10 'host 192.168.10.2 and port 443' 4 10 l   # engine -> REST API (F2)
```

Expected before a ban: `VLAN_QC_40 in 192.168.40.3.x -> 192.168.40.1.22`, then `VLAN_QC_10 out 192.168.40.3.x -> 192.168.10.2.2222`, with replies coming back.

**While banned:** only `VLAN_QC_40 in` lines appear and nothing goes out. That's the proof the FortiGate drops the traffic.

Press Ctrl-C to stop.

## 4. Flow debug (why is something dropped?)

```fortios
diagnose debug reset
diagnose debug flow filter addr 192.168.40.3
diagnose debug flow show function-name enable
diagnose debug flow trace start 10
diagnose debug enable
```

Trigger one connection from Kali, then stop:

```fortios
diagnose debug disable
diagnose debug reset
```

How to read the result:

| Message | Meaning |
|---|---|
| `find DNAT: IP-192.168.10.2, port-2222` | The VIP matched |
| `Allowed by Policy-<id>` | The decoy policy matched |
| `Denied by forward policy check (policy 0)` | The implicit deny: a VIP or policy is missing or wrong |
| `... banned` / `blocked by quarantine` | HoneyWall's ban is in effect (the wording varies by build) |

## 5. REST API (flow F2)

From Alpine (`/opt/honeywall/compose`):

```sh
TOK=$(sed -n 's/^FGT_API_TOKEN=//p' .env)
curl -sk -H "Authorization: Bearer $TOK" "https://192.168.10.1/api/v2/monitor/system/status?vdom=root" | head -c 300; echo
curl -sk -H "Authorization: Bearer $TOK" "https://192.168.10.1/api/v2/monitor/user/banned?vdom=root"; echo
```

Expected: HTTP 200 JSON with `"version":"v7.4.13"`, and the ban list.

On the FortiGate, watch API calls arrive:

```fortios
diagnose debug application httpsd -1
diagnose debug enable
```

Then `diagnose debug disable` when done. It shows the user `api_honeywall`, the URL and any permission errors.

## 6. Banned IPs (enforcement)

```fortios
diagnose user banned-ip list                    # 192.168.40.3, source Administrative, expiry
diagnose user banned-ip delete src4 192.168.40.3   # manual unban (HoneyWall notices within 3 s)
```

In the GUI: **Dashboard → Users & Devices → Quarantine** widget.

## 7. Logs

```fortios
execute log filter reset
execute log filter category traffic
execute log filter field srcip 192.168.40.3
execute log display
```

Expected: `action="accept"` entries with `policyname="USERS_TO_DECOY_SSH"` / `"USERS_TO_DECOY_WEB"` before the ban. The REST admin's own changes appear under the event log:

```fortios
execute log filter category event
execute log filter field user api_honeywall
execute log display
```

## 8. Automation

No automation stitch is used: HoneyWall bans through the REST API. `show system automation-stitch` should be empty. If you ever add one back, check it with `diagnose test application autod 1` (stitch stats) and `diagnose debug application autod -1`.

## 9. Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Kali: `192.168.40.1:22` answers with the **FortiGate's** SSH banner | `ssh` still in VLAN_QC_40 allowaccess | `set allowaccess ping https` (CLI block 1) |
| Kali: `:22` or `:80` times out, and Kali is **not** banned | VIP or policy missing, or policy order | Session list / flow debug (sections 2 and 4); `show firewall policy` |
| Decoys log source `192.168.10.1` instead of `192.168.40.3` | NAT enabled on the decoy policy | `set nat disable` on USERS_TO_DECOY_* |
| Hydra gets blocked before Cowrie sees it | An IPS or DoS profile on the decoy policy | Remove the security profiles from USERS_TO_DECOY_* |
| Engine log: `HTTP 401` | Wrong or old token | `execute api-user generate-key api_honeywall`, then `./setup.sh --simulate off` |
| Engine log: `HTTP 403` | Missing permission, or the request didn't come from 192.168.10.2 | httpsd debug (section 5); trusthost; raise only the reported group |
| Engine log: `Cannot connect … 192.168.10.1:443` | HTTPS not allowed on VLAN_QC_10, or admin port isn't 443 | `set allowaccess ping https`; if `admin-sport` ≠ 443, set `FGT_HOST=192.168.10.1:<port>` |
| Ban listed but Kali still connects | An existing session wasn't closed and the build doesn't drop it | Keep `FGT_CLOSE_SESSIONS=true`; check section 2 after the ban; give `fwgrp read-write` if close-multiple returns 403 |
| The ban disappears after a while | `expiry: 0` isn't honoured on this build | `BAN_EXPIRY=31536000` in `.env` |
| PC can't open `http://172.24.66.58:8080` | WAN VIP or policy 4, or the PC isn't on the WAN side | Session list with `filter daddr 192.168.10.2`; `show firewall policy 4` |
| Kali can open the dashboard | A VIP is bound to `any`, or there's an extra USERS→SERVERS rule | WAN VIPs `set extintf "port1"`; only the two decoy policies USERS→SERVERS |
| Your SSH to Kali (2223) froze during a demo | Expected: the ban also drops replies from 192.168.40.3 | Record from the Kali console; Unban from the PC |
