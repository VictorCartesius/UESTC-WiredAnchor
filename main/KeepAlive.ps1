# Srun keep-alive entry point - manages WIRED campus access only, reconnects when the session drops.
# Foreground:  powershell -ExecutionPolicy Bypass -File .\KeepAlive.ps1
# Background:  let Task Scheduler run this script at logon (hidden window).

. "$PSScriptRoot\SrunKeepAlive.ps1"
Start-SrunKeepAlive
