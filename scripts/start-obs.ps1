$sentinelDir = "$env:APPDATA\obs-studio\.sentinel"
$scenesDir   = "$env:APPDATA\obs-studio\basic\scenes"
$log         = "C:\BeachCam\logs\start-obs.log"

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

# After power loss, OBS can leave a scene collection JSON partially written,
# losing the Lua script entry. Check each collection and restore from .bak if needed.
Get-ChildItem $scenesDir -Filter "*.json" | Where-Object { $_.Name -notlike "*.bak" } | ForEach-Object {
    $jsonFile = $_.FullName
    $bakFile  = "$jsonFile.bak"
    $content  = Get-Content $jsonFile -Raw -ErrorAction SilentlyContinue

    if ($content -match "scene-switcher\.lua") {
        "[$(Get-Date)] $($_.Name): script entry OK" | Add-Content $log
    } else {
        "[$(Get-Date)] $($_.Name): script entry missing" | Add-Content $log
        if (Test-Path $bakFile) {
            $bakContent = Get-Content $bakFile -Raw -ErrorAction SilentlyContinue
            if ($bakContent -match "scene-switcher\.lua") {
                Copy-Item $bakFile $jsonFile -Force
                "[$(Get-Date)] Restored $($_.Name) from .bak" | Add-Content $log
            } else {
                "[$(Get-Date)] WARNING: $($_.Name).bak also missing script - cannot restore" | Add-Content $log
            }
        } else {
            "[$(Get-Date)] WARNING: No .bak found for $($_.Name)" | Add-Content $log
        }
    }
}

Start-Process "C:\Program Files\obs-studio\bin\64bit\obs64.exe" -WorkingDirectory "C:\Program Files\obs-studio\bin\64bit"
