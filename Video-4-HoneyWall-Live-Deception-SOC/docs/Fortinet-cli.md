<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/Fortinet-cli.md -->
# FortiGate CLI — HoneyWall (FortiOS 7.4.13)

Paste the blocks in order. Each block says what it does and why. Names match `docs/Lab-Matrix.md` exactly. The same configuration as GUI click-paths is in `docs/Fortinet-gui.md`, and the checks are in `docs/vt.md`.

**Assumptions** (taken from the previous Video-4 config):
- single VDOM `root`
- `port1` is WAN (zone `WAN`, IP 172.24.66.58)
- `VLAN_QC_10` and `VLAN_QC_40` on `port2` (zones `SERVERS` / `USERS`)
- HTTPS admin on port 443

If VDOMs are enabled, start each block with `config vdom` / `edit root`, and finish with `end`.

---

## 0. Back up and look before you change

Why: you get a rollback point, and you can confirm the policy IDs before deleting anything.

```fortios
execute backup config ftp honeywall-before.conf <ftp-server> <user> <password>
show firewall policy
show firewall vip
show system automation-stitch
```

Alternatively, back up from the GUI: click the admin name (top right) → Configuration → Backup.

In the output, check that **policy 3** is `USERS TO SERVERS` and **policy 20** is `OUTBOUND_HONEYPOT_WEBHOOK_TO_FGT`. If your IDs differ, use your IDs in block 5.

---

## 1. Interfaces — the decoys own ports 22 and 80 on 192.168.40.1

Why: the VIPs publish the decoys on the Users-side gateway IP, so the FortiGate's own SSH and HTTP admin must not listen there. On `VLAN_QC_10`, only `https` is needed (the engine calls the REST API) plus `ping`. `port1` (your management side) is not touched.

```fortios
config system interface
    edit "VLAN_QC_40"
        set allowaccess ping https
    next
    edit "VLAN_QC_10"
        set allowaccess ping https
    next
end
```

---

## 2. DHCP reservations (recommended)

Why: Alpine (192.168.10.2) and Kali (192.168.40.3) must keep their IPs. The DHCP ranges start exactly at those addresses. Get the MACs first with `diagnose ip arp list | grep -E "192.168.(10.2|40.3) "`.

```fortios
config system dhcp server
    edit 3
        config reserved-address
            edit 1
                set ip 192.168.10.2
                set mac <ALPINE_MAC>
                set description "alpine-docker HoneyWall"
            next
        end
    next
    edit 2
        config reserved-address
            edit 1
                set ip 192.168.40.3
                set mac <KALI_MAC>
                set description "kali-attacker"
            next
        end
    next
end
```

Skip this block if both hosts use static IPs.

---

## 3. Address objects

Why: they're used by the policies and for readability in logs. These already exist from the previous lab; re-applying them is harmless.

```fortios
config firewall address
    edit "NET_SERVERS_VLAN10"
        set subnet 192.168.10.0 255.255.255.0
    next
    edit "NET_USERS_VLAN40"
        set subnet 192.168.40.0 255.255.255.0
    next
    edit "HOST_ALPINE_HONEYPOT"
        set comment "alpine-docker: Cowrie + web decoy + HoneyWall"
        set subnet 192.168.10.2 255.255.255.255
    next
    edit "HOST_KALI_ATTACKER"
        set subnet 192.168.40.3 255.255.255.255
    next
end
```

---

## 4. Virtual IPs

Why: two **decoy** VIPs make the decoys look like real services on the Users gateway. Three **WAN** VIPs let your Windows PC reach HoneyWall, ntfy and Dozzle. The WAN VIPs are bound to `port1`, not `any`, so Kali can never hairpin to the dashboard.

```fortios
config firewall vip
    edit "VIP_HONEYWALL_SSH22"
        set comment "Decoy srv-corp-ssh01: 192.168.40.1:22 -> Cowrie 192.168.10.2:2222"
        set extip 192.168.40.1
        set mappedip "192.168.10.2"
        set extintf "VLAN_QC_40"
        set portforward enable
        set extport 22
        set mappedport 2222
    next
    edit "VIP_HONEYWALL_WEB80"
        set comment "Decoy Corp Backup Console: 192.168.40.1:80 -> 192.168.10.2:8088"
        set extip 192.168.40.1
        set mappedip "192.168.10.2"
        set extintf "VLAN_QC_40"
        set portforward enable
        set extport 80
        set mappedport 8088
    next
    edit "VIP_WAN_HONEYWALL_DASH"
        set comment "HoneyWall dashboard from the PC"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "port1"
        set portforward enable
        set extport 8080
        set mappedport 80
    next
    edit "VIP_WAN_HONEYWALL_NTFY"
        set comment "ntfy alert page from the PC"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "port1"
        set portforward enable
        set extport 8090
        set mappedport 8090
    next
    edit "VIP_WAN_HONEYWALL_DOZZLE"
        set comment "Dozzle container logs (full profile)"
        set extip 172.24.66.58
        set mappedip "192.168.10.2"
        set extintf "port1"
        set portforward enable
        set extport 9999
        set mappedport 9999
    next
end
```

