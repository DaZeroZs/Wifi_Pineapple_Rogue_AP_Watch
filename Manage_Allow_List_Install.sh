mkdir -p /root/rogue-ap-detector
mkdir -p /root/payloads/user/rogue-ap-workflow/rogue-ap-workflow

cat > /root/payloads/user/rogue-ap-workflow/rogue-ap-workflow/payload.sh << 'EOF'
#!/bin/sh
# Title: Rogue AP Workflow
# Description: Display-only AP baseline scan, candidate review, and allowlist preparation
# Author: local

BASE="/root/rogue-ap-detector"
CAND="$BASE/candidates.csv"
ALLOW="$BASE/allowlist.csv"
LOG="$BASE/workflow.log"

INTERFACE="wlan0"

RAW="/tmp/rogue-ap-raw-scan.txt"
TMP="/tmp/rogue-ap-candidates.tmp"
ERR="/tmp/rogue-ap-scan-error.txt"

mkdir -p "$BASE"

ensure_files() {
    [ -f "$ALLOW" ] || echo "# SSID,BSSID,COMMENT" > "$ALLOW"
    [ -f "$CAND" ] || echo "# SSID,BSSID,CHANNEL,FREQ,ENCRYPTION,RSSI,FIRST_SEEN,COMMENT" > "$CAND"
}

candidate_count() {
    grep -vc '^#' "$CAND" 2>/dev/null
}

allow_count() {
    grep -vc '^#' "$ALLOW" 2>/dev/null
}

first_candidate() {
    grep -v '^#' "$CAND" | head -n 1
}

remove_first_candidate() {
    TMPFILE="/tmp/candidates-new.csv"
    {
        grep '^#' "$CAND" | head -n 1
        grep -v '^#' "$CAND" | tail -n +2
    } > "$TMPFILE"
    mv "$TMPFILE" "$CAND"
}

rotate_first_candidate() {
    FIRST="$(first_candidate)"
    [ -z "$FIRST" ] && return

    TMPFILE="/tmp/candidates-rotated.csv"
    {
        grep '^#' "$CAND" | head -n 1
        grep -v '^#' "$CAND" | tail -n +2
        echo "$FIRST"
    } > "$TMPFILE"
    mv "$TMPFILE" "$CAND"
}

is_allowed() {
    ssid="$1"
    bssid="$(echo "$2" | tr 'A-F' 'a-f')"

    grep -i -q "^$ssid,$bssid," "$ALLOW"
}

trust_candidate_line() {
    line="$1"

    SSID="$(echo "$line" | cut -d',' -f1)"
    BSSID="$(echo "$line" | cut -d',' -f2 | tr 'A-F' 'a-f')"
    CH="$(echo "$line" | cut -d',' -f3)"
    FREQ="$(echo "$line" | cut -d',' -f4)"
    ENC="$(echo "$line" | cut -d',' -f5)"
    RSSI="$(echo "$line" | cut -d',' -f6)"

    if [ -z "$SSID" ] || [ -z "$BSSID" ]; then
        ALERT "Invalid candidate"
        echo "$(date) invalid candidate line=$line" >> "$LOG"
        return
    fi

    if is_allowed "$SSID" "$BSSID"; then
        ALERT "Already trusted"
        echo "$(date) already trusted SSID=$SSID BSSID=$BSSID" >> "$LOG"
        remove_first_candidate
        return
    fi

    echo "$SSID,$BSSID,Trusted from display CH=$CH FREQ=$FREQ ENC=$ENC RSSI=$RSSI" >> "$ALLOW"
    echo "$(date) trusted SSID=$SSID BSSID=$BSSID CH=$CH FREQ=$FREQ ENC=$ENC RSSI=$RSSI" >> "$LOG"

    ALERT "Trusted: $SSID"
    remove_first_candidate
}

