[CmdletBinding()]
param(
    [ValidateSet('gui', 'install', 'start', 'restart', 'stop', 'enable', 'disable', 'status', 'doctor', 'configure', 'uninstall', 'args')]
    [string]$Command = 'gui',
    [ValidateSet('discord', 'all')][string]$Profile,
    [ValidateSet('default', 'split')][string]$Strategy,
    [ValidateSet('yes', 'no')][string]$Voice,
    [switch]$Elevate,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Dpi.Core.psm1') -Force
if ($env:OS -ne 'Windows_NT') { throw 'This manager requires Windows 10/11 x64.' }
$Target = Join-Path $env:ProgramFiles 'DPI'
$Data = Join-Path $env:ProgramData 'DPI'
$Config = Join-Path $Data 'dpi.conf'
$ServiceName = 'DpiBypass'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if ($Command -notin @('status', 'doctor', 'args') -and -not (Test-Admin)) {
    if (-not $Elevate) { throw 'Run in an administrator PowerShell, or use Open DPI.cmd.' }
    $parameters = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Command ' + $Command
    foreach ($entry in @(@('Profile', $Profile), @('Strategy', $Strategy), @('Voice', $Voice))) {
        if ($entry[1]) { $parameters += ' -' + $entry[0] + ' ' + $entry[1] }
    }
    if ($NoStart) { $parameters += ' -NoStart' }
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $parameters -Wait -PassThru
    exit $process.ExitCode
}

function Invoke-Sc {
    param([string[]]$Arguments, [switch]$IgnoreMissing)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = "$env:SystemRoot\System32\sc.exe"
    $info.Arguments = ConvertTo-DpiWindowsCommandLine $Arguments
    $info.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -and -not ($IgnoreMissing -and $process.ExitCode -eq 1060)) {
        throw "Service configuration failed (sc.exe exit $($process.ExitCode))."
    }
    $process.Dispose()
}
function Assert-NoConflict {
    Assert-ServiceOwned
    foreach ($name in @('zapret', 'winws', 'winws1')) {
        $other = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($other -and ($other.Status -ne 'Stopped' -or $other.StartType -ne 'Disabled')) {
            throw "Existing $name service detected. Stop and disable it before using DPI."
        }
    }
    $expected = Join-Path $Target 'bin\winws.exe'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'")) {
        if ($process.ExecutablePath -ne $expected) { throw 'Another winws process is running. Close it first.' }
    }
}
function Assert-ServiceOwned {
    $existing = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $expected = '"' + (Join-Path $Target 'bin\winws.exe') + '" '
    if ($existing -and -not $existing.PathName.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The $ServiceName service belongs to another installation. It will not be changed."
    }
}
function Assert-Installed {
    Assert-ServiceOwned
    if (-not (Test-Path -LiteralPath (Join-Path $Target 'bin\winws.exe'))) { throw 'Install first using Install.cmd.' }
}
function Stop-Dpi {
    Assert-ServiceOwned
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
}
function Remove-DpiDriver {
    # WinDivert remains loaded after its final application handle closes.
    # Only unload drivers registered from this installation's exact path.
    $expected = Join-Path $Target 'bin\WinDivert64.sys'
    foreach ($driver in @(Get-CimInstance Win32_SystemDriver -Filter "Name LIKE 'WinDivert%'")) {
        $path = $driver.PathName.Trim('"').Replace('\??\', '').Replace('\\?\', '')
        if (-not $path.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($driver.State -ne 'Stopped') { Invoke-Sc -Arguments @('stop', $driver.Name) -IgnoreMissing }
        # WinDivert may already have marked its own service for deletion.
        Invoke-Sc -Arguments @('delete', $driver.Name) -IgnoreMissing
    }
}
function Test-Engine {
    param([string]$Base, [hashtable]$Settings)
    $binary = Join-Path $Base 'bin\winws.exe'
    $arguments = @(Get-DpiEngineArguments -Settings $Settings -Base $Base)
    & $binary '--dry-run' @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Engine validation failed (exit $LASTEXITCODE)." }
}
function Protect-Data {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($entry[0]), $entry[1],
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Data -AclObject $acl
}
function Update-ServiceConfiguration {
    $settings = Read-DpiSettings -Path $Config
    Test-Engine -Base $Target -Settings $settings
    $arguments = @(Get-DpiEngineArguments -Settings $settings -Base $Target)
    # Cygwin wordexp in @files depends on a shell and user-specific mounts.
    # SCM runs as LocalSystem; pass literal arguments for standalone installs.
    $binaryPath = ConvertTo-DpiWindowsCommandLine (@((Join-Path $Target 'bin\winws.exe')) + $arguments)
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Invoke-Sc -Arguments @('config', $ServiceName, 'binPath=', $binaryPath)
    } else {
        Invoke-Sc -Arguments @('create', $ServiceName, 'binPath=', $binaryPath, 'start=', 'auto', 'DisplayName=', 'DPI bypass')
    }
    Invoke-Sc -Arguments @('description', $ServiceName, 'Discord and website DPI bypass')
    Invoke-Sc -Arguments @('failure', $ServiceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/10000/restart/30000')
}
function Start-Dpi {
    Assert-Installed
    Assert-NoConflict
    # Validate before stopping; invalid settings preserve a running service.
    Test-Engine -Base $Target -Settings (Read-DpiSettings -Path $Config)
    Stop-Dpi
    Update-ServiceConfiguration
    if ((Get-Service -Name $ServiceName).StartType -eq 'Disabled') {
        Set-Service -Name $ServiceName -StartupType Manual
    }
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Start-Sleep -Seconds 1
    if ((Get-Service -Name $ServiceName).Status -ne 'Running') { throw 'DPI stopped after startup. Run dpi.ps1 -Command doctor.' }
    Write-Host 'DPI is running. Restart Discord to open fresh connections.'
}
function Install-Dpi {
    Assert-NoConflict
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'This release supports Intel/AMD x64 Windows only.' }
    if ($PSScriptRoot -eq $Target) { throw 'Install from a newly extracted release.' }
    foreach ($file in @('bin\winws.exe', 'bin\cygwin1.dll', 'bin\WinDivert.dll', 'bin\WinDivert64.sys', 'LICENSE', 'dpi.conf.example')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "Missing $file. Extract the full release ZIP first." }
    }
    $settingsPath = if (Test-Path -LiteralPath $Config) { $Config } else { Join-Path $PSScriptRoot 'dpi.conf.example' }
    Test-Engine -Base $PSScriptRoot -Settings (Read-DpiSettings -Path $settingsPath)
    Stop-Dpi
    Remove-DpiDriver
    New-Item -ItemType Directory -Path $Target, $Data -Force | Out-Null
    Protect-Data
    foreach ($folder in @('bin', 'profiles', 'files', 'docs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $folder) -Destination $Target -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'third-party')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'third-party') -Destination $Target -Recurse -Force
    }
    foreach ($name in @('dpi.ps1', 'Dpi.Core.psm1', 'Open DPI.cmd', 'LICENSE', 'README.md', 'dpi.conf.example')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $Target -Force
    }
    if (-not (Test-Path -LiteralPath $Config)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dpi.conf.example') -Destination $Config }
    Update-ServiceConfiguration
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'DPI.lnk'))
    $shortcut.TargetPath = Join-Path $Target 'Open DPI.cmd'
    $shortcut.WorkingDirectory = $Target
    $shortcut.Save()
    if (-not $NoStart) { Set-Service -Name $ServiceName -StartupType Automatic; Start-Dpi }
    Write-Host "Installed. Settings: $Config"
}
function Write-Settings {
    param([string]$SelectedProfile, [string]$SelectedStrategy, [string]$SelectedVoice)
    [IO.File]::WriteAllText($Config, "PROFILE=$SelectedProfile`r`nSTRATEGY=$SelectedStrategy`r`nVOICE=$SelectedVoice`r`n", [Text.UTF8Encoding]::new($false))
}
function Show-DpiWindow {
    if (-not (Test-Path -LiteralPath $Config)) { Install-Dpi }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'DPI'; $form.ClientSize = [Drawing.Size]::new(440, 310)
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)
    $status = [Windows.Forms.Label]::new(); $status.SetBounds(24, 20, 390, 28); $form.Controls.Add($status)
    $settings = Read-DpiSettings -Path $Config
    $selectors = @{}
    $row = 65
    foreach ($item in @(@('PROFILE', 'Traffic', @('discord', 'all')), @('STRATEGY', 'Strategy', @('default', 'split')), @('VOICE', 'Discord voice', @('yes', 'no')))) {
        $label = [Windows.Forms.Label]::new(); $label.Text = $item[1]; $label.SetBounds(24, $row, 150, 28); $form.Controls.Add($label)
        $combo = [Windows.Forms.ComboBox]::new(); $combo.DropDownStyle = 'DropDownList'; $combo.SetBounds(185, $row, 225, 28)
        $combo.Items.AddRange([object[]]$item[2]); $combo.SelectedItem = $settings[$item[0]]; $form.Controls.Add($combo)
        $selectors[$item[0]] = $combo; $row += 40
    }
    $connect = [Windows.Forms.Button]::new(); $connect.Text = 'Connect / apply'; $connect.SetBounds(24, 200, 185, 40); $form.Controls.Add($connect)
    $stop = [Windows.Forms.Button]::new(); $stop.Text = 'Disconnect'; $stop.SetBounds(225, 200, 185, 40); $form.Controls.Add($stop)
    $boot = [Windows.Forms.CheckBox]::new(); $boot.Text = 'Start automatically with Windows'; $boot.SetBounds(24, 260, 380, 28)
    $boot.Checked = (Get-Service -Name $ServiceName).StartType -eq 'Automatic'; $form.Controls.Add($boot)
    $boot.Add_CheckedChanged({ Set-Service -Name $ServiceName -StartupType $(if ($boot.Checked) { 'Automatic' } else { 'Manual' }) })
    $connect.Add_Click({
        try {
            Write-Settings $selectors.PROFILE.SelectedItem $selectors.STRATEGY.SelectedItem $selectors.VOICE.SelectedItem
            Start-Dpi
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'DPI') | Out-Null }
    })
    $stop.Add_Click({ try { Stop-Dpi } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'DPI') | Out-Null } })
    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 1000
    $timer.Add_Tick({ $status.Text = 'Status: ' + (Get-Service -Name $ServiceName).Status })
    $timer.Start(); $form.Add_FormClosed({ $timer.Dispose() })
    $status.Text = 'Status: ' + (Get-Service -Name $ServiceName).Status
    [void]$form.ShowDialog()
}

