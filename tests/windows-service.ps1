param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Intended only for the disposable Windows CI runner; touches a real service.
if ($env:CI -ne 'true') { throw 'Service smoke test is restricted to disposable CI runners.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('dpi-smoke-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Expand-Archive -LiteralPath $Archive -DestinationPath $work
    $release = Get-ChildItem -LiteralPath $work -Directory | Select-Object -First 1
    $manager = Join-Path $release.FullName 'dpi.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command install -NoStart
    if ($LASTEXITCODE -ne 0) { throw 'Install failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command start
    if ($LASTEXITCODE -ne 0) { throw 'Service startup failed' }
    if ((Get-Service DpiBypass).Status -ne 'Running') { throw 'Engine did not register with SCM' }
    $config = Join-Path $env:ProgramData 'DPI/dpi.conf'
    [IO.File]::WriteAllText($config, "PROFILE=all`nSTRATEGY=split`nVOICE=no`n")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command install -NoStart
    if ($LASTEXITCODE -ne 0) { throw 'Upgrade failed' }
    if ([IO.File]::ReadAllText($config) -notmatch 'STRATEGY=split') { throw 'Upgrade lost configuration' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command disable
    if ($LASTEXITCODE -ne 0 -or (Get-Service DpiBypass).Status -ne 'Stopped') { throw 'Disable failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command start
    if ($LASTEXITCODE -ne 0) { throw 'Starting a disabled service failed' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Command uninstall
    if ($LASTEXITCODE -ne 0 -or (Get-Service DpiBypass -ErrorAction SilentlyContinue)) { throw 'Uninstall failed' }
    if (-not (Test-Path -LiteralPath $config)) { throw 'Uninstall did not retain user settings' }
    Write-Host 'Windows service install, start, upgrade, disable, and uninstall checks passed.'
} finally {
    $log = Join-Path $env:ProgramData 'DPI/service.log'
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 40 }
    $service = Get-Service DpiBypass -ErrorAction SilentlyContinue
    if ($service) { Stop-Service DpiBypass -ErrorAction SilentlyContinue; & sc.exe delete DpiBypass | Out-Null }
    Remove-Item -LiteralPath $work -Recurse -Force
}
