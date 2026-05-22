mkdir -p /root/rogue-ap-detector
mkdir -p /root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start
mkdir -p /root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop
mkdir -p /root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status
mkdir -p /root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen

# ------------------------------------------------------------
# Main watcher daemon
# ------------------------------------------------------------
cat > /root/rogue-ap-detector/rogue_ap_watchd.sh << 'EOF'
#!/bin/sh
# Rogue AP Watcher daemon
# Detects known SSIDs with unknown BSSIDs.

BASE="/root/rogue-ap-detector"
ALLOW="$BASE/allowlist.csv"
LOG="$BASE/watch.log"
SEEN="$BASE/watch-seen.cache"
PIDFILE="$BASE/watch.pid"

INTERFACE="wlan0"
SCAN_INTERVAL="60"

RAW="/tmp/rogue-watch-raw-scan.txt"
TMP="/tmp/rogue-watch-aps.tmp"
ERR="/tmp/rogue-watch-scan-error.txt"

mkdir -p "$BASE"
[ -f "$ALLOW" ] || echo "# SSID,BSSID,COMMENT" > "$ALLOW"
touch "$SEEN"

normalize_mac() {
    echo "$1" | tr 'A-F' 'a-f'
}

is_comment_or_empty() {
    line="$1"
    [ -z "$line" ] && return 0
    echo "$line" | grep -q '^[[:space:]]*#' && return 0
    return 1
}

is_known_ssid() {
    target_ssid="$1"

    while IFS= read -r line; do
        is_comment_or_empty "$line" && continue

        ssid="$(echo "$line" | cut -d',' -f1)"

        if [ "$ssid" = "$target_ssid" ]; then
            return 0
        fi
    done < "$ALLOW"

    return 1
}

is_allowed_pair() {
    target_ssid="$1"
    target_bssid="$(normalize_mac "$2")"

    while IFS= read -r line; do
        is_comment_or_empty "$line" && continue

        ssid="$(echo "$line" | cut -d',' -f1)"
        bssid="$(echo "$line" | cut -d',' -f2 | tr 'A-F' 'a-f')"

        if [ "$ssid" = "$target_ssid" ] && [ "$bssid" = "$target_bssid" ]; then
            return 0
        fi
    done < "$ALLOW"

    return 1
}

already_alerted() {
    key="$1"
    grep -Fxq "$key" "$SEEN"
}

mark_alerted() {
    key="$1"
    echo "$key" >> "$SEEN"
}