try {
    switch ($Command) {
        'gui' { Show-DpiWindow }
        'install' { Install-Dpi }
        { $_ -in @('start', 'restart') } { Start-Dpi }
        'stop' { Stop-Dpi }
        'enable' { Assert-Installed; Set-Service -Name $ServiceName -StartupType Automatic; Start-Dpi }
        'disable' { Assert-Installed; Stop-Dpi; Set-Service -Name $ServiceName -StartupType Disabled }
        'status' { Get-Service -Name $ServiceName }
        'args' { Get-DpiEngineArguments -Settings (Read-DpiSettings -Path $Config) -Base $Target }
        'configure' {
            Assert-Installed
            $settings = Read-DpiSettings -Path $Config
            if ($Profile) { $settings.PROFILE = $Profile }; if ($Strategy) { $settings.STRATEGY = $Strategy }; if ($Voice) { $settings.VOICE = $Voice }
            Write-Settings $settings.PROFILE $settings.STRATEGY $settings.VOICE
            Start-Dpi
        }
        'doctor' {
            Assert-Installed
            Test-Engine -Base $Target -Settings (Read-DpiSettings -Path $Config)
            Get-Service -Name $ServiceName
            Resolve-DnsName discord.com
            Invoke-WebRequest -Uri 'https://discord.com' -Method Head -UseBasicParsing -TimeoutSec 10 | Select-Object StatusCode
            Write-Host 'HTTPS reachability does not verify login or voice. Check Windows DNS over HTTPS settings if DNS fails.'
        }
        'uninstall' {
            Assert-Installed; Stop-Dpi
            Remove-DpiDriver
            Invoke-Sc -Arguments @('delete', $ServiceName)
            Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'DPI.lnk') -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $Target -Recurse -Force
            Remove-Item -LiteralPath (Join-Path $Data 'engine.conf') -ErrorAction SilentlyContinue
            Write-Host "Uninstalled. Your settings remain in $Config."
        }
    }
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    if ($Command -eq 'gui') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
