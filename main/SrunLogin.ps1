# SrunLogin.ps1 : For Srun authentication (login) through PowerShell.

# Terminating errors for this chain (Login.ps1 / KeepAlive.ps1); Manage.ps1 sets its own.
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\SrunCrypto.ps1"
. "$PSScriptRoot\SrunConfig.ps1"

# Login requests use a different User-Agent than the keep-alive probe on purpose.
$script:SrunLoginHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }

# HTTP timeout for login requests (seconds).
$script:SrunLoginTimeoutSec = 10

# TCP connect timeout for reaching the gateway (ms). Single source for the keep-alive's
# ConnectTimeoutMs setting and for the source-IP lookup of the one-shot login path.
$script:SrunGatewayConnectTimeoutMs = 3000

# Gateway identity invariants: response field patterns and the challenge length bound. The
# field names and patterns are protocol red lines (README section 13) - only the placement may
# change, never the spelling or semantics.
$script:SrunGateway = @{
    ClientIpPattern   = '"client_ip":"(.*?)"'
    ChallengePattern  = '"challenge":"(.*?)"'
    MaxChallengeChars = 256
}

# Keeps callback names unique within the same millisecond.
$script:SrunCallbackSeq = 0

function New-SrunCallback {
    $script:SrunCallbackSeq++
    'jsonp' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $script:SrunCallbackSeq
}

# Escapes \ and " like the portal's JSON.stringify; a password containing either would
# otherwise produce invalid JSON and the gateway would reject the login.
function ConvertTo-SrunJsonString([string]$Value) {
    $escaped = $Value -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
    '"' + $escaped + '"'
}

# Shared GET helper (headers / timeout / parsing).
function Invoke-SrunGet([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec = $script:SrunLoginTimeoutSec) {
    (Invoke-WebRequest -UseBasicParsing -Headers $Headers -TimeoutSec $TimeoutSec -Uri $Uri).Content
}

# Call GET /cgi-bin/get_challenge and return the raw JSONP response body.
function Get-SrunChallenge([string]$Url, [string]$EncUser, [string]$Ip, [hashtable]$Headers) {
    $uri = '{0}/cgi-bin/get_challenge?callback={1}&username={2}&ip={3}' -f $Url, (New-SrunCallback), $EncUser, [Uri]::EscapeDataString($Ip)
    Invoke-SrunGet $uri $Headers
}

# Connect to the gateway and return the local source IP used; $null if unreachable.
# Host and port come from the URL (no hard-coded port). Shared by the login path and the
# keep-alive loop so the transport has a single implementation (README section 13).
function Get-SrunGatewaySourceIp([string]$Url, [int]$TimeoutMs = $script:SrunGatewayConnectTimeoutMs) {
    $u   = [Uri]$Url
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $null
    try {
        $iar = $tcp.BeginConnect($u.Host, $u.Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $tcp.EndConnect($iar)
        return $tcp.Client.LocalEndPoint.Address.ToString()
    } catch { return $null }
    finally {
        # Close() does not release the AsyncWaitHandle; without this every probe leaks a
        # kernel wait handle until the finalizer runs.
        if ($iar) { $iar.AsyncWaitHandle.Close() }
        $tcp.Close()
    }
}

# True for a dotted-quad IPv4 literal (four 0-255 octets). Shorthand such as '1' is rejected on
# purpose: IPAddress.TryParse would silently read it as 0.0.0.1.
function Test-SrunIpv4([string]$Value) {
    if ($Value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($part in $Value.Split('.')) { if ([int]$part -gt 255) { return $false } }
    return $true
}

# True for a plausible srun challenge: non-empty printable ASCII within the length bound.
# Deliberately permissive - the strongest evidence of identity is the client_ip echo match.
function Test-SrunChallengeToken([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value.Length -gt $script:SrunGateway.MaxChallengeChars) { return $false }
    return ($Value -match '^[\x21-\x7E]+$')
}

# Fetch the challenge token only after the peer has been verified to be the srun gateway.
# Evidence: get_challenge answers in srun's shape, client_ip is a valid IPv4 that equals the
# local source IP when one is supplied, and challenge is well formed. Returns a result object
# instead of throwing, so callers can tell an identity mismatch (stop, never log in) apart from
# a transport error (retry). No password material is built here.
function Get-SrunLoginToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string]$ExpectedSourceIp
    )
    $encUser = [Uri]::EscapeDataString($Config.Username)

    # First call only to learn client_ip; its challenge is bound to an empty ip and is not
    # usable, so the second call with the real ip below is required.
    $r1 = Get-SrunChallenge $Config.Url $encUser '' $script:SrunLoginHeaders
    $ip = [regex]::Match($r1, $script:SrunGateway.ClientIpPattern).Groups[1].Value
    if (-not (Test-SrunIpv4 $ip)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'client_ip missing or malformed'; Ip = ''; Challenge = '' }
    }
    if ($ExpectedSourceIp -and $ip -ne $ExpectedSourceIp) {
        return [pscustomobject]@{ Ok = $false; Reason = "client_ip $ip does not match local source $ExpectedSourceIp"; Ip = ''; Challenge = '' }
    }

    # Challenge bound to the real ip - this is the token.
    $r2  = Get-SrunChallenge $Config.Url $encUser $ip $script:SrunLoginHeaders
    $tok = [regex]::Match($r2, $script:SrunGateway.ChallengePattern).Groups[1].Value
    if (-not (Test-SrunChallengeToken $tok)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'challenge missing or malformed'; Ip = ''; Challenge = '' }
    }

    [pscustomobject]@{ Ok = $true; Reason = ''; Ip = $ip; Challenge = $tok }
}

