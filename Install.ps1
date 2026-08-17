<#
    Package Deployer Studio - installer

    Installs per-user (no admin rights needed):
      %LOCALAPPDATA%\Programs\PackageDeployerStudio

    Creates a Start Menu entry, an optional desktop shortcut, and an entry in
    Apps and features so it can be uninstalled the normal way.

    Run:   Install.cmd            (double-click)
    or:    powershell -ExecutionPolicy Bypass -File Install.ps1
    Remove: Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoDesktopShortcut,
    [switch]$Unblock,          # unblock without asking
    [switch]$NoUnblock,        # skip unblocking without asking
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\PackageDeployerStudio')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$AppName   = 'Package Deployer Studio'
$AppId     = 'PackageDeployerStudio'
$Source    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RegKey    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId"
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$Desktop   = [Environment]::GetFolderPath('Desktop')

function Say  { param($m) Write-Host "  $m" }
function Good { param($m) Write-Host "  $m" -ForegroundColor Green }
function Bad  { param($m) Write-Host "  $m" -ForegroundColor Red }
function Note { param($m) Write-Host "  $m" -ForegroundColor Yellow }

function Confirm-Box {
    param([string]$Text, [string]$Caption = $AppName)
    try {
        return ([System.Windows.Forms.MessageBox]::Show(
            $Text, $Caption,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1) -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        # No desktop session (CI, remoting) - fall back to the console.
        Write-Host ""
        $a = Read-Host "  $Text  [Y/n]"
        return ($a -eq '' -or $a -match '^(y|yes)$')
    }
}

function Get-FullPathSafe {
    param([string]$Path)
    try { return ([IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return $Path }
}

function Unblock-Tree {
    <#
      Windows tags every file that came out of a downloaded zip with a
      Zone.Identifier alternate data stream. .NET then refuses to load the
      package assembly and Package Deployer reports the useless
      "No Import packages found".

      Note the -Stream parameter: building a "path:Zone.Identifier" string and
      passing it as a normal path fails with "The given path's format is not
      supported", and because that throws it is easy to swallow and believe
      files were unblocked when nothing happened.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        try {
            if (Get-Item -LiteralPath $f.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
                Unblock-File -LiteralPath $f.FullName -ErrorAction SilentlyContinue
                $n++
            }
        } catch { }
    }
    return $n
}

Write-Host ""
Write-Host "  $AppName" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------" -ForegroundColor DarkGray

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Host "  Uninstalling..." -ForegroundColor Cyan
    Write-Host ""
    foreach ($lnk in @((Join-Path $StartMenu "$AppName.lnk"), (Join-Path $Desktop "$AppName.lnk"))) {
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Say "removed shortcut $(Split-Path -Leaf $lnk)" }
    }
    if (Test-Path -LiteralPath $RegKey) { Remove-Item -LiteralPath $RegKey -Recurse -Force; Say "removed Apps and features entry" }

    if (Test-Path -LiteralPath $InstallDir) {
        $keep = Join-Path $InstallDir 'PackageDeployertool'
        if (Test-Path -LiteralPath $keep) {
            Note "leaving PackageDeployertool in place: $keep"
            foreach ($i in @(Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $_.Name -ne 'PackageDeployertool' })) {
                Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Say "removed $InstallDir"
        }
    }
    Write-Host ""
    Good "Uninstalled."
    Write-Host ""
    return
}

# ------------------------------------------------------------------ install
Say "Installing to $InstallDir"
Write-Host ""

if (-not (Test-Path -LiteralPath (Join-Path $Source 'PackageDeployerStudio.ps1'))) {
    Bad "PackageDeployerStudio.ps1 is not next to this installer. Extract the whole zip first."
    Write-Host ""
    exit 1
}

$psv = $PSVersionTable.PSVersion
if ($psv.Major -lt 5) { Bad "PowerShell 5.1 or later is required (found $psv)."; exit 1 }

if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

$payload = @('PackageDeployerStudio.ps1','PackageDeployerStudio.bat','PackageDeployerStudio.ico',
             'README.md','LICENSE','HOW-TO-DEPLOY-A-PACKAGE.md','Install.ps1','Install.cmd')
