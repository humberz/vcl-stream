# install-services.ps1
# Installs BeachCam watchdog scripts as Windows services using WinSW.
# Run as Administrator.

# Check running as admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Error "Please run as Administrator."
    exit 1
}

$WinSW    = "C:\BeachCam\winsw\WinSW-x64.exe"
$WinSWDir = "C:\BeachCam\winsw"

# Verify WinSW is present
if (-not (Test-Path $WinSW)) {
    Write-Error "WinSW not found at $WinSW. Please download WinSW-x64.exe from https://github.com/winsw/winsw/releases and place it at $WinSW"
    exit 1
}

# Ensure log directory exists
New-Item -ItemType Directory -Force -Path "C:\BeachCam\logs" | Out-Null

function Install-WinSWService {
    param(
        [string]$ServiceId,
        [string]$XmlFile
    )

    $exeName = "$WinSWDir\$ServiceId.exe"
    $xmlPath = "$WinSWDir\$XmlFile"

    Write-Host "Installing $ServiceId..."

    # Copy WinSW exe with service name
    Copy-Item $WinSW $exeName -Force

    # Stop and uninstall if already exists
    $existing = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  Removing existing service..."
        & $exeName stop 2>$null
        & $exeName uninstall 2>$null
        Start-Sleep -Seconds 3
    }

    # Install service
    & $exeName install
    $installResult = $LASTEXITCODE

    if ($installResult -eq 0) {
        Write-Host "  Starting $ServiceId..."
        & $exeName start
        Write-Host "  Done: $ServiceId installed and started."
    } else {
        Write-Error "  Failed to install $ServiceId. Exit code: $installResult"
    }
}

# Install services
Install-WinSWService -ServiceId "BeachCam-VPNWatchdog" -XmlFile "BeachCam-VPNWatchdog.xml"
Start-Sleep -Seconds 5
Install-WinSWService -ServiceId "BeachCam-OBSWatchdog" -XmlFile "BeachCam-OBSWatchdog.xml"

# Summary
Write-Host ""
Write-Host "=== Installation complete ==="
Write-Host ""
Get-Service "BeachCam-*" | Format-Table Name, Status, StartType
Write-Host ""
Write-Host "To manage services:"
Write-Host "  Start:   Start-Service BeachCam-VPNWatchdog"
Write-Host "  Stop:    Stop-Service BeachCam-VPNWatchdog"
Write-Host "  Logs:    Get-Content C:\BeachCam\logs\vpn-watchdog.log -Wait"