# Submit a login with a token from Get-SrunLoginToken. This is the only place that builds
# password material, and it is only reached with a verified token.
function Send-SrunLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string]$ip,
        [Parameter(Mandatory)][string]$Challenge
    )

    # Protocol constants; the parameter and the checksum must use the same values.
    $SrunN           = '200'          # portal 'n'
    $SrunType        = '1'            # portal 'type'
    $SrunDoubleStack = '0'            # portal 'double_stack'
    $SrunOs          = 'Windows 10'   # cosmetic client description reported to the gateway
    $SrunName        = 'Windows'      # cosmetic client name reported to the gateway

    # Do not unify the spellings: "acid" in the info JSON vs "ac_id" in the query, and raw in
    # info/checksum vs URL-encoded in the query.
    $encUser = [Uri]::EscapeDataString($Config.Username)
    $tok     = $Challenge

    # Local encryption, equivalent to the login page's JavaScript.
    $info = '{"username":' + (ConvertTo-SrunJsonString $Config.Username) +
            ',"password":' + (ConvertTo-SrunJsonString $Config.Pass) +
            ',"ip":' + (ConvertTo-SrunJsonString $ip) +
            ',"acid":' + (ConvertTo-SrunJsonString $Config.AcId) +
            ',"enc_ver":' + (ConvertTo-SrunJsonString 'srun_bx1') + '}'
    $enc  = '{SRBX1}' + (Sr-Base64 (Sr-XEncode $info $tok))
    $md5  = Sr-Md5 $Config.Pass $tok
    $sum  = Sr-Sha1 ($tok + $Config.Username + $tok + $md5 + $tok + $Config.AcId + $tok + $ip + $tok + $SrunN + $tok + $SrunType + $tok + $enc)

    # Submit and login.
    $query = @(
        'callback=' + (New-SrunCallback)
        'action=login'
        'username=' + $encUser
        'password=' + [Uri]::EscapeDataString('{MD5}' + $md5)
        'ac_id=' + $Config.AcId
        'ip=' + [Uri]::EscapeDataString($ip)
        'chksum=' + $sum
        'info=' + [Uri]::EscapeDataString($enc)
        'n=' + $SrunN
        'type=' + $SrunType
        'os=' + [Uri]::EscapeDataString($SrunOs)
        'name=' + [Uri]::EscapeDataString($SrunName)
        'double_stack=' + $SrunDoubleStack
    ) -join '&'
    $body   = Invoke-SrunGet "$($Config.Url)/cgi-bin/srun_portal?$query" $script:SrunLoginHeaders
    $result = [regex]::Match($body, '"error":"(.*?)"').Groups[1].Value

    [pscustomobject]@{
        Ip      = $ip
        Result  = $result
        Success = ($result -eq 'ok')   # protocol literal
    }
}

# One-shot login: verify the peer, then submit. Used by Login.ps1 and by callers that do not
# already know the local source IP; the keep-alive loop calls Get-SrunLoginToken and
# Send-SrunLogin directly so it can gate on identity before building any password material.
function Invoke-SrunLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string]$ExpectedSourceIp
    )
    if (-not $ExpectedSourceIp) { $ExpectedSourceIp = Get-SrunGatewaySourceIp $Config.Url }
    $token = Get-SrunLoginToken -Config $Config -ExpectedSourceIp $ExpectedSourceIp
    if (-not $token.Ok) { throw "gateway identity check failed: $($token.Reason)" }
    Send-SrunLogin -Config $Config -ip $token.Ip -Challenge $token.Challenge
}
