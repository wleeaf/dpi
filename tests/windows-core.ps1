$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Root 'windows/Dpi.Core.psm1') -Force
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
$work = Join-Path ([IO.Path]::GetTempPath()) ('dpi-test-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $path = Join-Path $work 'dpi.conf'
    foreach ($profile in @('discord', 'all')) {
        foreach ($strategy in @('default', 'split')) {
            foreach ($voice in @('yes', 'no')) {
                [IO.File]::WriteAllText($path, "PROFILE=$profile`nSTRATEGY=$strategy`nVOICE=$voice`n")
                $settings = Read-DpiSettings -Path $path
                $arguments = @(Get-DpiEngineArguments -Settings $settings -Base 'C:\Program Files\DPI')
                Assert-True ($arguments[0] -eq '--wf-tcp=80,443') 'Missing TCP capture filter'
                Assert-True (($arguments -contains '--filter-l7=discord') -eq ($voice -eq 'yes')) 'Incorrect voice filter'
                $hosts = @($arguments | Where-Object { $_ -like '--hostlist=*' })
                Assert-True ($hosts.Count -eq $(if ($profile -eq 'discord') { 3 } else { 0 })) 'Incorrect host list filtering'
                Assert-True (($arguments -contains '--dpi-desync=fake,multidisorder') -eq ($strategy -eq 'default')) 'Incorrect strategy'
                # On Windows CI, verify all combinations using the actual engine.
                $binary = Join-Path $Root 'windows/bin/winws.exe'
                if (Test-Path -LiteralPath $binary) {
                    $engineBase = Join-Path $work 'DPI with spaces'
                    New-Item -ItemType Directory -Path $engineBase -Force | Out-Null
                    Copy-Item (Join-Path $Root 'profiles'), (Join-Path $Root 'files') -Destination $engineBase -Recurse -Force
                    $engineArgs = @(Get-DpiEngineArguments -Settings $settings -Base $engineBase)
                    & $binary '--dry-run' @engineArgs
                    if ($LASTEXITCODE -ne 0) { throw 'winws rejected a preset' }
                    $argumentFile = Join-Path $work 'engine.conf'
                    [IO.File]::WriteAllText($argumentFile, (ConvertTo-DpiArgumentFile (@('--dry-run') + $engineArgs)), [Text.UTF8Encoding]::new($false))
                    & $binary ('@' + $argumentFile.Replace('\', '/'))
                    if ($LASTEXITCODE -ne 0) { throw 'winws rejected its argument file' }
                }
            }
        }
    }
    foreach ($invalid in @('PROFILE=$(echo bad)', 'VOICE=true', 'OTHER=yes', 'STRATEGY=unknown', "PROFILE='all'", 'profile=all')) {
        [IO.File]::WriteAllText($path, $invalid)
        $rejected = $false
        try { Read-DpiSettings -Path $path | Out-Null } catch { $rejected = $true }
        Assert-True $rejected "Setting was not rejected: $invalid"
    }
    [IO.File]::WriteAllText($path, " # comment`r`n PROFILE = all # trailing comment`nVOICE=no")
    $settings = Read-DpiSettings -Path $path
    Assert-True ($settings.PROFILE -eq 'all' -and $settings.VOICE -eq 'no') 'Whitespace parsing failed'
    $quoted = ConvertTo-DpiArgumentFile @('--hostlist=C:/DPI $files/hosts.txt', '--new')
    Assert-True ($quoted.Contains('\$files')) 'Argument file allows variable expansion'
    $commandLine = ConvertTo-DpiWindowsCommandLine @('binPath=', '"C:\Program Files\DPI\bin\winws.exe" "@C:/ProgramData/DPI/engine.conf"', 'C:\trailing\')
    Assert-True ($commandLine.Contains('\"C:\Program Files\DPI\bin\winws.exe\"')) 'Service executable quotes were lost'
    Assert-True ($commandLine.EndsWith('C:\trailing\\"')) 'Trailing path backslash was lost'
    foreach ($file in Get-ChildItem (Join-Path $Root 'windows') -Recurse -Include *.ps1, *.psm1) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert-True (-not $errors) "PowerShell syntax error in $($file.Name)"
    }
    Write-Host 'Windows configuration and argument checks passed (8 preset combinations).'
} finally { Remove-Item -LiteralPath $work -Recurse -Force }
