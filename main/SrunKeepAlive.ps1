# SrunKeepAlive.ps1 - Keep-alive module: wired campus access only, reconnects when the session drops.
# Loads SrunLogin.ps1 (which loads SrunCrypto.ps1 + SrunConfig.ps1). Stock PowerShell 5.1 and
# .NET only - no modules.

. "$PSScriptRoot\SrunLogin.ps1"

# ---- SETTINGS ----
$script:SrunKeepAliveConfig = [ordered]@{
    OnlineInterval       = 30    # probe interval while online (seconds)
    FailThreshold        = 3     # consecutive internet failures before treating as offline
    DetachedDelay        = 60    # recheck interval when detached / not on a wired outlet (seconds)
    RetestDelay          = 3     # wait before re-probing while failures are below the threshold
    PostLoginDelay       = 2     # wait after a successful reconnect before re-probing
    BackoffStart         = 4     # initial backoff after a failed reconnect (seconds)
    BackoffFactor        = 2     # backoff multiplier applied per failed reconnect attempt
    MaxBackoff           = 60    # maximum backoff between failed reconnect attempts (seconds)
    MaxReconnectAttempts = 5     # consecutive failed reconnects before cooling down
    CooldownDelay        = 600   # cooldown recheck interval (seconds): never logs in during cooldown
    ConnectTimeoutMs     = $script:SrunGatewayConnectTimeoutMs  # gateway TCP connect timeout (ms); value defined in SrunLogin.ps1
    ProbeTimeoutMs       = 5000  # internet probe connect / read timeout (ms)
    MaxProbeChars        = 65536 # hard cap on probe response size (chars): a forged/portal answer cannot balloon memory
    LogRetentionDays     = 30    # delete log files older than this at daemon start (0 = keep forever)
}

# Probe target: URL and expected body belong together. An empty Expect means a status-only
# (HTTP 200) check - only safe where no captive portal rewrites the response.
$script:SrunProbe = @{
    Url    = 'http://www.msftconnecttest.com/connecttest.txt'
    Expect = 'Microsoft Connect Test'
}

# Probe User-Agent; different from the login UA on purpose.
$script:SrunProbeUA = 'SrunKeepAlive'

# Adapter descriptions excluded when detecting wired NICs (virtual / tunnel devices).
$script:SrunExcludedNicPattern = 'Virtual|VMware|Hyper-V|VirtualBox|TAP|Loopback|VPN|Bluetooth|WSL'

# Link-local (APIPA) address prefix treated as "no usable IPv4".
$script:SrunLinkLocalPrefix = '169.254.*'

# Log directory comes from SrunConfig.ps1 ($script:SrunLogDir); the date format is shared by
# the line prefix and the file name.
$script:SrunDateFmt = 'yyyy-MM-dd'
$script:SrunUtf8    = New-Object System.Text.UTF8Encoding($false)

# Never throws - both sinks are guarded.
function Write-SrunLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format "$script:SrunDateFmt HH:mm:ss"), $Message
    try { Write-Host $line } catch { }
    try {
        if (-not (Test-Path -LiteralPath $script:SrunLogDir)) {
            New-Item -ItemType Directory -Path $script:SrunLogDir -Force | Out-Null
        }
        $file = Join-Path $script:SrunLogDir ((Get-Date -Format $script:SrunDateFmt) + '.log')
        [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine, $script:SrunUtf8)
    } catch { }
}

# A state-change line, tagged so Manage.ps1 -Action Status can report the current state. Both
# the tag format and the parsing pattern come from a single definition in SrunConfig.ps1.
function Write-SrunStateLog([string]$State, [string]$Message) {
    Write-SrunLog "$Message $($script:SrunStateTag -f $State)"
}

# Prune logs older than $Days (0 = keep forever). Startup only, not on the logging hot path.
# Returns the number of files removed.
function Remove-SrunOldLogs([int]$Days) {
    if ($Days -le 0 -or -not (Test-Path -LiteralPath $script:SrunLogDir)) { return 0 }
    $cutoff  = (Get-Date).Date.AddDays(-$Days)
    $removed = 0
    Get-ChildItem -LiteralPath $script:SrunLogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    return $removed
}