parse_scan() {
    awk '
    BEGIN {
        bssid="";
        ssid="";
        signal="";
        channel="";
        freq="";
        enc="OPEN";
    }

    /^BSS / {
        if (bssid != "" && ssid != "") {
            print ssid "," bssid "," channel "," freq "," enc "," signal
        }

        bssid=$2
        gsub(/\(.*/, "", bssid)

        ssid="";
        signal="";
        channel="";
        freq="";
        enc="OPEN";
    }

    /^[ \t]*SSID:/ {
        ssid=substr($0, index($0, "SSID:") + 6)
    }

    /^[ \t]*signal:/ {
        signal=$2
    }

    /^[ \t]*freq:/ {
        freq=$2
    }

    /^[ \t]*DS Parameter set:/ {
        channel=$5
    }

    /^[ \t]*RSN:/ {
        if (enc == "OPEN") enc="WPA2/WPA3"
    }

    /^[ \t]*WPA:/ {
        if (enc == "OPEN") enc="WPA/WPA2"
    }

    END {
        if (bssid != "" && ssid != "") {
            print ssid "," bssid "," channel "," freq "," enc "," signal
        }
    }
    ' "$RAW" > "$TMP"
}

alert_rogue() {
    ssid="$1"
    bssid="$2"
    channel="$3"
    enc="$4"
    rssi="$5"

    msg="ROGUE AP? $ssid BSSID $bssid"

    echo "$(date) $msg CH=$channel ENC=$enc RSSI=$rssi" >> "$LOG"

    ALERT "$msg"
    RINGTONE "Alarm:d=4,o=5,b=180:c6,c6,c6,8p,c6,c6,c6"
    VIBRATE "Buzz:d=4,o=5,b=180:c,c,c,8p,c,c,c"
}

echo $$ > "$PIDFILE"
echo "$(date) watcher started interface=$INTERFACE interval=${SCAN_INTERVAL}s" >> "$LOG"

while true; do
    iw dev "$INTERFACE" scan > "$RAW" 2> "$ERR"
    RC="$?"

    if [ "$RC" != "0" ]; then
        ERRMSG="$(cat "$ERR" 2>/dev/null | head -c 120)"
        echo "$(date) scan failed rc=$RC error=$ERRMSG" >> "$LOG"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    if ! grep -q '^BSS ' "$RAW"; then
        echo "$(date) scan returned no BSS entries" >> "$LOG"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    parse_scan

    while IFS=',' read -r ssid bssid channel freq enc rssi; do
        [ -z "$ssid" ] && continue
        [ -z "$bssid" ] && continue

        bssid_lc="$(normalize_mac "$bssid")"

        if is_known_ssid "$ssid"; then
            if ! is_allowed_pair "$ssid" "$bssid_lc"; then
                key="$ssid|$bssid_lc"

                if ! already_alerted "$key"; then
                    mark_alerted "$key"
                    alert_rogue "$ssid" "$bssid_lc" "$channel" "$enc" "$rssi"
                else
                    echo "$(date) already alerted SSID=$ssid BSSID=$bssid_lc" >> "$LOG"
                fi
            fi
        fi
    done < "$TMP"

    sleep "$SCAN_INTERVAL"
done
EOF

# ------------------------------------------------------------
# Start payload
# ------------------------------------------------------------
cat > /root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh << 'EOF'
#!/bin/sh
# Title: Start Rogue Watch
# Description: Starts rogue AP watcher directly
# Author: local

BASE="/root/rogue-ap-detector"
WATCHER="$BASE/rogue_ap_watchd.sh"
PIDFILE="$BASE/watch.pid"
STARTLOG="$BASE/watch-start.log"

mkdir -p "$BASE"

echo "$(date) direct start payload executed" >> "$STARTLOG"

if ps | grep "rogue_ap_watchd.sh" | grep -v grep >/dev/null 2>&1; then
    pid="$(ps | grep "rogue_ap_watchd.sh" | grep -v grep | awk '{print $1}' | head -n 1)"
    echo "$pid" > "$PIDFILE"
    ALERT "Watcher already running"
    exit 0
fi

if [ ! -f "$WATCHER" ]; then
    ALERT "Watcher script missing"
    echo "$(date) missing watcher script: $WATCHER" >> "$STARTLOG"
    exit 0
fi

sed -i 's/\r$//' "$WATCHER"
chmod +x "$WATCHER"

rm -f "$PIDFILE"

sh "$WATCHER" >> "$STARTLOG" 2>&1 &

sleep 3

if ps | grep "rogue_ap_watchd.sh" | grep -v grep >/dev/null 2>&1; then
    pid="$(ps | grep "rogue_ap_watchd.sh" | grep -v grep | awk '{print $1}' | head -n 1)"
    echo "$pid" > "$PIDFILE"
    ALERT "Watcher started PID $pid"
    echo "$(date) watcher started pid=$pid" >> "$STARTLOG"
else
    ALERT "Watcher failed"
    echo "$(date) watcher failed to stay running" >> "$STARTLOG"
fi

exit 0
EOF

# ------------------------------------------------------------
# Stop payload
# ------------------------------------------------------------
cat > /root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop/payload.sh << 'EOF'
#!/bin/sh
# Title: Stop Rogue Watch
# Description: Stops rogue AP watcher directly
# Author: local

BASE="/root/rogue-ap-detector"
PIDFILE="$BASE/watch.pid"
STARTLOG="$BASE/watch-start.log"

mkdir -p "$BASE"

echo "$(date) direct stop payload executed" >> "$STARTLOG"

ps | grep "rogue_ap_watchd.sh" | grep -v grep | awk '{print $1}' | while read -r pid; do
    kill "$pid" 2>/dev/null
done

sleep 1

ps | grep "rogue_ap_watchd.sh" | grep -v grep | awk '{print $1}' | while read -r pid; do
    kill -9 "$pid" 2>/dev/null
done

rm -f "$PIDFILE"

ALERT "Watcher stopped"
exit 0
EOF

# ------------------------------------------------------------
# Status payload
# ------------------------------------------------------------
cat > /root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status/payload.sh << 'EOF'
#!/bin/sh
# Title: Rogue Watch Status
# Description: Shows rogue AP watcher status
# Author: local

BASE="/root/rogue-ap-detector"
PIDFILE="$BASE/watch.pid"
LOG="$BASE/watch.log"

if ps | grep "rogue_ap_watchd.sh" | grep -v grep >/dev/null 2>&1; then
    pid="$(ps | grep "rogue_ap_watchd.sh" | grep -v grep | awk '{print $1}' | head -n 1)"
    echo "$pid" > "$PIDFILE"
    ALERT "Watcher running PID $pid"
else
    rm -f "$PIDFILE"
    ALERT "Watcher stopped"
fi

exit 0
EOF

# ------------------------------------------------------------
# Clear seen cache payload
# ------------------------------------------------------------
cat > /root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen/payload.sh << 'EOF'
#!/bin/sh
# Title: Clear Rogue Watch Seen
# Description: Allows repeated alerts for previously seen rogue candidates
# Author: local

BASE="/root/rogue-ap-detector"
SEEN="$BASE/watch-seen.cache"

mkdir -p "$BASE"

: > "$SEEN"

ALERT "Seen cache cleared"
exit 0
EOF

# ------------------------------------------------------------
# Permissions and line endings
# ------------------------------------------------------------
sed -i 's/\r$//' /root/rogue-ap-detector/rogue_ap_watchd.sh
sed -i 's/\r$//' /root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh
sed -i 's/\r$//' /root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop/payload.sh
sed -i 's/\r$//' /root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status/payload.sh
sed -i 's/\r$//' /root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen/payload.sh

chmod +x /root/rogue-ap-detector/rogue_ap_watchd.sh
chmod +x /root/payloads/user/rogue-ap-watch-start/rogue-ap-watch-start/payload.sh
chmod +x /root/payloads/user/rogue-ap-watch-stop/rogue-ap-watch-stop/payload.sh
chmod +x /root/payloads/user/rogue-ap-watch-status/rogue-ap-watch-status/payload.sh
chmod +x /root/payloads/user/rogue-ap-watch-clear-seen/rogue-ap-watch-clear-seen/payload.sh

echo "Install complete. Reboot recommended."
