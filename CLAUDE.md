# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VCL STREAM is a production streaming automation system for weather-enabled live beach/lake camera feeds in Takapuna, Auckland. It keeps RTSP camera streams continuously live in OBS with automatic failover, email alerting, and weather/BRB overlays.

## Architecture

### Streaming Pipeline

```
OBS Studio → Vultr RTMP Relay → YouTube Live
```

OBS does not stream directly to YouTube. It pushes to a Vultr RTMP relay server, which restreams to YouTube. This adds a reliability buffer — if the local network blips, the relay can continue serving YouTube while OBS reconnects.

The Vultr relay also has its own BRB screen configured as a fallback. If OBS goes down entirely (not just a source failure), the relay switches to that BRB rather than dropping the YouTube stream.

### Component Details

Three integrated components:

### 1. OBS Lua Script (`scripts/scene-switcher.lua`)
Runs inside OBS Studio. Monitors two RTSP media sources (BeachCam, LakeCam) every 2000ms. On source failure, switches to BRB scene, waits 60s after all sources recover, then switches back to the main scene. Sends email alerts via `send-alert.ps1`. Configuration constants at the top of the file: `MAIN_SCENE`, `BRB_SCENE`, `CHECK_MS`, `RECOVERY_DELAY`, `RESTART_AFTER_S`, `POST_SWITCH_GRACE_S`, `RETURN_OVERLAY_S`, `RETURN_OVERLAY_SOURCE`, `OPENING_TIMEOUT_S`. Source names (`BeachCam`, `LakeCam`) are defined in the `SOURCES` table below the constants.

Key behaviours:
- **Post-switch grace period** (`POST_SWITCH_GRACE_S = 15`): after switching back to main scene, ignores transient source drops for 15s to prevent false BRB triggers during camera reinitialisation.
- **Opening timeout** (`OPENING_TIMEOUT_S = 30`): sources stuck in OPENING/BUFFERING state for more than 30s are treated as failed (prevents cameras booting black with no BRB trigger).
- **Recovery restart**: when cameras first come back healthy on the BRB scene, `obs_source_update` is called to fully reinitialise the RTSP connection (equivalent to clicking OK in source properties). The 60s countdown then starts from a clean connection.
- **Post-switch reinit**: after switching back to the main scene, sources are reinitialised again via `obs_source_update` while they are active in the scene. This is the critical step — reinit on an inactive source does not fix OBS's render state; it must happen while the source is active.
- **Return overlay** (`RETURN_OVERLAY_S = 60`, `RETURN_OVERLAY_SOURCE = "BRBSlide"`): a source named `BRBSlide` (the BRB scene, added to Lake & Beach at the top layer with eye off by default) is made visible for 60s on return from BRB, covering cameras during their post-switch reinit (~15s). Must be set up manually in OBS — see OBS Setup below.
- **Non-blocking alerts**: `send_alert` uses `start "" /b` to launch PowerShell detached, preventing SMTP wait from blocking the Lua timer and expiring the grace period.

### 2. PowerShell Watchdog Services (`scripts/`)
Windows services (via WinSW) that run independently of OBS:
- `obs-watchdog.ps1` — connects to OBS WebSocket v5 (`ws://localhost:4455`), implements the Hello→Identify→Identified handshake, polls `GetStreamStatus`, and calls `StartStream` if streaming has dropped
- `vpn-watchdog.ps1` — pings `10.0.1.1` to check OpenVPN tunnel health; alerts on disconnect
- `send-alert.ps1` — SMTP alerting via `smtp.safermail.co.nz:25` with 10-minute per-type throttling using lock files in `%TEMP%`. Recipients: `josh@roomone.live` and `nathan@victorcontractors.co.nz`.

### 3a. OBS Startup Wrapper (`scripts/start-obs.ps1`)
Not a WinSW service — runs via a Windows desktop shortcut called **OBS Start**. Executes before OBS launches and does three things:
1. **Deletes sentinel files** from `%APPDATA%\obs-studio\.sentinel\` — OBS creates a UUID-named file here at startup and deletes it on clean exit; if it exists at next boot, OBS shows a safe mode prompt requiring manual intervention.
2. **Restores scene collection from .bak** — OBS stores the Lua script list inside the scene collection JSON (`%APPDATA%\obs-studio\basic\scenes\*.json`), not in `global.ini`. A power loss can truncate this file mid-write, removing the script entry. OBS writes a `.bak` of the collection ~51s before updating the primary. The script checks each `.json` for `scene-switcher.lua` and copies the `.bak` over if it's missing. `.bak` restore is preferred over injecting a line because power loss causes structural JSON corruption, not just a missing entry — a partially-truncated file is invalid JSON regardless.
3. **Launches OBS** with `-WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"` — required to resolve OBS's locale files (`locale/en-US.ini`).

Logs to `C:\BeachCam\logs\start-obs.log`.

### 3. Docker Web Overlays (`docker-compose.yml`)
- `weather-overlay` (port 8080) — Nginx serving `html/index.html`: fetches OpenWeatherMap every 10 min, rotates Wind/Feels Like/Humidity stats every 5s, shows a branded ad bug every 30s for 15s. Canvas is 3840×2160 (4K).
- `brb-page` (port 8081) — Nginx serving `brb/index.html`: animated wave icon + rotating dots for the BRB scene

