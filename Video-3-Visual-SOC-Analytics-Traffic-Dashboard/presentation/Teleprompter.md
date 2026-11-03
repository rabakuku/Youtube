<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/presentation/Teleprompter.md -->
# Teleprompter — I Attacked My Own SOC

Voiceover for `presentation/PowerPoint.html`. The text below is **identical** to the deck's `scripts` array, cues included.

| Cue | Meaning |
|---|---|
| `[ACTION: Advance to Slide N]` | Click / press → to move to the next slide |
| `[PAUSE]` | One beat of silence |
| `[PUNCH: word]` | Stress that word (shown underlined in yellow in the pop-out prompter) |
| `[B-ROLL: ...]` | Point at, zoom into, or cut to that part of the animated graphic |

Target runtime: about 3–4 minutes of narration (~520 spoken words), before the live demo segment.

## Slide 1 — I Attacked My Own SOC

I attacked my own SOC.  
On purpose.  
And I recorded every second of it.

[PAUSE]  
On the left, a Kali box throws a real attack.  
In the middle, a FortiGate stops it.  
On the right, a free dashboard shows it [PUNCH: live].

By the end, you'll build the whole thing yourself.  
One script. Zero license cost.

## Slide 2 — The Problem

[ACTION: Advance to Slide 2]  
Here's the problem.  
Your FortiGate sees every packet.  
But those logs just scroll past.

[B-ROLL: Point to the scrolling log column]  
During a port scan, you get thousands of lines a minute.  
Nobody reads that.

[B-ROLL: Point to the implicit deny box]  
And the default deny rule?  
It blocks everything. And logs [PUNCH: nothing].

Commercial SIEMs fix this.  
But they bill you by the gigabyte.

## Slide 3 — The End Result

[ACTION: Advance to Slide 3]  
This is where we're going.  
A live wallboard that refreshes every five seconds.

[B-ROLL: Point to the THREAT LEVEL tile]  
This tile goes from green to red.  
It reads [PUNCH: UNDER ATTACK] when the blocks pile up.  
A minute after the attack stops, it's back to all clear.

Below it, you see who attacked.  
What ports they tried.  
And which exploits the IPS caught.

## Slide 4 — The Lab Topology

[ACTION: Advance to Slide 4]  
Here's the lab.  
Three machines. Two VLANs.

[B-ROLL: Point to the Kali node]  
Kali sits in VLAN forty. That's the attack zone.  
Alpine sits in VLAN ten. That's our SIEM.

[B-ROLL: Point to the FortiGate at the top]  
Both VLANs ride one trunk into the FortiGate.  
So every packet between them must pass a [PUNCH: policy].

## Slide 5 — The Data Flow

[ACTION: Advance to Slide 5]  
Now follow one blocked packet.

[B-ROLL: Trace the yellow syslog arrow]  
The FortiGate sends a syslog line to port five one four.  
Vector catches it and parses it.  
Loki stores it.

[B-ROLL: Point to Grafana]  
Grafana asks Loki every five seconds.  
And the panel updates.  
All four tools are [PUNCH: free] and open source.

## Slide 6 — Every Log Gets a Verdict

[ACTION: Advance to Slide 6]  
This part makes the dashboard simple.

[B-ROLL: Point to the raw log line]  
A FortiOS log is just key equals value text.  
Vector turns it into clean JSON.  
Then it adds one field. The verdict.

[B-ROLL: Point to the three colored pills]  
Blocked. Detected. Or allowed.  
A firewall deny and an IPS drop both count as [PUNCH: blocked].  
So every panel speaks the same language.

## Slide 7 — Only Port 80 Gets In

[ACTION: Advance to Slide 7]  
On the FortiGate, the rule is simple.  
One door in. Everything else denied.

[B-ROLL: Point to the green port 80 lane]  
Policy two allows HTTP to the dashboard.  
But the IPS inspects every request.

[B-ROLL: Point to the red lanes]  
Policy three denies the rest.  
And here's the trick. It [PUNCH: logs] every deny.  
That's what feeds the wallboard.

## Slide 8 — One Script Deploy

[ACTION: Advance to Slide 8]  
Deploying it takes one command.

[B-ROLL: Point to the terminal]  
The script checks you're on Alpine.  
It installs Docker only if it's missing.  
Then it pulls Vector, Loki and Grafana.

It even generates your password.  
And it sends a test log through the whole pipeline.  
If you see [PUNCH: self-test passed], you're live.

## Slide 9 — The Attack Campaign

[ACTION: Advance to Slide 9]  
Now the fun part. We attack.

[B-ROLL: Point to phase one]  
Phase one is recon. Who's alive?  
Phase two is a port scan. A thousand ports.  
Only port eighty answers.

[B-ROLL: Point to phase three]  
Phase three goes through that one open door.  
SQL injection. Log4Shell. A web scanner.  
And the IPS [PUNCH: drops] them.

[PAUSE]  
This is my own isolated lab.  
The script refuses any other target.

## Slide 10 — Detection Rules

[ACTION: Advance to Slide 10]  
Dashboards are nice. Alerts are better.

[B-ROLL: Point to the red threshold line]  
This rule counts distinct denied ports per source.  
More than twenty in one minute? That's a scan.  
The alert [PUNCH: fires].

A second rule fires on any IPS hit.  
A third warns you if the logs go quiet.  
Both attack rules map to MITRE ATT&CK.

## Slide 11 — Build It Yourself

[ACTION: Advance to Slide 11]  
Everything is on GitHub.  
The link is in the description.

Scripts. Configs. Dashboards. Alert rules.  
And the attack campaign.

[PAUSE]  
Next time, we close the loop.  
The FortiGate will [PUNCH: quarantine] the attacker automatically.

Subscribe so you don't miss it.  
And go break your own lab. Safely.