scan_baseline() {
    ensure_files

    resp=$(CONFIRMATION_DIALOG "Scan nearby APs now?") || exit 0

    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        ALERT "Scan cancelled"
        exit 0
    fi

    rm -f "$RAW" "$TMP" "$ERR"

    echo "$(date) Starting baseline scan on $INTERFACE" >> "$LOG"

    iw dev "$INTERFACE" scan > "$RAW" 2> "$ERR"
    RC="$?"

    if [ "$RC" != "0" ]; then
        ERRMSG="$(cat "$ERR" 2>/dev/null | head -c 90)"
        [ -z "$ERRMSG" ] && ERRMSG="no error text"
        ALERT "Scan failed rc=$RC"
        echo "$(date) scan failed rc=$RC error=$ERRMSG" >> "$LOG"
        exit 0
    fi

    if ! grep -q '^BSS ' "$RAW"; then
        ALERT "No BSS entries"
        echo "$(date) scan returned no BSS entries" >> "$LOG"
        exit 0
    fi

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

    COUNT="$(grep -c '^[^#]' "$TMP" 2>/dev/null)"

    if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
        ALERT "Parsed 0 APs"
        echo "$(date) parser found 0 APs" >> "$LOG"
        exit 0
    fi

    {
        echo "# SSID,BSSID,CHANNEL,FREQ,ENCRYPTION,RSSI,FIRST_SEEN,COMMENT"
        sort -u "$TMP" | while IFS= read -r line; do
            echo "$line,$(date '+%Y-%m-%d %H:%M:%S'),review-needed"
        done
    } > "$CAND"

    echo "$(date) baseline scan finished: $COUNT APs" >> "$LOG"

    ALERT "Scan done: $COUNT APs"
    exit 0
}

review_candidates() {
    ensure_files

    COUNT="$(candidate_count)"
    [ -z "$COUNT" ] && COUNT=0

    if [ "$COUNT" = "0" ]; then
        ALERT "No candidates"
        exit 0
    fi

    LINE="$(first_candidate)"

    SSID="$(echo "$LINE" | cut -d',' -f1)"
    BSSID="$(echo "$LINE" | cut -d',' -f2)"
    CH="$(echo "$LINE" | cut -d',' -f3)"
    FREQ="$(echo "$LINE" | cut -d',' -f4)"
    ENC="$(echo "$LINE" | cut -d',' -f5)"
    RSSI="$(echo "$LINE" | cut -d',' -f6)"

    choice=$(LIST_PICKER "Review $COUNT APs" \
        "Show details" \
        "Trust this AP" \
        "Skip this AP" \
        "Move to end" \
        "Exit" \
        "Show details") || exit 0

    case "$choice" in
        "Show details")
            PROMPT "$SSID $BSSID CH:$CH $ENC RSSI:$RSSI"
            resp=$(CONFIRMATION_DIALOG "Trust this AP?") || exit 0

            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                trust_candidate_line "$LINE"
            else
                ALERT "Not trusted"
            fi
            exit 0
            ;;

        "Trust this AP")
            resp=$(CONFIRMATION_DIALOG "Confirm trust $SSID?") || exit 0

            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                trust_candidate_line "$LINE"
            else
                ALERT "Cancelled"
            fi
            exit 0
            ;;

        "Skip this AP")
            resp=$(CONFIRMATION_DIALOG "Remove candidate?") || exit 0

            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                remove_first_candidate
                ALERT "Skipped"
                echo "$(date) skipped SSID=$SSID BSSID=$BSSID" >> "$LOG"
            else
                ALERT "Cancelled"
            fi
            exit 0
            ;;

        "Move to end")
            rotate_first_candidate
            ALERT "Moved to end"
            exit 0
            ;;

        *)
            exit 0
            ;;
    esac
}

show_summary() {
    ensure_files

    CCOUNT="$(candidate_count)"
    ACOUNT="$(allow_count)"

    [ -z "$CCOUNT" ] && CCOUNT=0
    [ -z "$ACOUNT" ] && ACOUNT=0

    ALERT "Candidates: $CCOUNT Trusted: $ACOUNT"
    exit 0
}

