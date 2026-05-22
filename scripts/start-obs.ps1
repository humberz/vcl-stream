$ini = "$env:APPDATA\obs-studio\global.ini"
$sentinelDir = "$env:APPDATA\obs-studio\.sentinel"
$log = "C:\BeachCam\logs\start-obs.log"

"[$(Get-Date)] start-obs.ps1 launched" | Add-Content $log

# Clear sentinel files (OBS creates these at startup, removes on clean exit;
# if present at next boot it triggers the safe mode prompt)
if (Test-Path $sentinelDir) {
    Get-ChildItem $sentinelDir -File | ForEach-Object {
        Remove-Item $_.FullName -Force
        "[$(Get-Date)] Deleted sentinel: $($_.Name)" | Add-Content $log
    }
} else {
    "[$(Get-Date)] No sentinel dir found" | Add-Content $log
}

# Also clear SafeMode flag in global.ini as a belt-and-suspenders measure
if (Test-Path $ini) {
    $lines = Get-Content $ini
    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match '^SafeMode=') { $found = $true; 'SafeMode=false' } else { $_ }
    }
    if (-not $found) {
        $lines = $lines | ForEach-Object {
            $_
            if ($_ -eq '[General]') { 'SafeMode=false' }
        }
    }
    $lines | Set-Content $ini
    "[$(Get-Date)] SafeMode cleared in global.ini (key was present: $found)" | Add-Content $log
}

Start-Process "C:\Program Files\obs-studio\bin\64bit\obs64.exe" -WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"
