# Install paddock-guestd in this Windows guest: C:\Program Files\paddock\paddock-guestd.exe, run as
# SYSTEM by the Windows service paddock-guestd, which starts at boot, and which the service manager
# starts again a second after it dies or stops with an error. Run it once in the golden image, from
# this folder, in an elevated PowerShell: powershell -ExecutionPolicy Bypass -File install.ps1
#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# The processor's own architecture: a PowerShell under x64 emulation reports AMD64 in its
# environment even on Arm. 12 is ARM64.
if ((Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture -ne 12) {
    throw "paddock's guest agent is built for Windows on Arm, and this isn't Windows on Arm"
}
$name = "paddock-guestd"
$dir = Join-Path $env:ProgramFiles "paddock"
$exe = Join-Path $dir "$name.exe"

function Invoke-Sc {
    sc.exe @args | Out-Null
    if ($LASTEXITCODE) { throw "sc.exe $args failed with $LASTEXITCODE" }
}

# A running agent holds its file open, so stop it before replacing it. Agents before 0.5.0 ran
# from a scheduled task, which the service replaces.
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}
$service = Get-Service -Name $name -ErrorAction SilentlyContinue
if ($service) { Stop-Service -Name $name -Force }
Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
Wait-Process -Name $name -Timeout 10 -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot "$name.exe") $exe -Force
# A file downloaded or copied from another machine may carry the mark of the web.
Unblock-File $exe

if ($service) {
    Invoke-Sc config $name binPath= "`"$exe`"" start= auto
} else {
    New-Service -Name $name -BinaryPathName "`"$exe`"" -DisplayName "paddock guest agent" `
        -Description "Answers paddock's host over vsock." -StartupType Automatic | Out-Null
}
# Start it again a second after every failure, including a stop with an error.
Invoke-Sc failure $name reset= 0 actions= restart/1000
Invoke-Sc failureflag $name 1
Start-Service -Name $name

# The agent stops with an error if it can't listen on vsock, as without virtio-win's viosock driver.
Start-Sleep -Seconds 2
if ((Get-Service -Name $name).Status -eq "Running") {
    "paddock-guestd is running"
} else {
    throw "paddock-guestd is not running; check that virtio-win's viosock driver is installed"
}
