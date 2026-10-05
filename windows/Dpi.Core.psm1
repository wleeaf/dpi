Set-StrictMode -Version Latest

function Read-DpiSettings {
    param([Parameter(Mandatory)][string]$Path)
    $settings = @{ PROFILE = 'discord'; STRATEGY = 'default'; VOICE = 'yes' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing settings: $Path" }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $content = ($line -split '#', 2)[0].Trim()
        if (-not $content) { continue }
        if ($content -cnotmatch '^([A-Z_]+)\s*=\s*([a-z]+)$') { throw "Invalid setting: $line" }
        $key, $value = $Matches[1], $Matches[2]
        $allowed = @{ PROFILE = @('discord', 'all'); STRATEGY = @('default', 'split'); VOICE = @('yes', 'no') }
        if (-not $allowed.ContainsKey($key) -or $value -cnotin $allowed[$key]) { throw "Unsupported setting: $key=$value" }
        $settings[$key] = $value
    }
    return $settings
}

function Get-DpiEngineArguments {
    param([Parameter(Mandatory)][hashtable]$Settings, [Parameter(Mandatory)][string]$Base)
    $root = $Base.Replace('\', '/')
    $ports = '443'
    if ($Settings.VOICE -eq 'yes') { $ports += ',50000-50099' }
    $result = [Collections.Generic.List[string]]::new()
    $result.Add('--wf-tcp=80,443')
    $result.Add("--wf-udp=$ports")
    $hostArgument = "--hostlist=$root/profiles/discord.txt"
    foreach ($port in @('80', '443')) {
        if ($port -eq '443') { $result.Add('--new') }
        $result.Add("--filter-tcp=$port")
        if ($Settings.PROFILE -eq 'discord') { $result.Add($hostArgument) }
        if ($Settings.STRATEGY -eq 'default') {
            if ($port -eq '80') {
                $result.Add('--dpi-desync=fake,multisplit')
                $result.Add('--dpi-desync-split-pos=method+2')
                $result.Add('--dpi-desync-fooling=md5sig')
            } else {
                $result.Add('--dpi-desync=fake,multidisorder')
                $result.Add('--dpi-desync-split-pos=1,midsld')
                $result.Add('--dpi-desync-fooling=badseq,md5sig')
                $result.Add("--dpi-desync-fake-tls=$root/files/fake/tls_clienthello_www_google_com.bin")
            }
        } else {
            $result.Add('--dpi-desync=multisplit')
            $position = if ($port -eq '80') { 'method+2' } else { '1,midsld' }
            $result.Add("--dpi-desync-split-pos=$position")
        }
        $result.Add('--dpi-desync-cutoff=n9')
    }
    $result.Add('--new')
    $result.Add('--filter-udp=443')
    if ($Settings.PROFILE -eq 'discord') { $result.Add($hostArgument) }
    $result.Add('--dpi-desync=fake')
    $result.Add('--dpi-desync-repeats=6')
    $result.Add("--dpi-desync-fake-quic=$root/files/fake/quic_initial_www_google_com.bin")
    $result.Add('--dpi-desync-cutoff=n9')
    if ($Settings.VOICE -eq 'yes') {
        foreach ($argument in @('--new', '--filter-udp=50000-50099', '--filter-l7=discord', '--dpi-desync=fake', '--dpi-desync-repeats=2', "--dpi-desync-fake-discord=$root/files/fake/discord-ip-discovery-with-port.bin", '--dpi-desync-cutoff=n9')) {
            $result.Add($argument)
        }
    }
    return $result.ToArray()
}

function ConvertTo-DpiArgumentFile {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # winws reads @files using POSIX wordexp. Quote each literal argument and
    # escape expansion characters, including paths containing spaces or $.
    return (($Arguments | ForEach-Object {
        '"' + $_.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`') + '"'
    }) -join "`n") + "`n"
}

function ConvertTo-DpiWindowsCommandLine {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Windows argv escaping, including embedded quotes and trailing backslashes.
    # ProcessStartInfo avoids PowerShell 5.1's native quote stripping for sc.exe.
    return ($Arguments | ForEach-Object {
        $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }) -join ' '
}

Export-ModuleMember -Function Read-DpiSettings, Get-DpiEngineArguments, ConvertTo-DpiArgumentFile, ConvertTo-DpiWindowsCommandLine
