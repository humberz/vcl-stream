$CheckInterval = 60
$StartupDelay = 180
$StreamRetryInterval = 30
$LogFile = "C:\BeachCam\logs\obs-watchdog.log"
$AlertScript = "C:\BeachCam\scripts\send-alert.ps1"
$WSPort = 4455

function Write-Log($msg) {
    $line = "[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $msg
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Is-OBSRunning {
    return (Get-Process -Name "obs64" -ErrorAction SilentlyContinue) -ne $null
}

function Send-OBSRequest($requestType) {
    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $uri = [System.Uri]"ws://localhost:$WSPort"
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(10000)

        $ws.ConnectAsync($uri, $cts.Token).Wait(5000) | Out-Null
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            return $null
        }

        $buffer = New-Object byte[] 8192
        $seg = New-Object System.ArraySegment[byte] (,$buffer)

        # Step 1: Read Hello (op 0)
        $result = $ws.ReceiveAsync($seg, $cts.Token).Result
        $hello = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

        # Step 2: Send Identify (op 1)
        $identify = '{"op":1,"d":{"rpcVersion":1}}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identify)
        $sendSeg = New-Object System.ArraySegment[byte] (,$bytes)
        $ws.SendAsync($sendSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(3000) | Out-Null

        # Step 3: Read Identified (op 2)
        $result = $ws.ReceiveAsync($seg, $cts.Token).Result
        $identified = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

        if ($identified -notmatch '"op":2') {
            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $cts.Token).Wait(3000) | Out-Null
            return $null
        }

        # Step 4: Send request (op 6)
        $request = '{"op":6,"d":{"requestType":"' + $requestType + '","requestId":"req1"}}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $sendSeg = New-Object System.ArraySegment[byte] (,$bytes)
        $ws.SendAsync($sendSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(3000) | Out-Null

        # Step 5: Read response (op 7)
        $result = $ws.ReceiveAsync($seg, $cts.Token).Result
        $response = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $cts.Token).Wait(3000) | Out-Null
        return $response

    } catch {
        return $null
    }
}

function Is-OBSStreaming {
    $response = Send-OBSRequest "GetStreamStatus"
    if ($response -eq $null) { return $false }
    return $response -match '"outputActive":true'
}

function Start-OBSStream {
    for ($i = 1; $i -le 6; $i++) {
        Write-Log "Attempting to start stream (attempt $i of 6)..."
        $response = Send-OBSRequest "StartStream"
        if ($response -ne $null) {
            Write-Log "Start stream command accepted by OBS."
            return $true
        }
        Write-Log "WebSocket not ready - waiting 10s..."
        Start-Sleep -Seconds 10
    }
    Write-Log "Could not start stream after 6 attempts."
    return $false
}

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
Write-Log "OBS watchdog started. Waiting $($StartupDelay)s for system to fully settle..."
Start-Sleep -Seconds $StartupDelay

# Initial stream start with retry loop - keeps trying every 30s until streaming
Write-Log "Attempting initial stream start..."
while (-not (Is-OBSStreaming)) {
    if (-not (Is-OBSRunning)) {
        Write-Log "OBS not running yet - waiting $($StreamRetryInterval)s..."
        Start-Sleep -Seconds $StreamRetryInterval
        continue
    }
    $result = Start-OBSStream
    if (Is-OBSStreaming) {
        Write-Log "Stream started successfully."
        break
    }
    Write-Log "Stream not active yet - retrying in $($StreamRetryInterval)s..."
    Start-Sleep -Seconds $StreamRetryInterval
}

$streamWasDown = $false
$obsWasDown = $false

while ($true) {
    if (-not (Is-OBSRunning)) {
        Write-Log "OBS is not running."
        if (-not $obsWasDown) {
            & $AlertScript -Subject "OBS Not Running" -Body "OBS is not running at $(Get-Date). Please check the machine."
            $obsWasDown = $true
            $streamWasDown = $true
        }
    } elseif (-not (Is-OBSStreaming)) {
        $obsWasDown = $false
        Write-Log "OBS running but not streaming - sending start command."
        if (-not $streamWasDown) {
            & $AlertScript -Subject "Stream Down" -Body "OBS is running but stream stopped at $(Get-Date). Attempting to restart."
            $streamWasDown = $true
        }
        Start-OBSStream | Out-Null
    } else {
        $obsWasDown = $false
        if ($streamWasDown) {
            Write-Log "Stream recovered."
            & $AlertScript -Subject "Stream Recovered" -Body "The stream is back online at $(Get-Date)."
            $streamWasDown = $false
        } else {
            Write-Log "Stream OK."
        }
    }

    Start-Sleep -Seconds $CheckInterval
}