# Manage.ps1 - manager UI: wraps Login.ps1 / KeepAlive.ps1, manages autostart.
# Menu: powershell -ExecutionPolicy Bypass -File .\Manage.ps1
# CLI:  powershell -ExecutionPolicy Bypass -File .\Manage.ps1 -Action <Action> [-Method Auto|Task|Run] [-Locate <area>] [-LogLines N]

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'ShowConfig', 'TestLogin', 'SetCredential', 'ClearCredential',
                 'SetLocate', 'Install', 'Uninstall', 'Enable', 'Disable', 'Start', 'Stop', 'Logs')]
    [string]$Action = 'Menu',

    [ValidateSet('Auto', 'Task', 'Run')]
    [string]$Method = 'Auto',

    [string]$Locate,

    [ValidateRange(1, 1000)]
    [int]$LogLines = 20
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\SrunConfig.ps1"

# ---- CONSTANTS ----
$script:AutostartName = 'UESTC-WiredAnchor'
$script:TaskName      = $script:AutostartName
$script:RunValueName  = $script:AutostartName
$script:RunKey        = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:LoginScript   = Join-Path $PSScriptRoot 'Login.ps1'
$script:KaScript      = Join-Path $PSScriptRoot 'KeepAlive.ps1'
$script:HiddenHost    = Join-Path $PSScriptRoot 'Start-Hidden.vbs'
# Full paths: a bare name would let a powershell.exe in the working directory hijack logon.
$script:WscriptExe    = Join-Path $env:SystemRoot 'System32\wscript.exe'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Failure -> exit code 1 (set by Write-SrunError).
$script:SrunFailed = $false

# ---- ACTION TABLE ----
# Generates the menu and the dispatch. Label is the exact -Action value; the -Action ValidateSet
# mirrors these keys plus 'Menu' (the drift guard below fails if they disagree).
$script:SrunActions = [ordered]@{
    Status          = @{ Label = 'Status';          Desc = 'credentials, area, gateway, autostart, daemon'; Run = { Show-Status } }
    ShowConfig      = @{ Label = 'ShowConfig';      Desc = 'print the effective configuration';             Run = { Show-Config } }
    SetCredential   = @{ Label = 'SetCredential';   Desc = 'store student ID and password';                 Run = { Set-SrunCredential } }
    ClearCredential = @{ Label = 'ClearCredential'; Desc = 'remove the stored credentials';                 Run = { Clear-SrunCredential } }
    SetLocate       = @{ Label = 'SetLocate';       Desc = "set area ($(@($script:SrunPresets.Keys) -join '/'))"; Run = { Set-SrunLocate } }
    TestLogin       = @{ Label = 'TestLogin';       Desc = 'log in once and report the result';             Run = { Invoke-LoginOnce } }
    Install         = @{ Label = 'Install';         Desc = 'install autostart at logon';                    Run = { Install-SrunAutostart } }
    Uninstall       = @{ Label = 'Uninstall';       Desc = 'remove autostart';                              Run = { Uninstall-SrunAutostart } }
    Enable          = @{ Label = 'Enable';          Desc = 'enable autostart';                              Run = { Enable-SrunAutostart } }
    Disable         = @{ Label = 'Disable';         Desc = 'disable autostart';                             Run = { Disable-SrunAutostart } }
    Start           = @{ Label = 'Start';           Desc = 'start the keep-alive daemon';                   Run = { Start-SrunKeepAliveProcess } }
    Stop            = @{ Label = 'Stop';            Desc = 'stop the keep-alive daemon';                    Run = { Stop-SrunKeepAliveProcess } }
    Logs            = @{ Label = 'Logs';            Desc = 'show the tail of the newest log';               Run = { Show-SrunLogs } }
}

# Drift guard: the -Action ValidateSet must match the action table exactly.
$script:SrunDeclaredActions = @((Get-Variable -Name Action).Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues })
$script:SrunTableActions = @('Menu') + @($script:SrunActions.Keys)
if (@(Compare-Object $script:SrunDeclaredActions $script:SrunTableActions).Count) {
    throw "Manage.ps1 is out of sync: -Action ValidateSet ($($script:SrunDeclaredActions -join ', ')) does not match the action table ($($script:SrunTableActions -join ', '))."
}