# IPv4 addresses of all connected WIRED adapters (virtual / tunnel / bluetooth excluded).
function Get-SrunWiredIpv4 {
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object {
        if ($_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) { return }
        if ($_.OperationalStatus   -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { return }
        if ($_.Description -match $script:SrunExcludedNicPattern) { return }
        $_.GetIPProperties().UnicastAddresses | ForEach-Object {
            if ($_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $_.Address.IPAddressToString -notlike $script:SrunLinkLocalPrefix) {
                $_.Address.IPAddressToString
            }
        }
    }
}

# Probe from the given source IP: online only on HTTP 200 and, if Expect is set, a body match.
# A captive portal returns $false.
function Test-SrunInternetVia([string]$LocalIp, [string]$Url, [string]$Expect, [int]$TimeoutMs = $script:SrunKeepAliveConfig.ProbeTimeoutMs) {
    $u   = [Uri]$Url
    $tcp = New-Object System.Net.Sockets.TcpClient(New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($LocalIp), 0))
    $iar = $null
    try {
        $tcp.ReceiveTimeout = $TimeoutMs
        $iar = $tcp.BeginConnect($u.Host, $u.Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $tcp.EndConnect($iar)
        $stream = $tcp.GetStream()
        $path = if ($u.PathAndQuery) { $u.PathAndQuery } else { '/' }
        $req  = "GET $path HTTP/1.1`r`nHost: $($u.Host)`r`nUser-Agent: $script:SrunProbeUA`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        # Bounded read - plain HTTP, so a rogue or portal answer must not balloon memory.
        $limit  = [int]$script:SrunKeepAliveConfig.MaxProbeChars
        $reader = New-Object System.IO.StreamReader($stream)
        $buf    = New-Object 'char[]' 4096
        $sb     = New-Object System.Text.StringBuilder
        while ($sb.Length -lt $limit) {
            $n = $reader.Read($buf, 0, [Math]::Min($buf.Length, $limit - $sb.Length))
            if ($n -le 0) { break }
            [void]$sb.Append($buf, 0, $n)
        }
        $text = $sb.ToString()
        if ($text -notmatch '^HTTP/\S+\s+200') { return $false }
        if ([string]::IsNullOrEmpty($Expect)) { return $true }
        return $text.Contains($Expect)
    } catch { return $false }
    finally {
        if ($iar) { $iar.AsyncWaitHandle.Close() }
        $tcp.Close()
    }
}

function Start-SrunKeepAlive {
    # Launched windowless with nobody waiting: an early failure must still leave a log line and
    # a non-zero exit code, or it dies without evidence.
    try {
        $cfg = Get-SrunConfig
    } catch {
        # Must not depend on anything that could itself have failed to load.
        try { Write-SrunLog "fatal: cannot start: $($_.Exception.Message)" } catch { }
        exit 1
    }
    $S = $script:SrunKeepAliveConfig

    # Event line, then tunables. loginTimeout lives in SrunLogin.ps1, so it is added explicitly.
    Write-SrunLog "keep-alive started: gateway $($cfg.Url), probe $($script:SrunProbe.Url)"
    $configText = ($S.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    Write-SrunLog "settings: loginTimeout=$($script:SrunLoginTimeoutSec)s, $configText"

    $gone = Remove-SrunOldLogs $S.LogRetentionDays
    if ($gone) { Write-SrunLog "removed $gone log file(s) older than $($S.LogRetentionDays) days" }

    $state = ''
    $fail = 0
    $reconnectFailures = 0
    $backoff = 0

    while ($true) {
        # Long-running daemon: one unexpected error must not terminate it.
        try {
            # 1) Is the gateway reachable, and which source IP does the OS use?
            $src = Get-SrunGatewaySourceIp $cfg.Url $S.ConnectTimeoutMs
            if (-not $src) {
                if ($state -ne 'Detached') { Write-SrunStateLog 'Detached' 'gateway unreachable - waiting (off campus or no link)'; $state = 'Detached' }
                Start-Sleep -Seconds $S.DetachedDelay
                continue
            }

            # 2) Only manage WIRED access; if the outlet is wireless, stay out of the way.
            if (@(Get-SrunWiredIpv4) -notcontains $src) {
                if ($state -ne 'Idle') { Write-SrunStateLog 'Idle' "outlet $src is not wired (likely Wi-Fi) - leaving it alone"; $state = 'Idle' }
                Start-Sleep -Seconds $S.DetachedDelay
                continue
            }

            # 3) Is the internet reachable from the wired outlet?
            if (Test-SrunInternetVia -LocalIp $src -Url $script:SrunProbe.Url -Expect $script:SrunProbe.Expect) {
                if ($state -ne 'Online') { Write-SrunStateLog 'Online' "online via $src"; $state = 'Online' }
                $fail = 0; $reconnectFailures = 0; $backoff = 0
                Start-Sleep -Seconds $S.OnlineInterval
                continue
            }

            # 4) Internet down - reconnect only after FailThreshold consecutive failures.
            $fail++
            if ($fail -lt $S.FailThreshold) {
                Start-Sleep -Seconds $S.RetestDelay
                continue
            }

            # 5) Identity gate. Confirm the peer is the srun gateway before any password material
            #    is built. A transport error is retried; an identity mismatch is never logged in to.
            $token = $null
            try {
                $token = Get-SrunLoginToken -Config $cfg -ExpectedSourceIp $src
            } catch {
                Write-SrunLog "gateway probe failed: $($_.Exception.Message)"
                if ($backoff -eq 0) { $backoff = $S.BackoffStart } else { $backoff = [Math]::Min($S.MaxBackoff, $backoff * $S.BackoffFactor) }
                Start-Sleep -Seconds $backoff
                continue
            }
            if (-not $token.Ok) {
                if ($state -ne 'Foreign') { Write-SrunStateLog 'Foreign' "foreign gateway: identity check failed ($($token.Reason)) - not logging in"; $state = 'Foreign' }
                Start-Sleep -Seconds $S.CooldownDelay
                continue
            }

            # 6) Identity confirmed. Waking from cooldown starts a fresh attempt budget; the only
            #    way out of cooldown is a successful identity check on the wired outlet above.
            if ($state -eq 'Cooling') {
                Write-SrunStateLog 'Offline' 'gateway identity confirmed again on wired outlet - resuming attempts'
                $state = 'Offline'
                $reconnectFailures = 0
            }
            if ($state -ne 'Offline') { Write-SrunStateLog 'Offline' "offline: $fail consecutive failures on $src - reconnecting"; $state = 'Offline' }

            try {
                $res = Send-SrunLogin -Config $cfg -ip $token.Ip -Challenge $token.Challenge
                Write-SrunLog "reconnect: $($res.Result) (ip $($res.Ip))"
                if ($res.Success) { $fail = 0; $reconnectFailures = 0; $backoff = 0; Start-Sleep -Seconds $S.PostLoginDelay; continue }
                $reconnectFailures++
            } catch {
                Write-SrunLog "reconnect failed: $($_.Exception.Message)"
                $reconnectFailures++
            }

            # 7) Attempt budget exhausted -> cooldown (no more logins until identity is re-verified
            #    after the delay); otherwise exponential backoff.
            if ($reconnectFailures -ge $S.MaxReconnectAttempts) {
                Write-SrunStateLog 'Cooling' "reconnect failed x$reconnectFailures - cooling for $($S.CooldownDelay)s"
                $state = 'Cooling'
                Start-Sleep -Seconds $S.CooldownDelay
                continue
            }
            if ($backoff -eq 0) { $backoff = $S.BackoffStart } else { $backoff = [Math]::Min($S.MaxBackoff, $backoff * $S.BackoffFactor) }
            Start-Sleep -Seconds $backoff
        } catch {
            Write-SrunLog "loop error (still running): $($_.Exception.Message)"
            $state = ''   # reset so the next state change is logged (not suppressed as "unchanged")
            Start-Sleep -Seconds $S.RetestDelay
        }
    }
}
