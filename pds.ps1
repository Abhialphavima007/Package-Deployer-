#!/usr/bin/env pwsh
#requires -Version 7.0
<#
    Package Deployer Studio - cross-platform companion
    macOS, Linux and Windows. PowerShell 7.

    The Windows desktop app (PackageDeployerStudio.ps1) is WPF, which does not
    exist outside Windows. This is the same workflow as a terminal program.

    What runs where, per Microsoft's own CLI docs:

      pac auth / env / solution      all platforms
      pac package init/add-solution  all platforms
      pac package deploy             WINDOWS ONLY
      pac package show               WINDOWS ONLY
      PackageDeployer.exe            WINDOWS ONLY (a WPF application)

    So on macOS this deploys a package by unpacking it and importing each
    solution in the order its ImportConfig.xml declares. See the warnings in
    Invoke-DeployPortable for exactly what that does and does not cover.

    Usage:
      pwsh ./pds.ps1              interactive menu
      pwsh ./pds.ps1 doctor       check the toolchain
      pwsh ./pds.ps1 envs         list environments
      pwsh ./pds.ps1 solutions    list solutions in the selected environment
      pwsh ./pds.ps1 deploy       deploy a package

    MIT licensed.
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$Command = '')

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.3.3'

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
$script:Plat = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }
$script:NativeDeploy = [bool]$IsWindows        # pac package deploy is Windows-only
$script:UserHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$script:StateDir = Join-Path $script:UserHome '.pdstudio'
$script:Settings = Join-Path $script:StateDir 'cli-settings.json'
$script:LogDir   = Join-Path $script:StateDir 'logs'
foreach ($d in @($script:StateDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function W    { param([string]$t = '', [string]$c = 'Gray') Write-Host $t -ForegroundColor $c }
function Ok   { param([string]$t) Write-Host "  ok    " -ForegroundColor Green -NoNewline; Write-Host $t }
function Bad  { param([string]$t) Write-Host "  fail  " -ForegroundColor Red   -NoNewline; Write-Host $t -ForegroundColor Red }
function Warn { param([string]$t) Write-Host "  warn  " -ForegroundColor Yellow -NoNewline; Write-Host $t -ForegroundColor Yellow }
function Info { param([string]$t) Write-Host "        $t" }
function Dim  { param([string]$t) Write-Host "        $t" -ForegroundColor DarkGray }

function Head {
    param([string]$t)
    W ''
    W ("  " + $t) Cyan
    W ("  " + ('-' * [Math]::Max(10, $t.Length))) DarkGray
}

function Banner {
    Clear-Host
    W ''
    W "   Package Deployer Studio" Cyan
    W "   companion v$script:AppVersion  -  $script:Plat" DarkGray
    if (-not $script:NativeDeploy) {
        W "   pac package deploy is Windows-only; portable deploy is used here." DarkYellow
    }
    W ''
}

function Ask {
    param([string]$Prompt, [string]$Default = '')
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $a = Read-Host "  $Prompt$suffix"
    if (-not $a -and $Default) { return $Default }
    return $a.Trim()
}

function AskYesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $d = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = (Read-Host "  $Prompt [$d]").Trim().ToLower()
        if (-not $a) { return $DefaultYes }
        if ($a -in @('y','yes')) { return $true }
        if ($a -in @('n','no'))  { return $false }
    }
}

