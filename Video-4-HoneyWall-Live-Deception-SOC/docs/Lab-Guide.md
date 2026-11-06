<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/Lab-Guide.md -->
# HoneyWall Lab Guide — one lab, five acts

This guide plays the whole HoneyWall story from start to finish, so you can rehearse it and record it. Each act tells you what to run, what should appear on the dashboard, in ntfy and on the FortiGate, and how to reset for the next one.

| Where | What runs there |
|---|---|
| **Kali console** (192.168.40.3) | `kali-attack-campaign.sh` (the attacker) |
| **Windows PC browser** | HoneyWall `http://172.24.66.58:8080`, ntfy `http://172.24.66.58:8090/honeywall`, FortiGate GUI |
| **Alpine** (SSH via WAN 2222) | `docker compose logs -f engine` (optional on-camera log view) |
| **FortiGate CLI** (optional) | `diagnose user banned-ip list` (the receipt) |

---

## Prerequisites

| Item | How to check | Done in |
|---|---|---|
| Stack running, all healthy | `/opt/honeywall/scripts/setup.sh --status` | Stage 4 |
| Real FortiGate, not rehearsal | Dashboard pill is **green**: *Live from FortiGate … v7.4.13* | Stage 5, block 8 |
| REST ban tested with 203.0.113.250 | Stage 5, block 9 all `success` | Stage 5 |
| Decoys reachable from Kali | `./kali-attack-campaign.sh --act 0` shows two ✔ reachable | Stage 5 |
| Ban list empty | Dashboard *Banned on FortiGate*: "The wall is open." | — |
| (Optional) AI reports | `curl -s -XPOST http://127.0.0.1/api/test/llm` → `"ok": true` | Stage 3, `docs/LLM-Setup.md` |

The decoy content you'll see on camera lives in the repo:

| File | What the attacker sees |
|---|---|
| `compose/userdb.txt` | The only working login: `svc_backup` / `Summer2026!` |
| `compose/honeyfs/home/svc_backup/.bash_history` | Breadcrumbs pointing to the AWS keys |
| `compose/honeyfs/root/.aws/credentials` | The SSH honeytoken (AWS's official *EXAMPLE* keys) |
| `decoy-web/decoy_web.py` | The "Corp Backup Console", `robots.txt`, `/backup/` listing, `.env.bak` web honeytoken |

---

## Before you hit record

- [ ] **Board clean:** click **Reset board** on HoneyWall. This clears the screen; bans and reports are kept.
- [ ] **Ban list empty:** the *Banned on FortiGate* panel shows no IPs. Otherwise click **Unban**.
- [ ] **Siren armed:** click once anywhere on the dashboard (browsers block audio until you do). Check that **Sound** and **Flash** are on.
- [ ] **Theme picked:** press `T` to switch between *hollywood* and *enterprise*.
- [ ] **Layout picked:** `L` switches between *full* (dashboard full-screen) and *split* (half-width next to the Kali console).
- [ ] **AI reports:** the button is on if you want the LLM report in Act 3.
- [ ] **ntfy page open** in a second browser tab, with the topic `honeywall` subscribed.
- [ ] **Kali from the console,** not over SSH. Your SSH session would freeze at the ban (Stage 5, block 11).
- [ ] **Kali preflight passed:** `./kali-attack-campaign.sh --act 0 --yes`. Tools must be installed **before** the first ban, because a banned Kali has no internet.
- [ ] **Terminal font** large enough (Ctrl+Shift++ in the Kali terminal) and the window maximized.
- [ ] **Notifications** on your PC muted, apart from the ntfy tab.
- [ ] **Optional:** an Alpine SSH window running `cd /opt/honeywall/compose && docker compose logs -f --tail=0 engine`.

### Window layouts

| Layout | Left | Right | Use for |
|---|---|---|---|
| **Full** | — | HoneyWall full-screen (1920×1080), `L` → full | The big moments: wall sealing, clock, stamp |
| **Split** | Kali console (VM window, ~50%) | HoneyWall at ~960 px wide, `L` → split | Attacker and defender side by side |
| **Picture-in-picture** | HoneyWall full | Kali as a small overlay in your editor | A clean final cut |

Split layout stacks the panels in priority order: clock → topology → terminal → bans → credentials → timeline → reports.

---

## The script in one line

```bash
./kali-attack-campaign.sh --all          # 0 → 1 → 2 → [Unban] → 3 → [Unban] → 3B → 4, Enter between acts
./kali-attack-campaign.sh --act 3        # one act
./kali-attack-campaign.sh --reset-check  # waits until the FortiGate lets Kali through again
```

Use `--fast` to turn off the typewriter effect, and `--no-pause` for a straight run with no Enter between acts.

---

## Act 0 — Preflight

**Goal:** prove the lab is live before anything happens.

**Run on Kali:** `./kali-attack-campaign.sh --act 0`

**Expected:**

```text
✔ Kali 2026.x
✔ attacker IP 192.168.40.3
✔ tools: nmap hydra sshpass curl nc ssh
✔ decoy SSH  192.168.40.1:22 reachable
✔ decoy web  192.168.40.1:80 reachable
```

**HoneyWall:** the green *Live from FortiGate* pill, the topology all quiet, and "HoneyWall open" under the wall.

**Narration hook:** "Everything you're about to see is real. The firewall on the right is a real FortiGate."

---

## Act 1 — Recon

**Goal:** the attacker finds a server worth attacking. Nothing gets banned.

**Run on Kali:** `--act 1`, which runs `nmap -sV -Pn -p 22,80 192.168.40.1`, then `curl /robots.txt`, then reads the `Server:` header.

**Expected on Kali:**
- `22/tcp open ssh OpenSSH 9.2p1 Debian 2+deb12u3`
- `80/tcp open http nginx 1.22.1`
- `Disallow: /backup/`

**HoneyWall:**
- packets fly Kali → FortiGate → decoy
- the terminal shows `── 192.168.40.3 opened a connection …`, `▲ Probe: connected and left without logging in`, and `http › GET /robots.txt 200`
- the timeline shows **T1046**
- the threat gauge moves a little

**FortiGate (optional):** `diagnose sys session filter src 192.168.40.3` then `diagnose sys session list` shows `act=dnat … (192.168.10.2:2222)`.

**Reset:** none needed.

---

## Act 2 — Brute force (the noisy attacker)

**Goal:** show the threshold rule: **5 failed logins within 30 s** leads to an instant ban.

**Run on Kali:** `--act 2`. Hydra runs against `root`/`admin` with 20 common passwords, printing every attempt.

**Expected on Kali:** `[ATTEMPT] … login "root" - pass "123456"` lines scroll, then stall. The script ends with:

```text
✘ the decoy stopped answering: 192.168.40.3 is QUARANTINED on the FortiGate
```

**HoneyWall, in order:**
1. The credential wall fills with amber `root:123456`, `admin:password` and so on, and the leaderboard grows.
2. The gauge climbs to 100, and the clock starts running.
3. The **honeycomb seals red** across the attacker link, the clock **freezes** (typically under 0.3 s), and the screen flashes **QUARANTINED** with the siren.
4. The *Banned on FortiGate* panel shows `192.168.40.3 · Brute force: 5 failed logins in N s`.
5. A toast appears, then an "Incident report ready" message a few seconds later.

**ntfy:** `QUARANTINED 192.168.40.3 in 0.xx s`, with the rule and a link.

**FortiGate:**
- `diagnose user banned-ip list` shows `192.168.40.3`, with source *Administrative*
- GUI: **Dashboard → Users & Devices → Quarantine**

**Reset:** click **Unban** on HoneyWall. The wall drains, and the terminal shows `□ … released`. On Kali, `--all` waits automatically; with single acts, run `--reset-check`.

**Narration hook:** "The time on that clock is from the fifth wrong password to the FortiGate confirming the ban."

---

## Act 3 — Let them in… slam the door (the stealthy attacker)

**Goal:** a careful attacker with a *valid* password never trips a threshold. HoneyWall lets them in on purpose, watches every keystroke, and bans them the moment they touch the bait.

**Run on Kali:** `--act 3`. It runs `ssh svc_backup@192.168.40.1` with the "leaked" password, then types `whoami`, `id`, `uname -a`, `ls -la`, `cat .bash_history` and `cat /root/.aws/credentials`.

**Expected on Kali:** a real Debian-looking shell, `svc_backup@srv-corp-ssh01:~$`. The `.bash_history` points at `/root/.aws/credentials`, and the AWS keys print. Then the session freezes on the next command, and the script reports:

```text
✘ ssh: the connection died mid-command - the FortiGate is dropping 192.168.40.3
```

That's SSH's own keepalive giving up after about 6 s.

**HoneyWall:**
- **Login SUCCESS svc_backup (LEAKED CREDENTIAL)**: a green chip on the credential wall, tags **T1078** and **T1021.004**
- every command is typed live in the *Attacker terminal*, with tags T1033, T1082, T1083 and T1005
- `cat /root/.aws/credentials` shows the file name highlighted red, then `▲ honeytoken touched`, the **T1552.001** tag, the seal, the clock, the stamp and the siren
- the scoreboard now lists both acts with their times

**Reports and replay:**
- **Incident reports → Read:** with AI reports on, there's an **AI** badge and a plain-English analysis of intent, the timeline, IOCs, MITRE tags and recommended actions. Otherwise it's a template report. **Download .md** saves it.
- **Replay → Play:** the real TTY recording of the session. Use **Speed 4×** on camera.

**Reset:** click **Unban**, then `--reset-check` (or let `--all` wait).

**Narration hook:** "No alarm went off when he logged in. He used a real password. The trap was the file."

---

## Act 3B — Web bait (bonus)

**Goal:** the same idea on a website. The open `/backup/` folder is the trap.

**Run on Kali:** `--act 3b`. It shows the headers, the `/backup/` listing (`.env.bak`, `db_dump.sql`, `nightly.log`), two failed web logins, then `curl /backup/.env.bak`.

**Expected on Kali:** the fake `.env` prints (DB password, AWS *EXAMPLE* keys). The next request times out, and the script ends with `✘ timeout: the web server vanished too`.

**HoneyWall:**
- `http ›` lines in the terminal
- dashed **web** chips on the credential wall
- `▲ honeytoken downloaded over HTTP: /backup/.env.bak`, tags **T1190** and **T1552.001**
- the seal

**Reset:** stay banned for Act 4.

---

## Act 4 — Proof and replay

**Goal:** the receipt. Every door stays shut while the ban stands.

**Run on Kali:** `--act 4`. Six rounds of SSH and HTTP attempts, all `✘ timed out`.

**Show while it runs:**
1. **HoneyWall:** *Banned on FortiGate* (the data comes from the FortiGate REST API every 3 s), the scoreboard with every act's time, and the Replay tab.
2. **FortiGate GUI:** **Dashboard → Users & Devices → Quarantine** shows `192.168.40.3`.
3. **FortiGate CLI:**

   ```fortios
   diagnose user banned-ip list
   diagnose sniffer packet any 'host 192.168.40.3' 4 10 l
   ```

   The sniffer shows only `in` packets on VLAN_QC_40 and nothing goes out. The firewall is dropping them.

**End state:** click **Unban**. The wall drains to "HoneyWall open". ntfy shows `Released 192.168.40.3`.

---

## After the take

| Want to… | Do |
|---|---|
| Record again | **Reset board**, check the ban list is empty, run `--act 0` |
| Keep a report | **Read → Download .md**, or on Alpine `docker compose cp engine:/data/reports/<file>.md .` |
| Show the raw engine log | `docker compose logs --tail=40 engine` (TRIGGER / QUARANTINE / RELEASE lines) |
| Rehearse without Kali | `./setup.sh --simulate on`, then `curl -s -XPOST -d '{"act":"3"}' http://127.0.0.1/api/test/simulate`; `--simulate off` afterwards |

---

## Common mistakes

| Mistake | What you'll see | Fix |
|---|---|---|
| Ran Act 3 while still banned from Act 2 | `ssh: connect … timed out` immediately | **Unban**, then `--reset-check` |
| Kali over SSH | Your terminal freezes at the ban and the recording is lost | Use the Kali VM console; click Unban from the PC |
| Forgot to click the page | No siren | Click once; the "arm the siren" button disappears |
| Rehearsal mode left on | Amber pill *Simulation mode*; Kali never actually blocked | `./setup.sh --simulate off` |
| Act 2 never bans | Fewer than 5 failures inside 30 s (slow network or `-t 1`) | Check `BRUTE_THRESHOLD` / `BRUTE_WINDOW_SEC` in `.env`; `docker compose logs engine \| grep TRIGGER` |
| Act 3 bans at login | `cowrie/userdb.txt` changed, so the failed attempts count | Use the exact `Summer2026!`; run Act 3 after an Unban (counters reset) |
| `192.168.40.1:22` shows the FortiGate banner | `ssh` still in VLAN_QC_40 allowaccess | `docs/Fortinet-cli.md` block 1 |
| Decoys log source 192.168.10.1 | NAT is on in a decoy policy | `set nat disable` (`docs/vt.md` §9) |
| The AI report says "template" | LLM off or unreachable | Turn on **AI reports**; `curl -s -XPOST http://127.0.0.1/api/test/llm` |
| Dashboard shows old files after an update | GitHub raw cache | Wait ~5 min after publishing, then `./setup.sh --update` |
