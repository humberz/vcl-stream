$CameraIP = "10.0.1.1"
$VPNAdapter = "Local Area Connection"
$CheckInterval = 30
$LogFile = "C:\BeachCam\logs\vpn-watchdog.log"
$AlertScript = "C:\BeachCam\scripts\send-alert.ps1"
$PingCount = 3
$DownSince = $null
$AlertSent = $false

function Write-Log($msg) {
    $line = "[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $msg
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Is-VPNAdapterUp {
    $adapter = Get-NetAdapter -Name $VPNAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    return $adapter -ne $null
}

function Can-ReachCamera {
    return (Test-Connection -ComputerName $CameraIP -Count $PingCount -Quiet -ErrorAction SilentlyContinue)
}

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
Write-Log "VPN watchdog started. Monitoring every $($CheckInterval)s."

while ($true) {
    $isUp = (Is-VPNAdapterUp) -and (Can-ReachCamera)

    if ($isUp) {
        if ($AlertSent) {
            Write-Log "VPN recovered - camera reachable."
            & $AlertScript -Subject "VPN Recovered" -Body "VPN tunnel restored and camera is reachable at $(Get-Date)."
            $AlertSent = $false
        } else {
            Write-Log "VPN OK - camera reachable at $CameraIP."
        }
        $DownSince = $null
    } else {
        if ($DownSince -eq $null) {
            $DownSince = Get-Date
            Write-Log "VPN or camera unreachable - monitoring..."
        } else {
            $downFor = ((Get-Date) - $DownSince).TotalSeconds
            Write-Log "VPN down for $([math]::Round($downFor))s."
            if (-not $AlertSent) {
                & $AlertScript -Subject "VPN Down" -Body "VPN or camera has been unreachable for $([math]::Round($downFor)) seconds at $(Get-Date). OpenVPN Connect may need attention."
                $AlertSent = $true
            }
        }
    }

    Start-Sleep -Seconds $CheckInterval
}