**Camera labels** are overlaid on the 4K canvas in `html/index.html` — Takapuna Beach (top frame, top-left, SSE) and Lake Pupuke (bottom frame, top-left, WNW). Styled with an orange eye icon (`#F6861F` filter) and high-opacity white direction text. Sizes: camera name 27px, direction text 27px, icon 42px.

**All hardcoded paths use `C:\BeachCam\`** as the deployment root. When deploying elsewhere, grep for `C:\BeachCam` in `.ps1`, `.lua`, and WinSW `.xml` files.

**The system runs on a separate stream PC.** Cannot run Docker, services, or browser previews from the dev machine. Deploy files directly to the stream PC to test.

## Commands

### Docker Overlays
```bash
docker-compose up -d
docker-compose ps
docker logs weather-overlay
```

### Windows Services (run as Administrator)
```powershell
# Install
.\scripts\install-services.ps1

# Manage
Get-Service "BeachCam-*"
Start-Service BeachCam-OBSWatchdog
Stop-Service BeachCam-VPNWatchdog

# Live log tailing
Get-Content "C:\BeachCam\logs\obs-watchdog.log" -Wait
Get-Content "C:\BeachCam\logs\vpn-watchdog.log" -Wait
```

### OBS Script
Load `scripts/scene-switcher.lua` via OBS → Tools → Scripts. Debug output goes to the OBS log window.

### OBS Setup Requirements
- **"Restart playback when source becomes active"** must be **unchecked** on both RTSP sources (BeachCam, LakeCam)
- **Return overlay**: in the Lake & Beach scene, add a source → Scene → BRB, rename it `BRBSlide`, place it at the top of the source list, and set it hidden (eye off). The Lua script shows and hides it automatically on recovery.

## Vultr RTMP Relay

**Server:** `149.28.163.222` — Vultr Sydney, Ubuntu 24.04, 2 vCPU / 4GB RAM  
**OBS machine IP:** `161.29.196.211` — UFW locks ports 1935 and 8080 to this IP only

**Stack:** SRS v6 (Simple Realtime Server) in Docker + bundled FFmpeg. SRS's `exec` directive pipes the live RTMP stream to YouTube automatically on publish.

**Fallback:** `stream-monitor.sh` polls the SRS HTTP API (`http://127.0.0.1:1985/api/v1/streams/`) every 5s. If OBS drops, it loops `/opt/fallback/slate.mp4` to YouTube via FFmpeg. When OBS reconnects, it kills the slate process and live feed resumes.

**Key file paths on the server:**
- SRS config: `/usr/local/srs/conf/docker.conf`
- Fallback slate: `/opt/fallback/slate.mp4`
- Monitor script: `/opt/stream-monitor.sh`
- Systemd service: `/etc/systemd/system/stream-monitor.service`

**YouTube stream key lives in two places** — the SRS `exec` directive in `docker.conf` and in `stream-monitor.sh`. Both must be updated together when rotating the key.

See `docs/vultr-relay.md` for the full deployment runbook.

## Technical Reference Document

`docs/technical-reference.html` is a comprehensive A4-structured operations guide covering all system components, commands, configuration, and troubleshooting.

**PDF generation:** The HTML is purpose-built for print — each section is a fixed-height `<div class="page break">` div. To produce a PDF, open the file in Chrome and use **File → Print → Save as PDF**, set margins to **None** (the page CSS handles margins internally via `@page { margin: 16mm; }`), and enable background graphics. Puppeteer/Node.js tooling was removed from the repo.

**Structure:** Cover page (dark, includes TOC), then pages for: System Overview, Architecture Diagram, Stream PC Components, WinSW Services + Vultr Relay, stream-monitor.sh, Start/Stop Reference, Monitoring + Config, OBS Streaming Settings + Email Alerts, Troubleshooting.

**Logo:** `docs/v-logo-white-1000x1000.png` — white PNG used on the dark cover page.

## Key Implementation Notes

- `obs-watchdog.ps1` implements OBS WebSocket v5 manually (op codes 0/1/2/6/7) since there's no native PS WebSocket client library
- Source state values tracked in Lua: `PLAYING`, `OPENING`, `BUFFERING`, `STOPPED`, `ENDED`, `ERROR` — only `PLAYING` is healthy
- Email throttle uses filesystem lock files (`%TEMP%\beachcam-alert-*.lock`) so alerts survive service restarts
- `scripts/archive/scene-switcher-060526.lua` is the previous version (20s restart, simpler state tracking) kept for reference
- `restart_source()` uses `obs_source_update` (not `obs_source_media_restart`) — update forces full source reinitialisation; media_restart only replays and does not fix a broken RTSP render state after NIC reconnect
- "Restart playback when source becomes active" must be **unchecked** on both RTSP sources in OBS
- OBS stores the Lua scripts list inside the **scene collection JSON** (`%APPDATA%\obs-studio\basic\scenes\*.json`), not in `global.ini`. Do not attempt to manage script loading via global.ini — it has no effect and risks corrupting OBS config.
- Do not use PowerShell `Set-Content` to write OBS config files — PS 5.1 defaults to UTF-16 LE, which OBS cannot read. Use `[System.IO.File]::WriteAllLines()` (UTF-8 without BOM) or `Copy-Item` for file operations on OBS config.
