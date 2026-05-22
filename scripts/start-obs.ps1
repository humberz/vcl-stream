$ini = "$env:APPDATA\obs-studio\global.ini"
$obsDir = "$env:APPDATA\obs-studio"
$log = "C:\BeachCam\logs\start-obs.log"

"[$(Get-Date)] start-obs.ps1 launched" | Add-Content $log
"[$(Get-Date)] APPDATA resolves to: $env:APPDATA" | Add-Content $log

# Log all files in obs-studio config dir modified in last 24h
"[$(Get-Date)] Recent files in obs-studio config dir:" | Add-Content $log
Get-ChildItem $obsDir -Recurse -File |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { "  $($_.FullName)  [$($_.LastWriteTime)]" } |
    Add-Content $log

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

    "[$(Get-Date)] global.ini content after write:" | Add-Content $log
    Get-Content $ini | ForEach-Object { "  $_" } | Add-Content $log
}

Start-Process "C:\Program Files\obs-studio\bin\64bit\obs64.exe" -WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"
