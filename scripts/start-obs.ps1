$ini = "$env:APPDATA\obs-studio\global.ini"

$lines = Get-Content $ini
$lines = $lines | ForEach-Object {
    if ($_ -match '^SafeMode=') { 'SafeMode=false' } else { $_ }
}
Set-Content $ini $lines

Start-Process "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