`SSH-TO-Honeypot` (2222 → Alpine:22) and `SSH-TO-KALI` (2223 → Kali:22) stay as they are. They're your management paths.

---

## 5. Firewall policies

Why: the decoy policies allow **only** SSH or HTTP, only to the decoy VIPs. There is **no NAT**, so the decoys see the real attacker IP; that's the IP HoneyWall bans. There are **no security profiles** on purpose: IPS would block the brute force before the honeypot sees it, and the honeypot is the sensor.

The WAN policy is reduced to the five VIPs in use. The old USERS→SERVERS "ALL" policy and the unused webhook policy are deleted.

```fortios
config firewall policy
    edit 4
        set name "WAN_TO_LAB_VIPS"
        set srcintf "WAN"
        set dstintf "SERVERS" "USERS"
        set srcaddr "all"
        set dstaddr "SSH-TO-Honeypot" "SSH-TO-KALI" "VIP_WAN_HONEYWALL_DASH" "VIP_WAN_HONEYWALL_NTFY" "VIP_WAN_HONEYWALL_DOZZLE"
        set action accept
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "PC -> management SSH + HoneyWall/ntfy/Dozzle (tip: restrict srcaddr to your PC subnet)"
    next
    delete 3
    delete 20
    edit 0
        set name "USERS_TO_DECOY_SSH"
        set srcintf "USERS"
        set dstintf "SERVERS"
        set srcaddr "NET_USERS_VLAN40"
        set dstaddr "VIP_HONEYWALL_SSH22"
        set action accept
        set schedule "always"
        set service "SSH"
        set nat disable
        set logtraffic all
        set comments "HoneyWall SSH decoy - no NAT, no profiles (the decoy is the sensor)"
    next
    edit 0
        set name "USERS_TO_DECOY_WEB"
        set srcintf "USERS"
        set dstintf "SERVERS"
        set srcaddr "NET_USERS_VLAN40"
        set dstaddr "VIP_HONEYWALL_WEB80"
        set action accept
        set schedule "always"
        set service "HTTP"
        set nat disable
        set logtraffic all
        set comments "HoneyWall web decoy - no NAT, no profiles"
    next
end
```

`edit 0` creates the policy with the next free ID. Policy 2, `SERVERS TO WAN` (SERVERS + USERS → WAN with NAT), stays unchanged; Alpine needs it for images and the LLM, and Kali for apt. Kali loses it while banned, which is expected.

---

## 6. Remove the previous Video-4 objects

Why: Mattermost, the duplicate `:9001` VIPs, the old `:2222` decoy VIP and the webhook stitch are replaced by HoneyWall's REST ban. Nothing references them after block 5.

```fortios
config firewall vip
    delete "HTTP-TO-Mattermost"
    delete "HTTP-TO-Honeypot"
    delete "HTTP-TO-Dozzle"
    delete "VIP_COWRIE_HONEYPOT_2222"
end
config system automation-stitch
    delete "STITCH_COWRIE_AUTO_QUARANTINE"
end
config system automation-action
    delete "ACT_QUARANTINE_ATTACKER_IP"
end
config system automation-trigger
    delete "TRIG_COWRIE_QUARANTINE"
end
```

If a delete fails with *"entry is used"*, find what still uses it with `diagnose sys cmdb refcnt show firewall.vip.name <name>`.

---

## 7. REST API admin for the HoneyWall engine (least privilege)

Why: the engine needs four things:

| What it does | Endpoint |
|---|---|
| Read the status (the LIVE pill) | `GET /api/v2/monitor/system/status` |
| Ban | `POST /api/v2/monitor/user/banned/add_users` |
| Read the ban back, and unban | `GET /api/v2/monitor/user/banned`, `POST .../clear_users` |
| Optionally close the attacker's open sessions | `POST /api/v2/monitor/firewall/session/close-multiple` |

The key only works from 192.168.10.2.

```fortios
config system accprofile
    edit "PROF_HONEYWALL_API"
        set comments "HoneyWall engine: status, banned IPs, attacker session close"
        set secfabgrp none
        set ftviewgrp none
        set authgrp read-write
        set sysgrp read
        set netgrp none
        set loggrp none
        set fwgrp read
        set vpngrp none
        set utmgrp none
        set wanoptgrp none
        set wifi none
    next
end
config system api-user
    edit "api_honeywall"
        set comments "HoneyWall engine on alpine-docker"
        set accprofile "PROF_HONEYWALL_API"
        set vdom "root"
        config trusthost
            edit 1
                set ipv4-trusthost 192.168.10.2 255.255.255.255
            next
        end
    next
end
execute api-user generate-key api_honeywall
```

The last command prints the token **once**. Copy it straight into the Alpine step below; never paste it into a repo or a chat.

**About the permissions:** on 7.4 the banned-IP list belongs to *User & Authentication* (`authgrp`) and sessions to *Firewall* (`fwgrp`). Block 9 tests every call. If one returns **403**, run this on the FortiGate:

