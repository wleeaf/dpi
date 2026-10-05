param([string]$Version = 'dev')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'Invalid version' }
$Root = Split-Path -Parent $PSScriptRoot
$PackageName = "dpi-$Version-windows-x86_64"
$Work = Join-Path ([IO.Path]::GetTempPath()) ('dpi-package-' + [Guid]::NewGuid())
$Package = Join-Path $Work $PackageName
$Dist = Join-Path $Root 'dist'
$RuntimeFiles = @('winws.exe', 'cygwin1.dll', 'WinDivert.dll', 'WinDivert64.sys')
foreach ($file in $RuntimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root "windows/bin/$file") -PathType Leaf)) {
        throw "Missing Windows runtime $file. Build the engine and fetch WinDivert first."
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'windows/third-party/NOTICE.txt'))) {
    throw 'Fetch matching Cygwin dependency sources before packaging.'
}
try {
    New-Item -ItemType Directory -Path $Package, $Dist -Force | Out-Null
    foreach ($name in @('dpi.ps1', 'Dpi.Core.psm1', 'Install.cmd', 'Open DPI.cmd', 'Uninstall.cmd')) {
        Copy-Item -LiteralPath (Join-Path $Root "windows/$name") -Destination $Package
    }
    New-Item -ItemType Directory -Path (Join-Path $Package 'bin') -Force | Out-Null
    foreach ($file in $RuntimeFiles) {
        Copy-Item -LiteralPath (Join-Path $Root "windows/bin/$file") -Destination (Join-Path $Package 'bin')
    }
    Copy-Item -LiteralPath (Join-Path $Root 'windows/third-party') -Destination $Package -Recurse
    Copy-Item -LiteralPath (Join-Path $Root 'profiles') -Destination $Package -Recurse
    New-Item -ItemType Directory -Path (Join-Path $Package 'docs') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'docs/LINUX.md'), (Join-Path $Root 'docs/MACOS.md'), (Join-Path $Root 'docs/DEVELOPMENT.md') -Destination (Join-Path $Package 'docs')
    $Payloads = Join-Path $Package 'files/fake'
    New-Item -ItemType Directory -Path $Payloads -Force | Out-Null
    foreach ($name in @('tls_clienthello_www_google_com', 'quic_initial_www_google_com', 'discord-ip-discovery-with-port')) {
        Copy-Item -LiteralPath (Join-Path $Root "files/fake/$name.bin") -Destination $Payloads
    }
    foreach ($name in @('README.md', 'LICENSE', 'dpi.conf.example')) {
        Copy-Item -LiteralPath (Join-Path $Root $name) -Destination $Package
    }
    $Archive = Join-Path $Dist "$PackageName.zip"
    Compress-Archive -Path $Package -DestinationPath $Archive -Force
    $hash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$Archive.sha256", "$hash  $PackageName.zip`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $Archive"
} finally { if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force } }