show_first_candidate() {
    ensure_files

    LINE="$(first_candidate)"

    if [ -z "$LINE" ]; then
        ALERT "No candidates"
        exit 0
    fi

    SSID="$(echo "$LINE" | cut -d',' -f1)"
    BSSID="$(echo "$LINE" | cut -d',' -f2)"
    CH="$(echo "$LINE" | cut -d',' -f3)"
    ENC="$(echo "$LINE" | cut -d',' -f5)"
    RSSI="$(echo "$LINE" | cut -d',' -f6)"

    PROMPT "$SSID $BSSID CH:$CH $ENC RSSI:$RSSI"
    exit 0
}

show_allowlist_count() {
    ensure_files

    ACOUNT="$(allow_count)"
    [ -z "$ACOUNT" ] && ACOUNT=0

    ALERT "Trusted APs: $ACOUNT"
    exit 0
}

clear_candidates() {
    ensure_files

    resp=$(CONFIRMATION_DIALOG "Clear candidate list?") || exit 0

    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        echo "# SSID,BSSID,CHANNEL,FREQ,ENCRYPTION,RSSI,FIRST_SEEN,COMMENT" > "$CAND"
        ALERT "Candidates cleared"
        echo "$(date) candidates cleared" >> "$LOG"
    else
        ALERT "Cancelled"
    fi

    exit 0
}

clear_allowlist() {
    ensure_files

    resp=$(CONFIRMATION_DIALOG "Clear trusted allowlist?") || exit 0

    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        echo "# SSID,BSSID,COMMENT" > "$ALLOW"
        ALERT "Allowlist cleared"
        echo "$(date) allowlist cleared" >> "$LOG"
    else
        ALERT "Cancelled"
    fi

    exit 0
}

debug_last_scan() {
    RAW_LINES="$(wc -l "$RAW" 2>/dev/null | awk "{print \$1}")"
    BSS_COUNT="$(grep -c '^BSS ' "$RAW" 2>/dev/null)"
    ERR_TEXT="$(cat "$ERR" 2>/dev/null | head -c 60)"

    [ -z "$RAW_LINES" ] && RAW_LINES=0
    [ -z "$BSS_COUNT" ] && BSS_COUNT=0
    [ -z "$ERR_TEXT" ] && ERR_TEXT="noerr"

    PROMPT "Raw:$RAW_LINES BSS:$BSS_COUNT Err:$ERR_TEXT"
    exit 0
}

show_help() {
    PROMPT "Flow: Scan baseline. Review candidates. Trust only known APs. Start Rogue Watch."
    exit 0
}

ensure_files

choice=$(LIST_PICKER "Rogue AP Setup" \
    "Scan baseline" \
    "Review candidates" \
    "Show summary" \
    "Show first candidate" \
    "Trusted count" \
    "Debug last scan" \
    "Clear candidates" \
    "Clear allowlist" \
    "Help" \
    "Exit" \
    "Review candidates") || exit 0

case "$choice" in
    "Scan baseline")
        scan_baseline
        ;;
    "Review candidates")
        review_candidates
        ;;
    "Show summary")
        show_summary
        ;;
    "Show first candidate")
        show_first_candidate
        ;;
    "Trusted count")
        show_allowlist_count
        ;;
    "Debug last scan")
        debug_last_scan
        ;;
    "Clear candidates")
        clear_candidates
        ;;
    "Clear allowlist")
        clear_allowlist
        ;;
    "Help")
        show_help
        ;;
    *)
        exit 0
        ;;
esac

exit 0
EOF

sed -i 's/\r$//' /root/payloads/user/rogue-ap-workflow/rogue-ap-workflow/payload.sh
chmod +x /root/payloads/user/rogue-ap-workflow/rogue-ap-workflow/payload.sh

echo "Rogue AP allowlist workflow installed."