# ---- HELPERS ----

# Lowercase and terse; errors and warnings go to stderr so they can be redirected/grepped.
function Write-SrunErrLine([string]$Text) {
    try {
        $prev = [Console]::ForegroundColor
        [Console]::ForegroundColor = 'Red'
        [Console]::Error.WriteLine($Text)
        [Console]::ForegroundColor = $prev
    } catch { Write-Host $Text -ForegroundColor Red }
}

function Write-SrunError([string]$Message) {
    $script:SrunFailed = $true
    Write-SrunErrLine "error: $Message"
}

function Write-SrunWarn([string]$Message) {
    try {
        $prev = [Console]::ForegroundColor
        [Console]::ForegroundColor = 'Yellow'
        [Console]::Error.WriteLine("warning: $Message")
        [Console]::ForegroundColor = $prev
    } catch { Write-Host "warning: $Message" -ForegroundColor Yellow }
}

function Write-SrunOk([string]$Message) { Write-Host $Message -ForegroundColor Green }

function Write-SrunNote([string]$Message) { Write-Host "note: $Message" -ForegroundColor DarkGray }

function Get-UserEnv([string]$Name) {
    [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Get-ProcessEnv([string]$Name) {
    [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function Set-UserEnv([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')   # persistent (HKCU\Environment)
    try   { Set-Item -Path "env:$Name" -Value $Value }              # best effort: this session too
    catch { Write-SrunWarn "saved, but this session could not be updated: $($_.Exception.Message)" }
}

function Clear-UserEnv([string]$Name) {
    [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    Remove-Item -Path "env:$Name" -ErrorAction SilentlyContinue
}

# User store first, then this session - the login path reads Process scope only.
function Get-SrunEffectiveEnv([string]$Name) {
    $v = Get-UserEnv $Name
    if (-not $v) { $v = Get-ProcessEnv $Name }
    return $v
}

# Copy User-store values missing from this session before launching: the child inherits this
# environment, and a shell opened before the credentials were saved would otherwise hand it none.
function Sync-SrunEnvForLaunch {
    foreach ($name in @($script:SrunEnvNumber, $script:SrunEnvPasswd, $script:SrunEnvLocate)) {
        if (Get-ProcessEnv $name) { continue }
        $persisted = Get-UserEnv $name
        if (-not $persisted) { continue }
        try { Set-Item -Path "env:$name" -Value $persisted } catch { }
    }
}

# Pre-flight for Install/Start: fail up front rather than let a windowless daemon die silently.
# -RequirePersisted: for launch paths that see only the User environment (Install, Start via task).
function Test-SrunStartReadiness([switch]$RequirePersisted) {
    $problems = @()
    $num = Get-SrunEffectiveEnv $script:SrunEnvNumber
    $path = Get-SrunEffectiveEnv $script:SrunEnvPasswd
    $numPersisted = [bool](Get-UserEnv $script:SrunEnvNumber)
    $pathPersisted = [bool](Get-UserEnv $script:SrunEnvPasswd)

    if (-not $num -or -not $path) {
        $problems += 'credentials are not set (use SetCredential)'
    } elseif ($RequirePersisted -and -not ($numPersisted -and $pathPersisted)) {
        $problems += 'credentials exist only in this session - a logon launch would not see them (use SetCredential)'
    }

    $loc = Get-SrunEffectiveEnv $script:SrunEnvLocate
    if ($loc) {
        try { $null = Get-SrunPreset $loc } catch { $problems += $_.Exception.Message }
        if ($RequirePersisted -and -not (Get-UserEnv $script:SrunEnvLocate)) {
            $problems += "area override '$loc' exists only in this session - a logon launch would fall back to the default"
        }
    }
    # Plain return - callers wrap with @(); ",$problems" would turn an empty result into a
    # phantom one-element "problem" that blocks start.
    return $problems
}

# The daemon reads its config once at startup, so a running instance keeps the old values.
function Write-SrunRestartHint {
    $proc = @(Get-KeepAliveProcess)
    if (-not $proc.Count) { return }
    $pids = ($proc | ForEach-Object { $_.ProcessId }) -join ', '
    Write-SrunNote "the running keep-alive (pid $pids) uses the settings from when it started - run Stop, then Start to apply changes"
}

# Effective configuration, resolved fresh on every call (nothing cached here).
function Get-SrunEffectiveConfig {
    $eff  = Get-SrunEffectiveLocate
    $url  = '(unknown area)'
    $acId = '(unknown area)'
    if ($script:SrunPresets.Contains($eff.Locate)) {     # only an unknown area degrades
        $preset = Get-SrunPreset $eff.Locate
        $url    = $preset.Url
        $acId   = $preset.AcId
    }
    [pscustomobject]@{
        Locate       = $eff.Locate
        LocateSource = $eff.Source
        Url          = $url
        AcId         = $acId
        Domain       = $script:SrunDomain
    }
}

# ---- LAUNCHER ----
# Get-KeepAliveLauncher decides (exec, args): a task takes arguments, a Run entry one command line.
# Start-Hidden.vbs is preferred (console hidden from creation); '-WindowStyle Hidden' alone only
# hides an existing console, which could still be closed. Falls back when Script Host is disabled.
function Test-SrunScriptHostEnabled {
    foreach ($path in @('HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings',
                        'HKCU:\SOFTWARE\Microsoft\Windows Script Host\Settings')) {
        $v = (Get-ItemProperty -Path $path -Name Enabled -ErrorAction SilentlyContinue).Enabled
        if ($null -ne $v -and $v -eq 0) { return $false }
    }
    return $true
}

function Get-KeepAliveLauncher {
    if ((Test-Path -LiteralPath $script:HiddenHost) -and
        (Test-Path -LiteralPath $script:WscriptExe) -and
        (Test-SrunScriptHostEnabled)) {
        return [pscustomobject]@{ Exec = $script:WscriptExe; Args = "//nologo //B `"$($script:HiddenHost)`""; Hidden = $true }
    }
    return [pscustomobject]@{
        Exec   = $script:PowerShellExe
        Args   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:KaScript)`""
        Hidden = $false
    }
}

function Get-KeepAliveCommandLine {
    $l = Get-KeepAliveLauncher
    "$($l.Exec) $($l.Args)"
}

# ---- AUTOSTART: TASK ----

function Get-AutostartTask {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
}

# ---- AUTOSTART: RUN ----

function Get-RunAutostart {
    if (-not (Test-Path -LiteralPath $script:RunKey)) { return $null }
    $item = Get-ItemProperty -LiteralPath $script:RunKey -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $prop = $item.PSObject.Properties[$script:RunValueName]
    if ($prop) { return [string]$prop.Value }
    return $null
}

function Add-RunAutostart {
    if (-not (Test-Path -LiteralPath $script:RunKey)) { New-Item -Path $script:RunKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $script:RunKey -Name $script:RunValueName -Value (Get-KeepAliveCommandLine)
}

function Remove-RunAutostart {
    if (Get-RunAutostart) { Remove-ItemProperty -LiteralPath $script:RunKey -Name $script:RunValueName -ErrorAction SilentlyContinue }
}

function Get-AutostartSummary {
    $task = Get-AutostartTask
    if ($task) { return "scheduled task ($($task.State))" }
    if (Get-RunAutostart) { return 'Run entry (logon, no admin)' }
    return 'not installed'
}

# ---- DAEMON PROCESS ----

# Match the launch shape, not a bare "KeepAlive.ps1" substring - Stop kills (-Force) what it finds.
function Get-KeepAliveProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-File\s+"?[^"]*KeepAlive\.ps1' }
}

# Daemon state from the newest log's last state tag (written by SrunKeepAlive.ps1). This reports
# the last state CHANGE, not live process memory, so the caller labels it when the daemon is down.
function Get-SrunLogDaemonState {
    if (-not (Test-Path -LiteralPath $script:SrunLogDir)) { return $null }
    $file = Get-ChildItem -LiteralPath $script:SrunLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    $lines = @(Get-Content -LiteralPath $file.FullName -Tail 200 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($lines[$i], $script:SrunStateTagPattern)   # pattern shared via SrunConfig.ps1
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# ---- ACTIONS ----

function Show-Status {
    $cfg  = Get-SrunEffectiveConfig
    $proc = @(Get-KeepAliveProcess)

    # Look credentials up where the login path does, or the panel can contradict a real login.
    $hasCreds  = [bool]((Get-SrunEffectiveEnv $script:SrunEnvNumber) -and (Get-SrunEffectiveEnv $script:SrunEnvPasswd))
    $persisted = [bool]((Get-UserEnv $script:SrunEnvNumber) -and (Get-UserEnv $script:SrunEnvPasswd))

    $credText = 'not set (use SetCredential)'
    if ($hasCreds) {
        $credText = 'set'
        if (-not $persisted) { $credText += ' (this session only, not saved)' }
    }
    $procText = 'not running'
    if ($proc.Count) { $procText = 'pid ' + (($proc | ForEach-Object { $_.ProcessId }) -join ', ') }

    $stateText = Get-SrunLogDaemonState
    if (-not $stateText) { $stateText = 'unknown' }
    elseif (-not $proc.Count) { $stateText += ' (last logged)' }

    Write-Host ("{0,-12} {1}" -f 'credentials', $credText)
    Write-Host ("{0,-12} {1}" -f 'area', "$($cfg.Locate) ($($cfg.LocateSource))")
    Write-Host ("{0,-12} {1}" -f 'gateway', "$($cfg.Url)  ac_id=$($cfg.AcId)  $($cfg.Domain)")
    Write-Host ("{0,-12} {1}" -f 'autostart', (Get-AutostartSummary))
    Write-Host ("{0,-12} {1}" -f 'daemon', $procText)
    Write-Host ("{0,-12} {1}" -f 'state', $stateText)
    Write-Host ("{0,-12} {1}" -f 'logs', $script:SrunLogDir)
    if ($proc.Count) { Write-SrunRestartHint }
}

function Show-Config {
    $cfg = Get-SrunEffectiveConfig
    # Only env-var names here; the "what to change where" list lives in README section 8.
    Write-Host ("{0,-14} {1}" -f 'area', "$($cfg.Locate) ($($cfg.LocateSource))")
    Write-Host ("{0,-14} {1}" -f 'gateway', "$($cfg.Url)  ac_id=$($cfg.AcId)")
    Write-Host ("{0,-14} {1}" -f 'domain', $cfg.Domain)
    Write-Host ("{0,-14} {1}" -f 'credentials', "$($script:SrunEnvNumber) / $($script:SrunEnvPasswd) (user environment)")
    Write-Host ("{0,-14} {1}" -f 'area override', "$($script:SrunEnvLocate) (user environment; $(@($script:SrunPresets.Keys) -join ' | '))")
}

function Invoke-LoginOnce {
    # Propagate Login.ps1's exit code, so TestLogin fails the same from menu or CLI.
    & $script:LoginScript
    if ($LASTEXITCODE -ne 0) { $script:SrunFailed = $true }
}

function Set-SrunCredential {
    Write-SrunNote 'stored as user environment variables - plain text in HKCU\Environment,'
    Write-Host '      readable by any process running as you (ClearCredential removes them).' -ForegroundColor DarkGray
    Write-Host -NoNewline 'student ID: '
    $id = Read-Host
    if ([string]::IsNullOrWhiteSpace($id)) { Write-Host 'cancelled (empty student ID)'; return }

    Write-Host -NoNewline 'password: '
    $sec = Read-Host -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ([string]::IsNullOrEmpty($plain)) { Write-Host 'cancelled (empty password)'; return }

    Set-UserEnv $script:SrunEnvNumber $id
    Set-UserEnv $script:SrunEnvPasswd $plain
    Write-SrunOk 'saved'
    Write-SrunRestartHint
}

function Clear-SrunCredential {
    # Check both stores, like the clear itself does, or a session-only value is removed silently.
    $had = [bool]((Get-UserEnv $script:SrunEnvNumber) -or (Get-UserEnv $script:SrunEnvPasswd) -or
                  (Get-ProcessEnv $script:SrunEnvNumber) -or (Get-ProcessEnv $script:SrunEnvPasswd))
    Clear-UserEnv $script:SrunEnvNumber
    Clear-UserEnv $script:SrunEnvPasswd
    if ($had) { Write-SrunOk 'cleared (user environment + this session)' }
    else      { Write-Host 'nothing to clear' }
    Write-SrunRestartHint
}

function Set-SrunLocate {
    $value = $Locate
    if (-not $value) {
        Write-Host -NoNewline "area [$(@($script:SrunPresets.Keys) -join '/')]: "
        $value = Read-Host
    }
    try { $null = Get-SrunPreset $value }                 # same validator as the login path
    catch { Write-SrunError $_.Exception.Message; return }
    # Store the canonical spelling from the preset table, whatever the user typed.
    $key = @($script:SrunPresets.Keys) | Where-Object { $_ -eq $value } | Select-Object -First 1
    if (-not $key) { $key = $value }        # never hand Set-UserEnv a $null - that would DELETE the variable
    Set-UserEnv $script:SrunEnvLocate $key
    Write-SrunOk "area set to '$key'"
    Write-SrunRestartHint
}

function Install-SrunAutostart {
    if (-not (Test-Path -LiteralPath $script:KaScript)) { throw "keep-alive script not found: $($script:KaScript)" }
    if ((Get-AutostartTask) -or (Get-RunAutostart)) { Write-Host 'autostart already installed'; return }

    # Refuse an entry that would die at logon with no visible symptom.
    $problems = @(Test-SrunStartReadiness -RequirePersisted)
    if ($problems.Count) {
        Write-SrunError 'cannot install autostart - the daemon would not start at logon'
        $problems | ForEach-Object { Write-SrunErrLine "  $_" }
        return
    }

    if (-not (Get-KeepAliveLauncher).Hidden) {
        Write-SrunWarn 'Windows Script Host is unavailable - a console window may flash at logon'
    }

    if ($Method -ne 'Run') {
        try {
            $launcher   = Get-KeepAliveLauncher
            $taskAction = New-ScheduledTaskAction -Execute $launcher.Exec -Argument $launcher.Args
            $trigger    = New-ScheduledTaskTrigger -AtLogOn
            $settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                            -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $script:TaskName -Action $taskAction -Trigger $trigger -Settings $settings `
                            -Description 'UESTC-WiredAnchor - campus auto-login keep-alive (managed by Manage.ps1)' | Out-Null
            Write-SrunOk 'installed (scheduled task, runs at logon)'
            return
        } catch {
            if ($Method -eq 'Task') {
                Write-SrunError "could not create the scheduled task: $($_.Exception.Message)"
                Write-SrunErrLine '  try running elevated, or use -Method Run'
                return
            }
            Write-SrunWarn 'scheduled task unavailable (needs admin) - using the per-user Run entry'
        }
    }

    Add-RunAutostart
    Write-SrunOk 'installed (Run entry, runs at logon)'
}

function Uninstall-SrunAutostart {
    $did = $false
    if (Get-RunAutostart) { Remove-RunAutostart; Write-SrunOk 'removed Run entry'; $did = $true }
    if (Get-AutostartTask) {
        try {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
            Write-SrunOk 'removed scheduled task'
            $did = $true
        } catch {
            Write-SrunError "could not remove scheduled task: $($_.Exception.Message)"
        }
    }
    if (-not $did) { Write-Host 'autostart not installed' }
}

function Enable-SrunAutostart {
    if (Get-AutostartTask) {
        Enable-ScheduledTask -TaskName $script:TaskName | Out-Null
        Write-SrunOk 'enabled (scheduled task)'
        return
    }
    if (Get-RunAutostart) { Write-Host 'already enabled (Run entry)'; return }
    Install-SrunAutostart
}

function Disable-SrunAutostart {
    if (Get-AutostartTask) {
        Disable-ScheduledTask -TaskName $script:TaskName | Out-Null
        Write-SrunOk 'disabled (task kept, will not run at logon)'
        return
    }
    if (Get-RunAutostart) {
        Remove-RunAutostart
        Write-SrunOk 'disabled (Run entry removed - run Enable to re-add)'
        return
    }
    Write-Host 'autostart not installed'
}

# Launcher only: starts the daemon and returns immediately. Named differently from
# SrunKeepAlive.ps1's blocking Start-SrunKeepAlive so dot-sourcing cannot shadow the loop.
function Start-SrunKeepAliveProcess {
    # Idempotent: a windowless daemon gives no visible cue, and a duplicate authenticates twice.
    $running = @(Get-KeepAliveProcess)
    if ($running.Count) {
        $pids = ($running | ForEach-Object { $_.ProcessId }) -join ', '
        Write-Host "keep-alive already running (pid $pids)"
        return
    }

    # A scheduled task starts with a fresh environment, so session-only values would be lost
    # there; the direct launcher inherits this process's environment, so they are fine.
    $task             = Get-AutostartTask
    $requirePersisted = [bool]$task
    $problems         = @(Test-SrunStartReadiness -RequirePersisted:$requirePersisted)
    if ($problems.Count) {
        Write-SrunError 'cannot start keep-alive'
        $problems | ForEach-Object { Write-SrunErrLine "  $_" }
        return
    }

    if ($task) {
        Start-ScheduledTask -TaskName $script:TaskName
        Write-SrunOk 'started (scheduled task)'
        return
    }
    # The child inherits this environment; make sure the pre-flight's values are really in it.
    Sync-SrunEnvForLaunch
    $launcher = Get-KeepAliveLauncher
    Start-Process -FilePath $launcher.Exec -ArgumentList $launcher.Args
    Write-SrunOk 'keep-alive started'
}

function Stop-SrunKeepAliveProcess {
    if (Get-AutostartTask) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
    $proc = @(Get-KeepAliveProcess)
    foreach ($p in $proc) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($proc.Count) { Write-SrunOk "stopped $($proc.Count) process(es)" }
    else { Write-Host 'keep-alive not running' }
}

function Show-SrunLogs {
    if (-not (Test-Path -LiteralPath $script:SrunLogDir)) { Write-Host 'no logs yet'; return }
    $file = Get-ChildItem -LiteralPath $script:SrunLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $file) { Write-Host 'no logs yet'; return }
    Write-Host "$($file.Name) (last $LogLines lines)" -ForegroundColor DarkGray
    Get-Content -LiteralPath $file.FullName -Tail $LogLines
}

function Show-Menu {
    # A view over $script:SrunActions - entries, order and labels all come from the table.
    $keys = @($script:SrunActions.Keys)
    while ($true) {
        Write-Host ''
        Write-Host 'UESTC-WiredAnchor' -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $action = $script:SrunActions[$keys[$i]]
            Write-Host ('  {0,2}) {1,-16} {2}' -f ($i + 1), $action.Label, $action.Desc)
        }
        Write-Host '   0) exit'
        Write-Host -NoNewline 'manage> ' -ForegroundColor Green
        $choice = Read-Host
        if ($choice -eq '0') { return }
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $keys.Count) {
            $entry = $script:SrunActions[$keys[$index - 1]]
            & $entry.Run
        } else {
            Write-Host 'unknown choice'
        }
    }
}

# ---- DISPATCH ----
# 'Menu' wraps the table; every other action is an entry in it.
if ($Locate -and $Action -ne 'SetLocate') {
    Write-SrunWarn "-Locate is only used by SetLocate (ignored for '$Action')"
}
if ($Action -eq 'Menu') {
    Show-Menu
} else {
    $entry = $script:SrunActions[$Action]
    & $entry.Run
    if ($script:SrunFailed) { exit 1 }
}