function Pause-Key { W ''; Read-Host "  press Enter to continue" | Out-Null }

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
function Get-Cfg {
    if (-not (Test-Path -LiteralPath $script:Settings)) { return @{} }
    try {
        $o = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}

function Set-Cfg {
    param([hashtable]$Values)
    $h = Get-Cfg
    foreach ($k in $Values.Keys) { $h[$k] = $Values[$k] }
    try { [pscustomobject]$h | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Settings -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------------------
# PAC CLI
# ---------------------------------------------------------------------------
function Resolve-Pac {
    $c = Get-Command 'pac' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $probe = @(
        (Join-Path $script:UserHome '.dotnet/tools/pac'),
        (Join-Path $script:UserHome '.dotnet/tools/pac.exe'),
        '/usr/local/share/dotnet/tools/pac',
        (Join-Path $script:UserHome '.local/share/dotnet/tools/pac')
    )
    foreach ($p in $probe) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Show-PacMissing {
    Bad "The Power Platform CLI (pac) was not found."
    W ''
    Info "Install it with the .NET tool, which works on macOS, Linux and Windows:"
    Dim  "  dotnet tool install --global Microsoft.PowerApps.CLI.Tool"
    W ''
    Info "Then make sure the tools folder is on PATH. On macOS add this to ~/.zshrc:"
    Dim  '  export PATH="$PATH:$HOME/.dotnet/tools"'
    W ''
    Info "No .NET SDK yet?  brew install --cask dotnet-sdk"
}

function Invoke-Pac {
    <#
      Runs pac and returns @{ Code; Text }. The call operator quotes arguments
      correctly on its own; $ErrorActionPreference is forced to Continue because
      a native command writing to stderr becomes terminating under 'Stop'.
    #>
    param([string[]]$Arguments, [switch]$Quiet, [string]$WorkDir)

    $exe = Resolve-Pac
    if (-not $exe) { Show-PacMissing; return @{ Code = 9009; Text = '' } }

    if (-not $Quiet) { Dim ("> pac " + ($Arguments -join ' ')) }

    $prev = Get-Location
    $old  = $ErrorActionPreference
    $code = 9009
    $sb   = [System.Text.StringBuilder]::new()
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $out  = & $exe @Arguments 2>&1
        $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        foreach ($l in @($out)) {
            if ($null -eq $l) { continue }
            $s = if ($l -is [System.Management.Automation.ErrorRecord]) { $l.ToString() } else { [string]$l }
            [void]$sb.AppendLine($s)
            if (-not $Quiet) { foreach ($one in ($s -split "`r?`n")) { if ($one.Trim()) { Info $one.TrimEnd() } } }
        }
    } catch {
        Bad $_.Exception.Message
        $code = 9009
    } finally {
        $ErrorActionPreference = $old
        Set-Location $prev
    }
    return @{ Code = $code; Text = $sb.ToString() }
}

function Invoke-Dotnet {
    param([string[]]$Arguments, [string]$WorkDir)
    $exe = (Get-Command 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $exe) {
        Bad "The .NET SDK (dotnet) was not found."
        Info "macOS:  brew install --cask dotnet-sdk"
        Info "or:     https://dotnet.microsoft.com/download"
        return 9009
    }
    Dim ("> dotnet " + ($Arguments -join ' '))
    $prev = Get-Location
    $old  = $ErrorActionPreference
    $code = 9009
    try {
        if ($WorkDir) { Set-Location -LiteralPath $WorkDir }
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $out = & $exe.Source @Arguments 2>&1
        $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        foreach ($l in @($out)) { if ($l) { Info ([string]$l).TrimEnd() } }
    } catch { Bad $_.Exception.Message; $code = 9009 }
    finally { $ErrorActionPreference = $old; Set-Location $prev }
    return $code
}

# ---------------------------------------------------------------------------
# Sign in and environments
# ---------------------------------------------------------------------------
function Invoke-SignIn {
    Head "Sign in"
    $name = Ask "Name this connection" ((Get-Cfg).AuthName ?? 'DevEnv')
    if (-not $name) { Warn "Cancelled."; return }

    $deviceCode = $false
    if (-not $IsWindows) {
        Info "A browser window will open for sign-in."
        $deviceCode = AskYesNo "No browser here (SSH, container)? Use a device code instead" $false
    }
    $a = @('auth','create','--name',$name)
    if ($deviceCode) { $a += '--deviceCode' }

    Info "Complete the sign-in when prompted, including MFA."
    $r = Invoke-Pac -Arguments $a
    if ($r.Code -ne 0) { Bad "Sign-in failed or was cancelled."; return }
    Ok "Signed in as connection '$name'."
    Set-Cfg @{ AuthName = $name }
    Get-EnvList | Out-Null
}

function Show-Connections {
    Head "Saved connections"
    [void](Invoke-Pac -Arguments @('auth','list'))
}

function Switch-Connection {
    Head "Switch connection"
    [void](Invoke-Pac -Arguments @('auth','list'))
    $n = Ask "Connection name to switch to"
    if (-not $n) { return }
    $r = Invoke-Pac -Arguments @('auth','select','--name',$n)
    if ($r.Code -eq 0) { Ok "Switched to '$n'."; Set-Cfg @{ AuthName = $n } }
}

function Get-EnvList {
    Head "Environments"
    $r = Invoke-Pac -Arguments @('env','list') -Quiet
    if ($r.Code -ne 0) {
        Bad "Could not list environments. Sign in first."
        foreach ($l in ($r.Text -split "`r?`n")) { if ($l.Trim()) { Info $l } }
        return @()
    }
    $rows = @()
    foreach ($line in ($r.Text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $m = [regex]::Match($line, 'https://[^\s]+')
        if (-not $m.Success) { continue }
        $url  = $m.Value.TrimEnd('/')
        $head = $line.Substring(0, $m.Index)
        $name = ($head -replace '^\s*\[\d+\]\s*','' -replace '^\s*\*\s*','').Trim()
        if (-not $name) { $name = $url }
        $rows += [pscustomobject]@{ Name = $name; Url = $url }
    }
    if ($rows.Count -eq 0) {
        Warn "No environments parsed. Raw output:"
        foreach ($l in ($r.Text -split "`r?`n")) { if ($l.Trim()) { Info $l } }
        return @()
    }
    $i = 0
    foreach ($e in $rows) { $i++; W ("   {0,2}. {1,-42} {2}" -f $i, $e.Name, $e.Url) }
    return $rows
}

function Select-Env {
    $rows = Get-EnvList
    if ($rows.Count -eq 0) { return }
    W ''
    $n = Ask "Number of the environment to use"
    if (-not ($n -as [int])) { return }
    $idx = [int]$n - 1
    if ($idx -lt 0 -or $idx -ge $rows.Count) { Bad "Out of range."; return }
    $e = $rows[$idx]
    if ($e.Url -notmatch '^https://') { Bad "That does not look like a valid environment URL."; return }

    $r = Invoke-Pac -Arguments @('env','select','--environment',$e.Url)
    if ($r.Code -ne 0) { Bad "Could not select that environment."; return }
    Ok "Target is now $($e.Name)"
    Set-Cfg @{ EnvName = $e.Name; EnvUrl = $e.Url }
}

function Show-WhoAmI {
    Head "Current target"
    $r = Invoke-Pac -Arguments @('env','who')
    if ($r.Code -ne 0) { Bad "Not connected to an environment." }
}

function Get-CurrentEnvName {
    $c = Get-Cfg
    if ($c.EnvName) { return [string]$c.EnvName }
    return '(none selected)'
}

# ---------------------------------------------------------------------------
# Solutions
# ---------------------------------------------------------------------------
function Get-Prop {
    param($Obj, [string[]]$Names, $Default = '')
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)".Trim()) { return "$($p.Value)".Trim() }
    }
    return $Default
}

function Get-SolutionList {
    param([switch]$IncludeSystem)
    Head "Solutions in $(Get-CurrentEnvName)"
    $a = @('solution','list','--json')
    if ($IncludeSystem) { $a += '--includeSystemSolutions' }
    $r = Invoke-Pac -Arguments $a -Quiet
    if ($r.Code -ne 0) {
        Bad "Could not list solutions. Select an environment first."
        foreach ($l in ($r.Text -split "`r?`n")) { if ($l.Trim()) { Info $l } }
        return @()
    }
    $i = $r.Text.IndexOfAny([char[]]@('[','{'))
    if ($i -lt 0) { Bad "No JSON in the response."; return @() }
    try { $data = $r.Text.Substring($i) | ConvertFrom-Json } catch { Bad "Could not parse the solution list."; return @() }

    $rows = @()
    foreach ($s in @($data)) {
        $u = Get-Prop $s @('SolutionUniqueName','UniqueName','uniquename','solutionuniquename','Name')
        if (-not $u) { continue }
        $m = Get-Prop $s @('IsManaged','Managed','ismanaged','isManaged')
        $rows += [pscustomobject]@{
            UniqueName = $u
            Friendly   = Get-Prop $s @('FriendlyName','friendlyname','DisplayName','displayname') $u
            Version    = Get-Prop $s @('VersionNumber','Version','version')
            Managed    = if ($m -match '^(true|1|yes)$') { 'yes' } elseif ($m) { 'no' } else { '' }
        }
    }
    $rows = @($rows | Sort-Object Friendly)
    $n = 0
    foreach ($s in $rows) {
        $n++
        W ("   {0,3}. {1,-34} {2,-28} {3,-12} {4}" -f $n, $s.Friendly, $s.UniqueName, $s.Version, $s.Managed)
    }
    if ($rows.Count -eq 0) { Info "No solutions returned. Try including system solutions." }
    return $rows
}

function Export-Solutions {
    $rows = Get-SolutionList
    if ($rows.Count -eq 0) { return }
    W ''
    Info "Enter numbers separated by commas, or 'all'."
    $pick = Ask "Solutions to export"
    if (-not $pick) { return }

    $chosen = @()
    if ($pick -eq 'all') { $chosen = $rows }
    else {
        foreach ($tok in ($pick -split ',')) {
            $t = $tok.Trim()
            if ($t -as [int]) {
                $idx = [int]$t - 1
                if ($idx -ge 0 -and $idx -lt $rows.Count) { $chosen += $rows[$idx] }
            }
        }
    }
    if ($chosen.Count -eq 0) { Bad "Nothing selected."; return }

    $cfg = Get-Cfg
    $dir = Ask "Export folder" ($cfg.ExportDir ?? (Join-Path (Get-Location) 'exported-solutions'))
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Cfg @{ ExportDir = $dir }

    $managed   = AskYesNo "Export managed" $true
    $unmanaged = AskYesNo "Also export unmanaged" $false
    $kinds = @()
    if ($managed)   { $kinds += $true }
    if ($unmanaged) { $kinds += $false }
    if ($kinds.Count -eq 0) { Bad "Pick managed, unmanaged, or both."; return }

    $done = 0; $failed = 0; $total = $chosen.Count * $kinds.Count; $n = 0
    foreach ($s in $chosen) {
        foreach ($k in $kinds) {
            $n++
            $suffix = if ($k) { '_managed' } else { '_unmanaged' }
            $file   = Join-Path $dir ($s.UniqueName + $suffix + '.zip')
            Head ("[$n/$total] exporting $($s.UniqueName)" + $(if ($k) { ' (managed)' } else { ' (unmanaged)' }))
            $a = @('solution','export','--path',$file,'--name',$s.UniqueName,'--overwrite')
            if ($k) { $a += '--managed' }          # --managed is a switch, not a value
            $r = Invoke-Pac -Arguments $a
            if ($r.Code -eq 0 -and (Test-Path -LiteralPath $file)) {
                Ok ("{0}  ({1} MB)" -f (Split-Path -Leaf $file), [math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 2))
                $done++
            } else { Bad "export failed: $($s.UniqueName)"; $failed++ }
        }
    }
    W ''
    if ($failed) { Warn "$done exported, $failed failed." } else { Ok "$done file(s) exported to $dir" }
}

function Import-SolutionZip {
    param([string]$Path)
    Head "Import a solution"
    if (-not $Path) { $Path = Ask "Path to the solution .zip" }
    $Path = $Path.Trim().Trim('"').Trim("'")
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Bad "File not found."; return $false }

    W ''
    Info "Target: $(Get-CurrentEnvName)"
    if (-not (AskYesNo "Import $(Split-Path -Leaf $Path) into that environment" $false)) { Warn "Cancelled."; return $false }

    $a = @('solution','import','--path',$Path)
    if (AskYesNo "Publish changes after import" $true)   { $a += '--publish-changes' }
    if (AskYesNo "Activate plug-ins and workflows" $true) { $a += '--activate-plugins' }
    if (AskYesNo "Force overwrite unmanaged customizations" $false) { $a += '--force-overwrite' }

    Info "This can take a long time for large solutions."
    $r = Invoke-Pac -Arguments $a
    if ($r.Code -eq 0) { Ok "Imported."; return $true }
    Bad "Import failed."
    return $false
}

# ---------------------------------------------------------------------------
# Create a package
# ---------------------------------------------------------------------------
function New-Package {
    Head "Create a package"
    $cfg  = Get-Cfg
    $name = Ask "Package name" ($cfg.PkgName ?? 'DeploymentPackage')
    if ($name -match '[\\/:*?"<>|\s]') { Bad "No spaces or \ / : * ? < > | in the name."; return }
    $out  = Ask "Output folder" ($cfg.OutDir ?? (Get-Location).Path)
    if (-not (Test-Path -LiteralPath $out)) { Bad "That folder does not exist."; return }
    Set-Cfg @{ PkgName = $name; OutDir = $out }

    $dir = Ask "Folder containing the solution zips" ($cfg.ExportDir ?? $out)
    if (-not (Test-Path -LiteralPath $dir)) { Bad "That folder does not exist."; return }
    $zips = @(Get-ChildItem -LiteralPath $dir -Filter *.zip -File | Sort-Object Name)
    if ($zips.Count -eq 0) { Bad "No .zip files there."; return }

    W ''
    $i = 0
    foreach ($z in $zips) { $i++; W ("   {0,2}. {1}" -f $i, $z.Name) }
    W ''
    Info "Import order runs in the order you list them."
    $pick = Ask "Solutions to include (comma separated, or 'all')"
    $chosen = @()
    if ($pick -eq 'all') { $chosen = $zips | ForEach-Object { $_.FullName } }
    else {
        foreach ($tok in ($pick -split ',')) {
            $t = $tok.Trim()
            if ($t -as [int]) {
                $idx = [int]$t - 1
                if ($idx -ge 0 -and $idx -lt $zips.Count) { $chosen += $zips[$idx].FullName }
            }
        }
    }
    if ($chosen.Count -eq 0) { Bad "Nothing selected."; return }

    $proj = Join-Path $out $name
    if (Test-Path -LiteralPath $proj) {
        if (-not (AskYesNo "'$proj' exists. Delete it and start fresh" $false)) { Warn "Cancelled."; return }
        Remove-Item -LiteralPath $proj -Recurse -Force
    }

    $steps = $chosen.Count + 2
    Head "[1/$steps] pac package init"
    if ((Invoke-Pac -Arguments @('package','init','-o',$name) -WorkDir $out).Code -ne 0) { Bad "init failed."; return }
    if (-not (Test-Path -LiteralPath $proj)) { Bad "Project folder was not created."; return }

    $n = 1
    foreach ($z in $chosen) {
        $n++
        Head ("[$n/$steps] adding " + (Split-Path -Leaf $z))
        if ((Invoke-Pac -Arguments @('package','add-solution','-p',$z) -WorkDir $proj).Code -ne 0) {
            Bad "add-solution failed for $z"; return
        }
    }

    Head "[$steps/$steps] dotnet publish"
    if ((Invoke-Dotnet -Arguments @('publish') -WorkDir $proj) -ne 0) { Bad "publish failed."; return }

    $zip = @(Get-ChildItem -LiteralPath $proj -Recurse -File -Filter '*.pdpkg.zip' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    W ''
    if ($zip.Count -gt 0) {
        Ok "Package built: $($zip[0].FullName)"
        Set-Cfg @{ LastPackage = $zip[0].FullName }
    } else {
        Ok "Publish finished. Look under $proj for the output."
    }
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
function Expand-Package {
    <# Returns the folder holding ImportConfig.xml, extracting the zip if needed. #>
    param([string]$Path)
    $work = $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([IO.Path]::GetExtension($Path) -ne '.zip') { Bad "Expected a folder or a .zip."; return $null }
        $work = Join-Path ([IO.Path]::GetTempPath()) ('pds_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Info "Extracting $(Split-Path -Leaf $Path) ..."
        $extracted = $false
        try {
            # Entry-by-entry so each destination can be checked before writing.
            $zf = [IO.Compression.ZipFile]::OpenRead($Path)
            try {
                $root = [IO.Path]::GetFullPath($work).TrimEnd([IO.Path]::DirectorySeparatorChar) +
                        [IO.Path]::DirectorySeparatorChar
                foreach ($e in $zf.Entries) {
                    if (-not $e.Name) { continue }                       # directory entry
                    $full = [IO.Path]::GetFullPath((Join-Path $work $e.FullName))
                    if (-not $full.StartsWith($root)) {                  # zip-slip guard
                        Warn "blocked unsafe zip entry: $($e.FullName)"
                        continue
                    }
                    $d = Split-Path -Parent $full
                    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $full, $true)
                }
            } finally { $zf.Dispose() }
            $extracted = $true
        } catch {
            Dim "  entry-by-entry extract unavailable ($($_.Exception.Message)); using Expand-Archive"
        }
        if (-not $extracted) {
            try { Expand-Archive -LiteralPath $Path -DestinationPath $work -Force }
            catch { Bad "Extract failed: $($_.Exception.Message)"; return $null }
        }
    }
    $cfg = @(Get-ChildItem -LiteralPath $work -Recurse -File -Filter 'ImportConfig.xml' -ErrorAction SilentlyContinue |
             Select-Object -First 1)
    if ($cfg.Count -eq 0) { Bad "No ImportConfig.xml found inside that package."; return $null }
    return $cfg[0].Directory.FullName
}

function Invoke-DeployPortable {
    <#
      The macOS / Linux deploy path.

      pac package deploy does not exist off Windows, so this reads the
      package's ImportConfig.xml and imports each solution in the declared
      order with pac solution import, honouring the per-solution flags the
      package author set.

      What this does NOT do, and the user is told so up front:
        - run the package's own C# ImportExtension code (pre/post steps)
        - import configuration data files the package ships
        - apply runtime package settings
      For a package that only ships solutions, this is equivalent.
    #>
    param([string]$PackagePath)

    $assets = Expand-Package -Path $PackagePath
    if (-not $assets) { return }

    $cfgFile = Join-Path $assets 'ImportConfig.xml'
    try { $x = [xml](Get-Content -LiteralPath $cfgFile -Raw) } catch { Bad "ImportConfig.xml is not valid XML."; return }

    $sols = @($x.SelectNodes('//configsolutionfile'))
    if ($sols.Count -eq 0) { Bad "ImportConfig.xml lists no solutions."; return }

    # Warn about the parts a solution-by-solution import cannot reproduce.
    $caveats = @()
    if (@($x.SelectNodes('//filestoimport/*')).Count -gt 0)    { $caveats += 'configuration data files' }
    if (@($x.SelectNodes('//configimportdata/*')).Count -gt 0) { $caveats += 'data import steps' }
    $dll = @(Get-ChildItem -LiteralPath (Split-Path -Parent $assets) -Filter *.dll -File -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -notmatch '^(Microsoft|System|Azure|Newtonsoft|netstandard)' })
    if ($dll.Count -gt 0) { $caveats += "custom package code ($($dll[0].Name))" }

    Head "Portable deploy"
    Info "Target      : $(Get-CurrentEnvName)"
    Info "Package     : $PackagePath"
    Info "Solutions   : $($sols.Count), in the order ImportConfig.xml declares"
    W ''
    Warn "pac package deploy is Windows-only, so this imports each solution directly."
    if ($caveats.Count -gt 0) {
        Warn "This package also contains: $($caveats -join ', ')."
        Warn "Those are NOT applied here. Deploy on Windows if you need them."
    }
    W ''

    $plan = @()
    $i = 0
    foreach ($s in $sols) {
        $name = $s.GetAttribute('solutionpackagefilename')
        if (-not $name) { continue }
        $p = Join-Path $assets $name
        $i++
        $plan += [pscustomobject]@{
            Order    = $i
            File     = $name
            Path     = $p
            Exists   = (Test-Path -LiteralPath $p)
            Force    = ($s.GetAttribute('overwriteunmanagedcustomizations') -match '^(true|1)$')
            Activate = ($s.GetAttribute('publishworkflowsandactivateplugins') -match '^(true|1)$')
        }
    }
    foreach ($p in $plan) {
        $flags = @()
        if ($p.Force)    { $flags += 'force-overwrite' }
        if ($p.Activate) { $flags += 'activate-plugins' }
        $mark = if ($p.Exists) { ' ' } else { '!' }
        W ("   {0}{1,2}. {2,-46} {3}" -f $mark, $p.Order, $p.File, ($flags -join ', '))
    }
    if (@($plan | Where-Object { -not $_.Exists }).Count -gt 0) {
        W ''
        Bad "Lines marked ! are missing from the package. Aborting."
        return
    }

    W ''
    if (-not (AskYesNo "Import these $($plan.Count) solution(s) into $(Get-CurrentEnvName)" $false)) { Warn "Cancelled."; return }

    $log = Join-Path $script:LogDir ('deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $okCount = 0
    foreach ($p in $plan) {
        Head ("[$($p.Order)/$($plan.Count)] importing $($p.File)")
        $a = @('solution','import','--path',$p.Path,'--publish-changes')
        if ($p.Activate) { $a += '--activate-plugins' }
        if ($p.Force)    { $a += '--force-overwrite' }
        $r = Invoke-Pac -Arguments $a
        Add-Content -LiteralPath $log -Value ("[{0}] {1} -> exit {2}" -f (Get-Date -Format 's'), $p.File, $r.Code)
        Add-Content -LiteralPath $log -Value $r.Text
        if ($r.Code -ne 0) {
            Bad "Import failed on $($p.File). Stopping - later solutions may depend on this one."
            Info "Log: $log"
            return
        }
        Ok "$($p.File) imported."
        $okCount++
    }
    W ''
    Ok "All $okCount solution(s) imported into $(Get-CurrentEnvName)."
    Info "Log: $log"
    W ''
    Info "Post-deploy, as with any package: bind connection references, fill"
    Info "environment variables, and turn cloud flows on."
}

function Invoke-DeployNative {
    param([string]$PackagePath)
    Head "Deploy with pac package deploy"
    Info "Target : $(Get-CurrentEnvName)"
    Info "Package: $PackagePath"
    W ''
    if (-not (AskYesNo "Deploy now" $false)) { Warn "Cancelled."; return }
    $log = Join-Path $script:LogDir ('deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Info "Large packages take 45-120 minutes."
    $r = Invoke-Pac -Arguments @('package','deploy','--package',$PackagePath,'--logFile',$log)
    if ($r.Code -eq 0) { Ok "Deployment succeeded." } else { Bad "Deployment failed. Log: $log" }
}

function Invoke-Deploy {
    $cfg  = Get-Cfg
    $path = Ask "Package (.pdpkg.zip or the folder holding it)" ($cfg.LastPackage ?? '')
    $path = $path.Trim().Trim('"').Trim("'")
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { Bad "Not found."; return }
    Set-Cfg @{ LastPackage = $path }

    if ((Get-Cfg).EnvUrl) { } else { Bad "Select an environment first."; return }

    if ($script:NativeDeploy) {
        W ''
        Info "You are on Windows, so both routes are available."
        Info "  1. pac package deploy   - full fidelity, runs the package's own code"
        Info "  2. portable import      - solution by solution, same as macOS uses"
        $c = Ask "Which" '1'
        if ($c -eq '2') { Invoke-DeployPortable -PackagePath $path } else { Invoke-DeployNative -PackagePath $path }
    } else {
        Invoke-DeployPortable -PackagePath $path
    }
}

function New-WindowsWorkflow {
    <# For packages that need real pac package deploy, from a Mac. #>
    Head "Generate a Windows deploy pipeline"
    Info "pac package deploy needs Windows. This writes a GitHub Actions workflow"
    Info "that runs it on a windows-latest runner, so you can deploy from a Mac."
    W ''
    $out = Ask "Write to" (Join-Path (Get-Location) '.github/workflows/deploy-package.yml')
    $dir = Split-Path -Parent $out
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $yml = @'
name: Deploy package

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target environment URL
        required: true
      package:
        description: Path to the .pdpkg.zip in this repo
        required: true
        default: dist/DeploymentPackage.1.0.0.pdpkg.zip

jobs:
  deploy:
    # pac package deploy is Windows-only, so this must be a Windows runner.
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install the PAC CLI
        run: dotnet tool install --global Microsoft.PowerApps.CLI.Tool

      - name: Authenticate
        env:
          APP_ID:   ${{ secrets.PP_APP_ID }}
          SECRET:   ${{ secrets.PP_CLIENT_SECRET }}
          TENANT:   ${{ secrets.PP_TENANT_ID }}
        run: >
          pac auth create
          --applicationId "$env:APP_ID"
          --clientSecret "$env:SECRET"
          --tenant "$env:TENANT"
          --environment "${{ github.event.inputs.environment }}"

      - name: Deploy
        run: pac package deploy --package "${{ github.event.inputs.package }}" --logFile deploy.log

      - name: Keep the log
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: deploy-log
          path: deploy.log
'@
    Set-Content -LiteralPath $out -Value $yml -Encoding UTF8
    Ok "Written: $out"
    W ''
    Info "Add these repository secrets: PP_APP_ID, PP_CLIENT_SECRET, PP_TENANT_ID"
    Info "(an app registration with the System Administrator role on the target)."
}

# ---------------------------------------------------------------------------
# Doctor
# ---------------------------------------------------------------------------
function Invoke-Doctor {
    Head "Toolchain check"
    Info ("Platform        : {0}" -f $script:Plat)
    Info ("PowerShell      : {0}" -f $PSVersionTable.PSVersion)
    Info ("Settings        : {0}" -f $script:Settings)
    W ''

    $pac = Resolve-Pac
    if ($pac) {
        Ok "pac found: $pac"
        [void](Invoke-Pac -Arguments @('--version'))
    } else { Show-PacMissing }

    W ''
    $dn = Get-Command 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dn) { Ok "dotnet found: $($dn.Source)" }
    else { Warn "dotnet not found - needed only to build packages." }

    W ''
    if ($script:NativeDeploy) {
        Ok "pac package deploy is available on this platform."
    } else {
        Warn "pac package deploy is Windows-only - this platform uses the portable import."
        Info "Microsoft lists pac data, pac package deploy and pac package show as Windows-only."
    }

    $c = Get-Cfg
    W ''
    Info ("Connection      : {0}" -f ($c.AuthName ?? '(none)'))
    Info ("Environment     : {0}" -f ($c.EnvName  ?? '(none)'))
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
function Show-Menu {
    while ($true) {
        Banner
        W "   Connection : $((Get-Cfg).AuthName ?? '(not signed in)')" DarkGray
        W "   Environment: $(Get-CurrentEnvName)" DarkGray
        W ''
        W "    1  Sign in"
        W "    2  Saved connections"
        W "    3  Switch connection"
        W ''
        W "    4  List environments"
        W "    5  Select environment"
        W "    6  Who am I"
        W ''
        W "    7  List solutions"
        W "    8  Export solutions"
        W "    9  Import a solution"
        W ''
        W "   10  Create a package"
        W "   11  Deploy a package"
        W "   12  Generate a Windows deploy pipeline"
        W ''
        W "   13  Toolchain check"
        W "    q  Quit"
        W ''
        $c = (Read-Host "  choose").Trim().ToLower()
        try {
            switch ($c) {
                '1'  { Invoke-SignIn;            Pause-Key }
                '2'  { Show-Connections;         Pause-Key }
                '3'  { Switch-Connection;        Pause-Key }
                '4'  { [void](Get-EnvList);      Pause-Key }
                '5'  { Select-Env;               Pause-Key }
                '6'  { Show-WhoAmI;              Pause-Key }
                '7'  { [void](Get-SolutionList); Pause-Key }
                '8'  { Export-Solutions;         Pause-Key }
                '9'  { [void](Import-SolutionZip); Pause-Key }
                '10' { New-Package;              Pause-Key }
                '11' { Invoke-Deploy;            Pause-Key }
                '12' { New-WindowsWorkflow;      Pause-Key }
                '13' { Invoke-Doctor;            Pause-Key }
                'q'  { W ''; return }
                default { }
            }
        } catch {
            W ''
            Bad $_.Exception.Message
            Dim ("   at line {0}" -f $_.InvocationInfo.ScriptLineNumber)
            Pause-Key
        }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
switch ($Command.ToLower()) {
    ''           { Show-Menu }
    'menu'       { Show-Menu }
    'doctor'     { Banner; Invoke-Doctor; W '' }
    'signin'     { Banner; Invoke-SignIn }
    'envs'       { Banner; [void](Get-EnvList); W '' }
    'solutions'  { Banner; [void](Get-SolutionList); W '' }
    'export'     { Banner; Export-Solutions }
    'import'     { Banner; [void](Import-SolutionZip) }
    'package'    { Banner; New-Package }
    'deploy'     { Banner; Invoke-Deploy }
    'pipeline'   { Banner; New-WindowsWorkflow }
    default {
        Banner
        Bad "Unknown command '$Command'."
        Info "Try: doctor, signin, envs, solutions, export, import, package, deploy, pipeline"
        W ''
    }
}