$copied = 0
foreach ($f in $payload) {
    $src = Join-Path $Source $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $f) -Force
        $copied++
    }
}
Say "copied $copied file(s)"

# ------------------------------------------------- Package Deployer tool
# The app is configured with a working tool folder at install time so the
# Deploy page is usable straight away instead of erroring on first click.
$toolDir = Join-Path $InstallDir 'PackageDeployertool'
$srcTool = Join-Path $Source 'PackageDeployertool'

function Test-ToolFolder {
    param([string]$p)
    return ($p -and (Test-Path -LiteralPath (Join-Path $p 'PackageDeployer.exe')))
}

function Find-ExistingTool {
    $c = @($srcTool,
           (Join-Path $Source 'PackageDeployerTool'),
           (Join-Path (Split-Path -Parent $Source) 'PackageDeployertool'),
           $toolDir)
    foreach ($d in @(Get-ChildItem -LiteralPath $Source -Directory -ErrorAction SilentlyContinue)) { $c += $d.FullName }
    foreach ($pkg in @('microsoft.crmsdk.xrmtooling.packagedeployment.wpf','microsoft.crmsdk.xrmtooling.packagedeployment')) {
        $root = Join-Path $env:USERPROFILE ".nuget\packages\$pkg"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($v in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $c += (Join-Path $v.FullName 'tools'); $c += (Join-Path $v.FullName 'content\bin\coretools'); $c += $v.FullName
        }
    }
    foreach ($p in $c) { if (Test-ToolFolder $p) { return $p } }
    return $null
}

$configuredTool = $null
if (Test-ToolFolder $toolDir) {
    $configuredTool = $toolDir
    Say "Package Deployer tool already installed"
} else {
    $found = Find-ExistingTool
    if ($found) {
        if ((Get-FullPathSafe $found) -like ((Get-FullPathSafe $Source) + '*')) {
            Say "copying the Package Deployer tool (this takes a moment) ..."
            Copy-Item -LiteralPath $found -Destination $toolDir -Recurse -Force
            $configuredTool = $toolDir
            Good "copied the Package Deployer tool into the install folder"
        } else {
            $configuredTool = $found
            Good "found the Package Deployer tool at $found"
        }
    } else {
        Write-Host ""
        Note "Microsoft's Package Deployer tool was not found."
        if (Confirm-Box @"
Microsoft's Package Deployer tool was not found on this machine.

It is not redistributed with this app. The Deploy page's Clean / Load / Verify /
Launch steps need it; deploying with the PAC CLI does not.

Do you have it already and want to point at it now?

Yes - browse for the folder containing PackageDeployer.exe
No  - skip; you can set it later on the Deploy page
"@ "$AppName - Package Deployer tool") {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Locate PackageDeployer.exe'
            $dlg.Filter = 'PackageDeployer.exe|PackageDeployer.exe|All files (*.*)|*.*'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $picked = Split-Path -Parent $dlg.FileName
                if (Test-ToolFolder $picked) { $configuredTool = $picked; Good "using $picked" }
                else { Bad "PackageDeployer.exe was not in that folder" }
            }
        }
    }
}

if (-not $configuredTool) {
    Note "No tool folder configured. Set it on the Deploy page when you have one."
}

# ------------------------------------------------------------------- unblock
Write-Host ""
$doUnblock = $true
if     ($NoUnblock) { $doUnblock = $false }
elseif ($Unblock)   { $doUnblock = $true }
else {
    $doUnblock = Confirm-Box @"
Unblock the files that were just installed?

Windows marks everything that came out of a downloaded zip as blocked. If these
files stay blocked, the Package Deployer tool fails to load its package assembly
and reports "No Import packages found" with no explanation.

Choosing Yes clears that mark on the installed app$(if (Test-Path -LiteralPath $toolDir) { ', the Package Deployer tool' })
and the folder you extracted. Nothing else on your machine is touched.

Recommended: Yes
"@ "$AppName - unblock files"
}

