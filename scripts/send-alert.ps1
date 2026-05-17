param(
    [string]$Subject = "BeachCam Alert",
    [string]$Body = "An alert was triggered."
)

$To = @("josh@roomone.live", "nathan@victorcontractors.co.nz")
$From = "ups@victorcontractors.co.nz"
$SMTPServer = "smtp.safermail.co.nz"
$SMTPPort = 25
$Username = "ups@victorcontractors.co.nz"
$Password = "##VCL2026!!"

$LockFile = "$env:TEMP\beachcam-alert-$([Math]::Abs($Subject.GetHashCode())).lock"
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt 10) { exit 0 }
}
Set-Content -Path $LockFile -Value (Get-Date)

try {
    $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($Username, $securePass)

    Send-MailMessage `
        -To $To `
        -From $From `
        -Subject "[BeachCam] $Subject" `
        -Body "$Body`n`n--`nBeachCam Alert System`n$(Get-Date)" `
        -SmtpServer $SMTPServer `
        -Port $SMTPPort `
        -Credential $credential `
        -ErrorAction Stop

    Write-Host "Alert sent: $Subject"
} catch {
    Write-Host "Failed to send alert: $_"
    Add-Content -Path "C:\BeachCam\logs\alerts.log" -Value "[$(Get-Date)] FAILED to send '$Subject': $_"
}