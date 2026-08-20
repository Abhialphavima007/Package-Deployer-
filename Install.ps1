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
    [switch]$WithTool,         # install the Package Deployer tool without asking
    [switch]$NoTool,           # never ask about the Package Deployer tool
    [string]$ToolPath = '',    # a folder you already have that holds PackageDeployer.exe
    [string]$ToolInstallDir = '',   # where to put it; a PackageDeployertool folder is created inside
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

function Select-FolderModern {
    <#
      The Explorer folder picker, not the old tree control: an OpenFileDialog
      with name validation off shows the modern dialog, and we take the folder
      it lands in. The caller asks for a PARENT folder and creates its own
      subfolder inside, so there is never a need to invent a new folder here.
    #>
    param([string]$Description, [string]$Start)
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch { return $null }
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title           = "$Description  -  open the folder, then click Select"
    $d.ValidateNames   = $false
    $d.CheckFileExists = $false
    $d.CheckPathExists = $true
    $d.Multiselect     = $false
    $d.Filter          = 'Folders|*.this-never-matches'
    $d.FileName        = 'Select this folder'
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.InitialDirectory = $Start }
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $p = Split-Path -Parent $d.FileName
    if (Test-Path -LiteralPath $d.FileName -PathType Container) { $p = $d.FileName }
    return $p
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

