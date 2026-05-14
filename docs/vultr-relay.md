# Vultr RTMP Relay — Deployment Runbook

Full reference for standing up the relay on a fresh VPS.

## Infrastructure

| | |
|---|---|
| Provider | Vultr Cloud Compute, Sydney |
| OS | Ubuntu 24.04 LTS |
| Spec | 2 vCPU / 4GB RAM / 3TB transfer |
| Server IP | 149.28.163.222 |
| OBS machine IP | 161.29.196.211 |

## Stack

- **SRS** (Simple Realtime Server) v6 — RTMP ingest + YouTube restream via `exec` directive
- **FFmpeg** — bundled inside SRS container at `/usr/local/srs/objs/ffmpeg/bin/ffmpeg`
- **stream-monitor.sh** — bash fallback switcher, runs as a systemd service

## Stream Flow

```
OBS → RTMP (port 1935) → SRS (Docker) → FFmpeg exec → YouTube RTMP
                               ↑
               stream-monitor.sh polls SRS API (port 1985)
               loops slate.mp4 to YouTube if OBS drops
               kills slate and resumes live when OBS reconnects
```

---

## 1. Initial Server Setup

```bash
apt update && apt upgrade -y
apt install -y docker.io curl jq
systemctl enable --now docker
```

## 2. Firewall (UFW)

Lock RTMP and SRS stats ports to the OBS machine IP only. Leave SSH open.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow from 161.29.196.211 to any port 1935   # RTMP ingest
ufw allow from 161.29.196.211 to any port 8080   # SRS HTTP stats
# Port 1985 (SRS API) stays localhost-only — do not open externally
ufw enable
```

## 3. Fallback Slate

```bash
mkdir -p /opt/fallback
# Copy slate.mp4 to the server
scp slate.mp4 root@149.28.163.222:/opt/fallback/slate.mp4
```

The slate is a 4K source downscaled to 2560x1440 at 12 Mbps. Any loopable MP4 at matching resolution/bitrate works.

## 4. SRS Docker Container

```bash
docker run -d \
  --name srs \
  --restart always \
  -p 1935:1935 \
  -p 8080:8080 \
  -p 1985:1985 \
  -v /opt/fallback:/opt/fallback \
  ossrs/srs:6
```

## 5. SRS Config

Write to `/usr/local/srs/conf/docker.conf` inside the container. The easiest way is to exec in and edit, then restart:

```bash
docker exec -it srs bash
# edit /usr/local/srs/conf/docker.conf
exit
docker restart srs
```

**Full config:**

```
listen              1935;
max_connections     100;
daemon              off;
srs_log_tank        console;

http_server {
    enabled         on;
    listen          8080;
}

http_api {
    enabled         on;
    listen          1985;
}

vhost __defaultVhost__ {
    exec {
        enabled on;
        publish /usr/local/srs/objs/ffmpeg/bin/ffmpeg -re -i rtmp://172.17.0.2/live/stream -c:v copy -c:a copy -bufsize 24000k -f flv rtmp://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY;
    }
}
```

> ⚠️ Replace `YOUR-STREAM-KEY`. The IP `172.17.0.2` is the SRS container's own address on the Docker bridge — do not change it.

## 6. Stream Monitor Script

Create `/opt/stream-monitor.sh`:

```bash
#!/bin/bash

API="http://127.0.0.1:1985/api/v1/streams/"
SLATE="/opt/fallback/slate.mp4"
YOUTUBE_RTMP="rtmp://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY"
PID_FILE="/tmp/slate-ffmpeg.pid"
FFMPEG="/usr/bin/ffmpeg"

is_obs_live() {
  count=$(curl -s "$API" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('streams', [])))
except:
    print(0)
" 2>/dev/null)
  [ "${count:-0}" -gt "0" ]
}

start_slate() {
  if [ ! -f "$PID_FILE" ]; then
    $FFMPEG -re -stream_loop -1 -i "$SLATE" \
      -c:v copy -c:a copy -bufsize 24000k \
      -f flv "$YOUTUBE_RTMP" \
      >> /var/log/stream-monitor.log 2>&1 &
    echo $! > "$PID_FILE"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") OBS dropped — slate started (PID $!)" >> /var/log/stream-monitor.log
  fi
}

stop_slate() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    pkill -f "slate.mp4" 2>/dev/null
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") OBS reconnected — slate stopped" >> /var/log/stream-monitor.log
  fi
}

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") stream-monitor started" >> /var/log/stream-monitor.log

while true; do
  if is_obs_live; then
    stop_slate
  else
    start_slate
  fi
  sleep 5
done
```

```bash
chmod +x /opt/stream-monitor.sh
```

> ⚠️ Replace `YOUR-STREAM-KEY` here too. This and the SRS config are the two places the key lives.

## 7. Systemd Service

Create `/etc/systemd/system/stream-monitor.service`:

```ini
[Unit]
Description=Stream monitor — slate fallback for SRS RTMP relay
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/stream-monitor.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/stream-monitor.log
StandardError=append:/var/log/stream-monitor.log

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now stream-monitor
systemctl status stream-monitor
```

## 8. OBS Settings

| | |
|---|---|
| Service | Custom |
| Server | `rtmp://149.28.163.222/live` |
| Stream Key | `stream` |
| Resolution | 2560x1440 |
| Video Bitrate | 12000 Kbps |
| Encoder | NVENC H.264 |
| Keyframe Interval | 2 seconds |

## Useful Commands

```bash
# Check SRS is receiving the stream
curl http://127.0.0.1:1985/api/v1/streams/ | python3 -m json.tool

# Monitor the fallback switcher log
tail -f /var/log/stream-monitor.log

# View SRS container logs
docker logs -f srs

# Restart SRS after config changes
docker restart srs

# Restart stream monitor after script changes
systemctl restart stream-monitor
```

## Rotating the YouTube Stream Key

The key appears in two places — update both before restarting:

1. `/usr/local/srs/conf/docker.conf` → `exec` → `publish` line
2. `/opt/stream-monitor.sh` → `YOUTUBE_RTMP` variable

```bash
docker restart srs
systemctl restart stream-monitor
```
