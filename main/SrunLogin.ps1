# SrunLogin.ps1 : For Srun authentication (login) through PowerShell.

# Terminating errors for this chain (Login.ps1 / KeepAlive.ps1); Manage.ps1 sets its own.
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\SrunCrypto.ps1"
. "$PSScriptRoot\SrunConfig.ps1"

# Login requests use a different User-Agent than the keep-alive probe on purpose.
$script:SrunLoginHeaders = @{ 'User-Agent' = 'Mozilla/5.0' }

# HTTP timeout for login requests (seconds).
$script:SrunLoginTimeoutSec = 10

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

function Invoke-SrunLogin {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    # Protocol constants; the parameter and the checksum must use the same values.
    $SrunN           = '200'          # portal 'n'
    $SrunType        = '1'            # portal 'type'
    $SrunDoubleStack = '0'            # portal 'double_stack'
    $SrunOs          = 'Windows 10'   # cosmetic client description reported to the gateway
    $SrunName        = 'Windows'      # cosmetic client name reported to the gateway

    # Do not unify the spellings: "acid" in the info JSON vs "ac_id" in the query, and raw in
    # info/checksum vs URL-encoded in the query.
    $encUser = [Uri]::EscapeDataString($Config.Username)

    # 1) First call only to learn client_ip; its challenge is bound to an empty ip and is not
    #    usable, so the second call with the real ip below is required.
    $ip = [regex]::Match((Get-SrunChallenge $Config.Url $encUser '' $script:SrunLoginHeaders), '"client_ip":"(.*?)"').Groups[1].Value
    if (-not $ip) { throw 'get_challenge returned no client_ip (gateway page/response format changed?)' }

    # 2) Challenge bound to the real ip - this is the token.
    $tok = [regex]::Match((Get-SrunChallenge $Config.Url $encUser $ip $script:SrunLoginHeaders), '"challenge":"(.*?)"').Groups[1].Value
    if (-not $tok) { throw 'get_challenge returned no challenge token (gateway response format changed?)' }

    # 3) Local encryption, equivalent to the login page's JavaScript.
    $info = '{"username":' + (ConvertTo-SrunJsonString $Config.Username) +
            ',"password":' + (ConvertTo-SrunJsonString $Config.Pass) +
            ',"ip":' + (ConvertTo-SrunJsonString $ip) +
            ',"acid":' + (ConvertTo-SrunJsonString $Config.AcId) +
            ',"enc_ver":' + (ConvertTo-SrunJsonString 'srun_bx1') + '}'
    $enc  = '{SRBX1}' + (Sr-Base64 (Sr-XEncode $info $tok))
    $md5  = Sr-Md5 $Config.Pass $tok
    $sum  = Sr-Sha1 ($tok + $Config.Username + $tok + $md5 + $tok + $Config.AcId + $tok + $ip + $tok + $SrunN + $tok + $SrunType + $tok + $enc)

    # 4) Submit and login.
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