```fortios
diagnose debug application httpsd -1
diagnose debug enable
```

Repeat the call, read which permission is denied, then `diagnose debug disable`. Raise only that group, for example `set fwgrp read-write` if closing sessions needs write access. If you'd rather keep `fwgrp read`, set `FGT_CLOSE_SESSIONS=false` in `.env`; the ban still blocks new packets.

---

## 8. Alpine — switch HoneyWall from rehearsal mode to the real FortiGate

Run on Alpine (192.168.10.2), not on the FortiGate:

```sh
cd /opt/honeywall && ./setup.sh --simulate off        # paste the token at the hidden prompt
./setup.sh --status                                   # engine: "fgt_online": true, "simulate": false
```

The dashboard pill turns green and reads *Live from FortiGate FGT-… · v7.4.13 · NN ms*.

---

## 9. Prove every API call with a harmless test IP (from Alpine)

Why: this verifies the ban, read-back and unban **before** Kali ever gets banned. `203.0.113.250` is a documentation-only address (TEST-NET-3), so banning it can't affect anything.

```sh
cd /opt/honeywall/compose
TOK=$(sed -n 's/^FGT_API_TOKEN=//p' .env); FGT=https://192.168.10.1; Q='?vdom=root'
H="Authorization: Bearer $TOK"
curl -sk -H "$H" "$FGT/api/v2/monitor/system/status$Q" | head -c 250; echo                       # 1. 200, version v7.4.13
curl -sk -H "$H" -X POST "$FGT/api/v2/monitor/user/banned/add_users$Q" \
     -d '{"ip_addresses":["203.0.113.250"],"expiry":0}'; echo                                     # 2. "status":"success"
curl -sk -H "$H" "$FGT/api/v2/monitor/user/banned$Q"; echo                                        # 3. 203.0.113.250 listed
curl -sk -H "$H" -X POST "$FGT/api/v2/monitor/firewall/session/close-multiple$Q" \
     -d '{"saddr":"203.0.113.250"}'; echo                                                         # 4. success (or 403 - see block 7)
curl -sk -H "$H" -X POST "$FGT/api/v2/monitor/user/banned/clear_users$Q" \
     -d '{"ip_addresses":["203.0.113.250"]}'; echo                                                # 5. "status":"success"
curl -sk -H "$H" "$FGT/api/v2/monitor/user/banned$Q"; echo                                        # 6. empty results
```

In step 3, also check the `expires` field. With `expiry: 0`, the entry should be permanent. If 7.4.13 shows a near-future expiry instead, set `BAN_EXPIRY=31536000` (one year) in `.env`. HoneyWall's Unban still clears it instantly.

---

## 10. On the FortiGate: watch the ban list

```fortios
diagnose user banned-ip list
```

This shows banned source IPs, their source ("Administrative" when set through the API) and expiry. To clear by hand: `diagnose user banned-ip delete src4 <ip>`, or `diagnose user banned-ip clear` to remove all. If the keyword differs on your build, `diagnose user ?` lists the options.

In the GUI, the ban shows under **Dashboard → Users & Devices → Quarantine**. That's the on-camera "receipt" for Act 4.

---

## 11. Self-lockout and session test (do this once, off camera)

Why: you need to know what happens to an **already open** session when Kali gets banned. Two cases matter: your management SSH to Kali through WAN 2223, and an attacker session inside the decoy.

1. From your PC: `ssh -p 2223 <kali-user>@172.24.66.58`. In that session, run `ping 192.168.40.1`.
2. From Kali's **VM console**: open a decoy session with `ssh svc_backup@192.168.40.1` (password `Summer2026!`) and leave it at the prompt.
3. From Alpine: ban Kali by hand.

   ```sh
   curl -sk -H "$H" -X POST "$FGT/api/v2/monitor/user/banned/add_users$Q" -d '{"ip_addresses":["192.168.40.3"],"expiry":0}'; echo
   ```

4. Observe and note what happens to each:
   - the PC → Kali SSH session (does it freeze?)
   - the ping inside it
   - the decoy session (does typing still echo?)
5. Release Kali (or click **Unban** on HoneyWall):

   ```sh
   curl -sk -H "$H" -X POST "$FGT/api/v2/monitor/user/banned/clear_users$Q" -d '{"ip_addresses":["192.168.40.3"]}'; echo
   ```

The **expected** result is that all three freeze. The FortiGate drops packets *sourced from* 192.168.40.3, which includes the replies in your WAN 2223 session. The engine also closes the attacker's sessions when `FGT_CLOSE_SESSIONS=true`.

That's why Lab-Matrix §13 says to record the attack from the Kali **console**. HoneyWall's Unban button lives on your PC browser path (WAN → 192.168.10.2), which the ban never touches.

---

## 12. Save

The FortiGate saves configuration changes immediately. Take a new backup for the repo-free record:

```fortios
execute backup config ftp honeywall-after.conf <ftp-server> <user> <password>
```
