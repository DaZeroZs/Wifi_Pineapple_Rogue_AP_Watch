# WiFi Pineapple Pager Rogue AP Watch

A display-driven rogue access point detection workflow for the **WiFi Pineapple Pager**.

This setup helps you:

- build a trusted AP allowlist from the Pager display
- continuously monitor nearby APs
- alert when a known SSID appears with an unknown BSSID
- start/stop the watcher directly from the Pager display

The intended use case is defensive monitoring in your own or explicitly authorized environments.

---

## Detection Logic

The watcher compares nearby APs against a local allowlist.

| Detected case | Meaning | Action |
|---|---|---|
| Known SSID + trusted BSSID | Expected AP | No alert |
| Known SSID + unknown BSSID | Possible rogue AP / evil twin | Alert, ringtone, vibration |
| Unknown SSID | Not part of your protected list | Ignored by watcher |
| Same rogue candidate seen again | Already alerted before | No repeated alert until cache is cleared |

Example:

```text
Allowlist:
SSID = xyz
BSSID = b6:9c:6c:70:cf:d1

Detected:
SSID = xyz
BSSID = ff:29:cd:3:22

Result:
ROGUE AP? xyz BSSID ff:29:cd:3:22
```

This does not automatically prove malicious activity. It means a known SSID is being advertised by an unexpected AP radio MAC address.

Common legitimate reasons include mesh nodes, additional enterprise APs, replacement routers, different bands/radios, or infrastructure changes.

---

## Files

This repository contains two installer scripts.

```text
Install.sh
Manage_Allow_List_Install.sh
```

### `Install.sh`

Installs the continuous watcher and display payloads:

```text
/root/rogue-ap-detector/rogue_ap_watchd.sh

/root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh
/root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop/payload.sh
/root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status/payload.sh
/root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen/payload.sh
```

### `Manage_Allow_List_Install.sh`

Installs the display workflow for preparing the allowlist:

```text
/root/payloads/user/rogue-ap-workflow/rogue-ap-workflow/payload.sh
```

This workflow scans nearby APs, stores them as candidates, and lets the user trust or skip them from the Pager display.

---

## Installation

Connect to the Pager over SSH.

```sh
ssh root@172.16.52.1
```

Copy both scripts to the Pager, for example:

```sh
scp Install.sh root@172.16.52.1:/root/
scp Manage_Allow_List_Install.sh root@172.16.52.1:/root/
```

On the Pager, make both scripts executable:

```sh
chmod +x /root/Install.sh
chmod +x /root/Manage_Allow_List_Install.sh
```

Run the allowlist workflow installer:

```sh
/root/Manage_Allow_List_Install.sh
```

Run the watcher installer:

```sh
/root/Install.sh
```

Reboot the Pager:

```sh
reboot
```

After reboot, the new payloads should be available from the Pager display under:

```text
Dashboard → Payloads
```

---

## First-Time Setup

Before starting continuous monitoring, prepare the allowlist.

The allowlist is stored here:

```text
/root/rogue-ap-detector/allowlist.csv
```

Format:

```csv
# SSID,BSSID,COMMENT
xyz,b6:9c:6c:70:cf:d1,Trusted AP
```

Do not blindly trust every AP found during a scan. If a rogue AP is already present during the baseline scan, trusting everything would whitelist the attacker.

---

## Display Workflow: Prepare Allowlist

Open the Pager display:

```text
Dashboard → Payloads → rogue-ap-workflow
```

### Step 1: Scan Baseline

Choose:

```text
Scan baseline
```

The Pager scans nearby APs using `wlan0`.

Expected result:

```text
Scan done: X APs
```

The discovered APs are written to:

```text
/root/rogue-ap-detector/candidates.csv
```

### Step 2: Review Candidates

Run the workflow again:

```text
Dashboard → Payloads → rogue-ap-workflow → Review candidates
```

For each candidate, the display offers:

```text
Show details
Trust this AP
Skip this AP
Move to end
Exit
```

### Candidate Actions

| Action | Meaning | Effect |
|---|---|---|
| Show details | Shows SSID, BSSID, channel, encryption, RSSI | Lets you inspect before deciding |
| Trust this AP | Marks AP as trusted | Adds SSID+BSSID to `allowlist.csv` |
| Skip this AP | Removes from review queue | Does not trust the AP |
| Move to end | Defers decision | Moves AP to end of candidate list |
| Clear candidates | Deletes candidate queue | Does not delete allowlist |
| Clear allowlist | Deletes trusted APs | Use with care |

Because the Pager display is more stable with short payload runs, one run usually processes one AP decision. Repeat:

```text
Dashboard → Payloads → rogue-ap-workflow → Review candidates
```

until no candidates remain or until you have trusted the APs you care about.

---

## Start Continuous Monitoring

After the allowlist is prepared:

```text
Dashboard → Payloads → rogue-ap-watch-start
```

Expected result:

```text
Watcher started PID <number>
```

The watcher now scans every 60 seconds and alerts if a known SSID appears with an unknown BSSID.

---

## Check Watcher Status

From the Pager display:

```text
Dashboard → Payloads → rogue-ap-watch-status
```

Possible results:

```text
Watcher running PID <number>
```

or:

```text
Watcher stopped
```

---

## Stop Continuous Monitoring

From the Pager display:

```text
Dashboard → Payloads → rogue-ap-watch-stop
```

Expected result:

```text
Watcher stopped
```

---

## Clear Alert Memory

The watcher remembers already-alerted rogue candidates to avoid alert spam.

For example, if this pair already triggered once:

```text
xyz|xx:e8:29:cd:3a:23
```

