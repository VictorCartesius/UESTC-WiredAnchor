# Srun Authentication through PowerShell.
# Prints the source IP, then one result line ('connected', or 'login failed: <reason>').
# Exits 0 on success and 1 on failure.

. "$PSScriptRoot\SrunLogin.ps1"

try {
    $res = Invoke-SrunLogin -Config (Get-SrunConfig)
    Write-Host "ip $($res.Ip)"
    if ($res.Success) { Write-Host 'connected' -ForegroundColor Green; exit 0 }
    Write-Host "login failed: $($res.Result)" -ForegroundColor Yellow
    exit 1
} catch {
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    exit 1
}
