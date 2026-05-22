$ini = "$env:APPDATA\obs-studio\global.ini"
$log = "C:\BeachCam\logs\start-obs.log"

"[$(Get-Date)] start-obs.ps1 launched" | Add-Content $log

if (-not (Test-Path $ini)) {
    "[$(Get-Date)] ERROR: Cannot find $ini" | Add-Content $log
} else {
    $lines = Get-Content $ini
    $found = $false

    $lines = $lines | ForEach-Object {
        if ($_ -match '^SafeMode=') {
            $found = $true
            'SafeMode=false'
        } else { $_ }
    }

    if (-not $found) {
        $lines = $lines | ForEach-Object {
            $_
            if ($_ -eq '[General]') { 'SafeMode=false' }
        }
    }

    $lines | Set-Content $ini
    "[$(Get-Date)] SafeMode cleared (key was present: $found)" | Add-Content $log
}

Start-Process "C:\Program Files\obs-studio\bin\64bit\obs64.exe" -WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"