the watcher will not alert repeatedly every 60 seconds.

To allow repeated alerts again:

```text
Dashboard → Payloads → rogue-ap-watch-clear-seen
```

Expected result:

```text
Seen cache cleared
```

---

## Alert Meanings

### `ROGUE AP? <SSID> BSSID <BSSID>`

A known SSID was detected from an unknown BSSID.

Example:

```text
ROGUE AP? xyz BSSID ff:e8:29:cd:3a:22
```

This is the main alert.

Possible meanings:

- evil twin AP
- rogue AP
- new legitimate AP
- mesh node
- replacement router
- different WiFi band/radio
- enterprise infrastructure change

Treat this as suspicious until verified.

### No alert for unknown SSIDs

Unknown SSIDs are ignored by default.

Reason: otherwise the Pager would alert constantly for every nearby home router, hotspot, printer, guest network, or coffee-shop WiFi.

### No repeated alert

If the same suspicious SSID+BSSID pair was already reported, the watcher suppresses repeated alerts.

Use `rogue-ap-watch-clear-seen` to clear this memory.

---

## Recommended Operational Flow

At a new location:

```text
1. Stop watcher if it is running.
2. Payloads → rogue-ap-workflow → Scan baseline.
3. Payloads → rogue-ap-workflow → Review candidates.
4. Trust only APs you can verify.
5. Payloads → rogue-ap-watch-start.
6. Carry/use the Pager.
7. If the Pager alerts, inspect the SSID and BSSID.
8. Stop watcher when finished.
```

---

## Verification over SSH

After starting the watcher, you can verify it over SSH:

```sh
cat /root/rogue-ap-detector/watch.pid
ps | grep rogue_ap_watchd | grep -v grep
tail -n 30 /root/rogue-ap-detector/watch.log
```

Working example:

```text
5867
5867 root 1436 S sh /root/rogue-ap-detector/rogue_ap_watchd.sh
Fri May 22 11:10:34 UTC 2026 watcher started interface=wlan0 interval=60s
```

---

## Important Paths

```text
/root/rogue-ap-detector/allowlist.csv
/root/rogue-ap-detector/candidates.csv
/root/rogue-ap-detector/watch.log
/root/rogue-ap-detector/watch-start.log
/root/rogue-ap-detector/watch.pid
/root/rogue-ap-detector/watch-seen.cache
/tmp/rogue-watch-scan-error.txt
```

---

## Troubleshooting

### Payload does not appear on display

Check the expected nested payload structure:

```sh
find /root/payloads/user -maxdepth 5 -type f -name "payload.sh" -print
```

Expected examples:

```text
/root/payloads/user/rogue-ap-workflow/rogue-ap-workflow/payload.sh
/root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh
/root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop/payload.sh
/root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status/payload.sh
/root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen/payload.sh
```

Fix permissions and line endings:

```sh
find /root/payloads/user -type f -name "payload.sh" -exec sed -i 's/\r$//' {} \;
find /root/payloads/user -type f -name "payload.sh" -exec chmod +x {} \;
reboot
```

### Watcher does not start

Check:

```sh
cat /root/rogue-ap-detector/watch-start.log
cat /root/rogue-ap-detector/watch.log
ps | grep rogue_ap_watchd | grep -v grep
```

Try starting directly:

```sh
/root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh
```

### Watcher says stopped but PID file exists

The PID file may be stale.

```sh
rm -f /root/rogue-ap-detector/watch.pid
```

Start again from the display:

```text
Dashboard → Payloads → rogue-ap-watch-start
```

### Scan failures

Check:

```sh
tail -n 50 /root/rogue-ap-detector/watch.log
cat /tmp/rogue-watch-scan-error.txt
```

Common causes:

- `wlan0` is busy
- another payload is scanning
- Recon or another process is using the radio
- radio/driver temporarily failed the scan

### Baseline scan finds zero APs

Run manually:

```sh
iw dev wlan0 scan | grep -E "^BSS|SSID:|signal:|freq:|DS Parameter" | head -n 40
```

If manual scan works but the display workflow does not, stop Recon and scan again.

---

## Security Notes

This tool does not attack APs or clients. It performs local scanning and allowlist comparison.

The watcher is intended for:

- authorized WiFi monitoring
- lab validation
- defensive rogue AP awareness
- field checks of known SSIDs

Do not use it to monitor networks where you do not have authorization.

---

## Limitations

- The watcher scans every 60 seconds, so short-lived APs may be missed.
- It detects suspicious SSID/BSSID mismatches, not proof of compromise.
- Enterprise WiFi and mesh networks often use many BSSIDs for one SSID.
- A correct allowlist is critical.
- Unknown SSIDs are ignored by default to avoid noise.
- If a rogue AP is trusted during baseline, it becomes allowlisted.

---

## Quick Command Reference

Install:

```sh
chmod +x /root/Manage_Allow_List_Install.sh
chmod +x /root/Install.sh
/root/Manage_Allow_List_Install.sh
/root/Install.sh
reboot
```

Start watcher:

```text
Dashboard → Payloads → rogue-ap-watch-start
```

Stop watcher:

```text
Dashboard → Payloads → rogue-ap-watch-stop
```

Check status:

```text
Dashboard → Payloads → rogue-ap-watch-status
```

Clear repeated-alert memory:

```text
Dashboard → Payloads → rogue-ap-watch-clear-seen
```

Prepare allowlist:

```text
Dashboard → Payloads → rogue-ap-workflow → Scan baseline
Dashboard → Payloads → rogue-ap-workflow → Review candidates
```
