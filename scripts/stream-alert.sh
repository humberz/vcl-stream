#!/bin/bash
# /opt/stream-alert.sh
# Polls SRS API every 30s and emails on OBS drop/recovery.
# Runs as a systemd service alongside stream-monitor.
# Kept separate from stream-monitor.sh so alert logic doesn't affect failover.

POLL_INTERVAL=30
SRS_API="http://127.0.0.1:1985/api/v1/streams/"
RECIPIENTS="josh@roomone.live nathan@victorcontractors.co.nz"

send_alert() {
    local subject="$1"
    local body="$2"
    printf "From: ups@victorcontractors.co.nz\nTo: %s\nSubject: [BeachCam] %s\n\n%s\n\n--\nBeachCam Alert System\n%s\n" \
        "$RECIPIENTS" "$subject" "$body" "$(date)" \
        | msmtp $RECIPIENTS
}

obs_was_down=false

while true; do
    stream_count=$(curl -sf "$SRS_API" | grep -c '"id"' 2>/dev/null || echo 0)

    if [ "$stream_count" -eq 0 ]; then
        if [ "$obs_was_down" = false ]; then
            send_alert "OBS Down - Slate Active" "OBS lost connection at $(date). Fallback slate is now streaming to YouTube."
            obs_was_down=true
        fi
    else
        if [ "$obs_was_down" = true ]; then
            send_alert "OBS Recovered" "OBS reconnected at $(date). Live stream has resumed."
            obs_was_down=false
        fi
    fi

    sleep $POLL_INTERVAL
done
