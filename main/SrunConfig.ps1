# SrunConfig.ps1 : project configuration - environment variable names, log directory,
# area presets, default area, carrier domain. Credentials come from environment variables.

# Environment variable names
$script:SrunEnvNumber = 'UESTC_NUMBER'   # student ID          (required)
$script:SrunEnvPasswd = 'UESTC_PASSWD'   # password            (required)
$script:SrunEnvLocate = 'UESTC_LOCATE'   # area override       (optional, see below)

$script:SrunLogDir = Join-Path $PSScriptRoot 'logs'

# Daemon state tag: SrunKeepAlive.ps1 writes it on every state-change log line, and Manage.ps1
# -Action Status parses the newest one back. One definition, two consumers - the pattern below
# is derived from the tag so the two can never drift. It is anchored to end of line because the
# tag is always the last thing on a state line: that stops peer-controlled text elsewhere on a
# line (login result, HTTP error text) from impersonating a state tag.
$script:SrunStateTag        = '[state={0}]'
$script:SrunStateTagPattern = [regex]::Escape($script:SrunStateTag).Replace([regex]::Escape('{0}'), '([A-Za-z]+)') + '$'

# Area presets. Url and ac_id belong together; adding a key here is enough - every consumer
# iterates this table. Ordered so generated lists (menu, hints) stay stable across runs.
#   Teaching = whole teaching area
#   Dorm     = dormitory area
$script:SrunPresets = [ordered]@{
    Teaching = @{ Url = 'http://10.253.0.237'; AcId = '1' }
    Dorm     = @{ Url = 'http://10.253.0.235'; AcId = '3' }
}

$script:SrunDefaultLocate = 'Teaching'

# Carrier suffix appended to the student ID.
$script:SrunDomain = '@dx-uestc'   # UESTC Campus @dx-uestc | China Telecom @dx | China Mobile @cmcc

# Effective area: UESTC_LOCATE override wins, otherwise the default. Resolved on every call, so a
# mid-session change is picked up. Source tag: 'default' / 'env UESTC_LOCATE'.
function Get-SrunEffectiveLocate {
    $fromEnv = [Environment]::GetEnvironmentVariable($script:SrunEnvLocate, 'Process')
    if ($fromEnv) { return [pscustomobject]@{ Locate = $fromEnv; Source = "env $script:SrunEnvLocate" } }
    [pscustomobject]@{ Locate = $script:SrunDefaultLocate; Source = 'default' }
}

# Single area-name validator shared by the login path and the manager UI.
function Get-SrunPreset([string]$Locate) {
    $preset = $script:SrunPresets[$Locate]
    if (-not $preset) { throw "unknown area '$Locate' (expected: $($script:SrunPresets.Keys -join ', '))" }
    return $preset
}

function Get-SrunConfig {
    $eff    = Get-SrunEffectiveLocate
    $preset = Get-SrunPreset $eff.Locate

    $user = [Environment]::GetEnvironmentVariable($script:SrunEnvNumber, 'Process')
    $pass = [Environment]::GetEnvironmentVariable($script:SrunEnvPasswd, 'Process')
    if ([string]::IsNullOrEmpty($user) -or [string]::IsNullOrEmpty($pass)) {
        throw "credentials are not set ($($script:SrunEnvNumber) / $($script:SrunEnvPasswd))"
    }

    [pscustomobject]@{
        Pass     = $pass
        Username = "$user$($script:SrunDomain)"
        Url      = $preset.Url
        AcId     = $preset.AcId
    }
}