if ($doUnblock) {
    $targets = @($InstallDir)
    if ((Get-FullPathSafe $Source) -ne (Get-FullPathSafe $InstallDir)) { $targets += $Source }
    $total = 0
    foreach ($t in $targets) {
        $n = Unblock-Tree $t
        $total += $n
        Say "unblocked $n file(s) in $t"
    }
    Good "unblocked $total file(s) in total"
} else {
    Note "skipped unblocking - if the tool later says 'No Import packages found', run:"
    Note "  Get-ChildItem '$InstallDir' -Recurse -File | Unblock-File"
}

# shortcuts
$icon   = Join-Path $InstallDir 'PackageDeployerStudio.ico'
$target = Join-Path $InstallDir 'PackageDeployerStudio.bat'
$shell  = New-Object -ComObject WScript.Shell

function New-Shortcut {
    param([string]$Path)
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath       = $target
    $s.WorkingDirectory = $InstallDir
    $s.Description      = 'Front-end for the Microsoft Package Deployer tool and the Power Platform CLI'
    $s.WindowStyle      = 7                       # start the launcher minimised; the WPF window is the UI
    if (Test-Path -LiteralPath $icon) { $s.IconLocation = $icon }
    $s.Save()
}

New-Shortcut (Join-Path $StartMenu "$AppName.lnk")
Say "Start Menu shortcut created"

if (-not $NoDesktopShortcut) {
    New-Shortcut (Join-Path $Desktop "$AppName.lnk")
    Say "desktop shortcut created"
}

# Apps and features entry
$verLine = Select-String -LiteralPath (Join-Path $InstallDir 'PackageDeployerStudio.ps1') -Pattern "AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
$version = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { '1.0.0' }

if (-not (Test-Path -LiteralPath $RegKey)) { New-Item -Path $RegKey -Force | Out-Null }
$size = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum / 1KB)
New-ItemProperty -Path $RegKey -Name 'DisplayName'     -Value $AppName    -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'DisplayVersion'  -Value $version    -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'Publisher'       -Value 'Alphavima' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'InstallLocation' -Value $InstallDir -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'DisplayIcon'     -Value $icon       -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'NoModify'        -Value 1           -PropertyType DWord  -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'NoRepair'        -Value 1           -PropertyType DWord  -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'EstimatedSize'   -Value $size       -PropertyType DWord  -Force | Out-Null
New-ItemProperty -Path $RegKey -Name 'UninstallString' `
    -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}\Install.ps1" -Uninstall' -f $InstallDir) `
    -PropertyType String -Force | Out-Null
Say "registered in Apps and features (v$version)"

# Seed the app's settings so it starts already configured.
$stateDir = Join-Path $InstallDir '.pdstudio'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$settingsFile = Join-Path $stateDir 'settings.json'

$settings = [ordered]@{}
if (Test-Path -LiteralPath $settingsFile) {
    try {
        $existing = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $settings[$p.Name] = $p.Value }
    } catch { }
}
if ($configuredTool) { $settings['ToolDir'] = $configuredTool }
if (-not $settings.Contains('OutDir'))    { $settings['OutDir']    = $InstallDir }
if (-not $settings.Contains('ExportDir')) { $settings['ExportDir'] = (Join-Path $InstallDir 'exported-solutions') }
try {
    [pscustomobject]$settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    if ($configuredTool) { Good "configured the tool folder: $configuredTool" }
    else { Say "wrote default settings" }
} catch { Note "could not write settings.json: $($_.Exception.Message)" }

Write-Host ""
Good "Installed."
Write-Host ""

if (-not (Test-Path -LiteralPath $toolDir)) {
    Note "One thing left to do:"
    Note "Microsoft's PackageDeployertool folder is not redistributed with this app."
    Note "Copy it into:  $InstallDir"
    Note "Get it from the Microsoft.CrmSdk.XrmTooling.PackageDeployment.WPF NuGet package."
    Write-Host ""
}

foreach ($e in @('pac','dotnet')) {
    if (Get-Command $e -ErrorAction SilentlyContinue) { Good "$e found on PATH" }
    else { Note "$e is not on PATH - the Solutions and Create Package pages need it" }
}

Write-Host ""
Say "Launch it from the Start Menu, or run: $target"
Write-Host ""

if (Confirm-Box "Installation finished.`r`n`r`nStart $AppName now?" $AppName) {
    Start-Process -FilePath $target -WorkingDirectory $InstallDir
}