function Get-PackageDeployerTool {
    <#
      Fetch Microsoft's Package Deployer tool from their own NuGet feed.

      Far better than asking someone who has just downloaded this app to go and
      find a PackageDeployer.exe they have never heard of. The package is a zip;
      we pull the newest stable version and look for the exe wherever it sits,
      rather than assuming a folder layout.
    #>
    param([string]$Dest)

    $id   = 'microsoft.crmsdk.xrmtooling.packagedeployment.wpf'
    $base = "https://api.nuget.org/v3-flatcontainer/$id"
    $tmp  = Join-Path $env:TEMP ("pdtool_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'      # the built-in bar makes this crawl

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        Say "asking nuget.org for the current version ..."
        $idx = Invoke-RestMethod -Uri "$base/index.json" -TimeoutSec 60 -UseBasicParsing
        $ver = $idx.versions |
               Where-Object { $_ -notmatch '-' } |
               Sort-Object { try { [version]$_ } catch { [version]'0.0' } } |
               Select-Object -Last 1
        if (-not $ver) { Bad "No stable version listed on nuget.org."; return $null }

        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp "tool.zip"          # .nupkg is a zip; Expand-Archive wants the extension
        Say "downloading version $ver - about 30 MB, this takes a minute ..."
        Invoke-WebRequest -Uri "$base/$ver/$id.$ver.nupkg" -OutFile $zip -TimeoutSec 900 -UseBasicParsing

        Say "extracting ..."
        $ex = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force

        $exe = Get-ChildItem -LiteralPath $ex -Recurse -File -Filter 'PackageDeployer.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if (-not $exe) { Bad "PackageDeployer.exe was not inside that package."; return $null }

        if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
        Copy-Item -Path (Join-Path $exe.Directory.FullName '*') -Destination $Dest -Recurse -Force
        if (Test-ToolFolder $Dest) { return $Dest }
        Bad "Copied the files but PackageDeployer.exe is not where expected."
        return $null
    } catch {
        Bad "Download failed: $($_.Exception.Message)"
        info "You can add the tool later from the Deploy page - nothing else is affected."
        return $null
    } finally {
        $ProgressPreference = $oldProgress
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$configuredTool = $null

if ($ToolPath) {
    if (Test-ToolFolder $ToolPath) { $configuredTool = $ToolPath; Good "using the tool folder you specified: $ToolPath" }
    else { Bad "-ToolPath does not contain PackageDeployer.exe: $ToolPath" }
}

if (-not $configuredTool -and (Test-ToolFolder $toolDir)) {
    $configuredTool = $toolDir
    Good "Package Deployer tool already present"
}

if (-not $configuredTool) {
    # Look around quietly first. Most people never see a prompt at all.
    $found = Find-ExistingTool
    if ($found) {
        if ((Get-FullPathSafe $found) -like ((Get-FullPathSafe $Source) + '*')) {
            Say "copying the Package Deployer tool (this takes a moment) ..."
            Copy-Item -LiteralPath $found -Destination $toolDir -Recurse -Force
            $configuredTool = $toolDir
            Good "copied the Package Deployer tool into the install folder"
        } else {
            $configuredTool = $found
            Good "found the Package Deployer tool already on this machine: $found"
        }
    }
}

if (-not $configuredTool -and -not $NoTool) {
    # Never a "go and find PackageDeployer.exe" file picker - someone installing
    # this for the first time has no idea what that is. Install it for them,
    # into a folder they choose.
    $want = $WithTool
    if (-not $want) {
        $want = Confirm-Box @"
Install Microsoft's Package Deployer tool now?

$AppName drives Microsoft's Package Deployer tool. Microsoft does not permit it
to be bundled here, so it is downloaded from their official NuGet feed - about
30 MB. You will be asked where to put it.

Yes  - install it and configure the path automatically (recommended)
No   - skip it for now; you can add it later from the Deploy page

Skipping is fine: signing in, browsing environments, exporting and importing
solutions, building packages and deploying with the Power Platform CLI all
work without it.
"@ "$AppName - Package Deployer tool"
    }

    if ($want) {
        # Ask for a PARENT folder and create PackageDeployertool inside it, so
        # the destination is predictable and no new folder has to be invented
        # in the dialog.
        $parent = $ToolInstallDir
        if (-not $parent) {
            Write-Host ""
            Say "Choose where to install it - a 'PackageDeployertool' folder is created inside."
            Say "Default is the app's own folder: $InstallDir"
            $parent = Select-FolderModern "Where should Microsoft's Package Deployer tool go?" $InstallDir
            if (-not $parent) {
                $parent = $InstallDir
                Note "no folder chosen - using the app folder"
            }
        }
        if (-not (Test-Path -LiteralPath $parent)) {
            try { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            catch { Bad "Cannot create $parent - using the app folder instead"; $parent = $InstallDir }
        }

        $dest = if ((Split-Path -Leaf $parent) -ieq 'PackageDeployertool') { $parent }
                else { Join-Path $parent 'PackageDeployertool' }

        Write-Host ""
        Say "Installing to $dest"
        $configuredTool = Get-PackageDeployerTool -Dest $dest
        if ($configuredTool) {
            Good "Package Deployer tool installed"
            Good "path configured for the app: $configuredTool"
        } else {
            Note "Add it later from the Deploy page - nothing else is affected."
        }
    } else {
        Say "skipped the Package Deployer tool"
    }
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
Write-Host "  ---------------------------------------------" -ForegroundColor DarkGray
Good "Installed to $InstallDir"
Write-Host ""
Write-Host "  What you can do now" -ForegroundColor Cyan

$hasPac    = [bool](Get-Command 'pac'    -ErrorAction SilentlyContinue)
$hasDotnet = [bool](Get-Command 'dotnet' -ErrorAction SilentlyContinue)

if ($hasPac) {
    Good "Sign in, browse environments, export and import solutions"
    Good "Deploy a package with the Power Platform CLI"
} else {
    Note "Sign in / solutions / CLI deploy need the Power Platform CLI:"
    Note "    dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
}
if ($hasDotnet) { Good "Build packages (pac package init + dotnet publish)" }
else            { Note "Building packages needs the .NET SDK: https://dotnet.microsoft.com/download" }

if ($configuredTool) {
    Good "Drive the Package Deployer GUI tool (Clean / Load / Verify / Launch)"
    Say  "    tool folder: $configuredTool"
} else {
    Note "The Package Deployer GUI steps are not set up yet - entirely optional."
    Note "Add the tool any time: Deploy page, then Browse next to 'Tool folder',"
    Note "or run this installer again and answer Yes to the download."
}

Write-Host ""
Say "Start it from the Start Menu, the desktop shortcut, or:"
Say "  $target"
Write-Host ""

if (Confirm-Box "Installation finished.`r`n`r`nStart $AppName now?" $AppName) {
    Start-Process -FilePath $target -WorkingDirectory $InstallDir
}
