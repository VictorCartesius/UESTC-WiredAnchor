# SrunCrypto.ps1 : For Srun authentication encryption.

function To-Hex([byte[]]$b) { ($b | ForEach-Object { $_.ToString('x2') }) -join '' }

function Sr-Words([string]$s, [bool]$withLen) {
    $w = New-Object System.Collections.Generic.List[int64]
    for ($i = 0; $i -lt $s.Length; $i += 4) {
        $v = [int64]0
        for ($j = 0; $j -lt 4; $j++) {
            $c = if ($i + $j -lt $s.Length) { [int][char]$s[$i + $j] } else { 0 }
            $v = $v -bor ([int64]$c -shl (8 * $j))
        }
        $w.Add($v)
    }
    if ($withLen) { $w.Add([int64]$s.Length) }
    return ,$w.ToArray()
}

function Sr-XEncode([string]$msg, [string]$key) {
    $p = Sr-Words $msg $true; $k = Sr-Words $key $false
    if ($k.Length -lt 4) { $k += New-Object 'int64[]' (4 - $k.Length) }
    $n = $p.Length - 1; $z = $p[$n]; $y = $p[0]; $d = [int64]0
    for ($q = [int][Math]::Floor(6 + 52.0 / ($n + 1)); $q -gt 0; $q--) {
        $d = ($d + 2654435769L) -band 4294967295; $e = ($d -shr 2) -band 3
        for ($i = 0; $i -le $n; $i++) {
            $y = $p[($i + 1) % ($n + 1)]
            $m = (($z -shr 5) -bxor (($y -shl 2) -band 4294967295)) + ((($y -shr 3) -bxor (($z -shl 4) -band 4294967295)) -bxor ($d -bxor $y)) + (($k[($i -band 3) -bxor $e]) -bxor $z)
            $p[$i] = ($p[$i] + $m) -band 4294967295; $z = $p[$i]
        }
    }
    -join ($p | ForEach-Object { [char]($_ -band 0xFF); [char](($_ -shr 8) -band 0xFF); [char](($_ -shr 16) -band 0xFF); [char](($_ -shr 24) -band 0xFF) })
}

function Sr-Base64([string]$s) {
    $std = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    $cus = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'
    -join ([Convert]::ToBase64String([byte[]][char[]]$s).ToCharArray() | ForEach-Object { $i = $std.IndexOf($_); if ($i -ge 0) { $cus[$i] } else { $_ } })
}

function Sr-Md5([string]$p, [string]$t) {
    $h = New-Object System.Security.Cryptography.HMACMD5
    try {
        $h.Key = [System.Text.Encoding]::UTF8.GetBytes($t)
        To-Hex ($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($p)))
    }
    finally {
        # HMACMD5 holds unmanaged state; without Dispose it lingers until the finalizer runs.
        $h.Dispose()
    }
}

function Sr-Sha1([string]$v) {
    $h = [System.Security.Cryptography.SHA1]::Create()
    try {
        To-Hex ($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($v)))
    }
    finally {
        $h.Dispose()
    }
}
