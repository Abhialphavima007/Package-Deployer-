# Package Deployer — Developer Runbook

How to deploy **any** Package Deployer package to **any** Dataverse environment
using the tool in `.\PackageDeployertool`.

This folder ships **empty of package content on purpose**. Every deployment
uses a different package — you add the package files, deploy, then clean up.

---

## 1. What's in this folder

```
C:\PackageDeployer\
 ├─ HOW-TO-DEPLOY-A-PACKAGE.md   <- this file
 └─ PackageDeployertool\         <- the tool (do not modify)
      ├─ PackageDeployer.exe
      ├─ PackageDeployer.exe.config
      ├─ Microsoft.*.dll  (many)
      └─ <language folders>
```

`PackageDeployertool` contains **only the tool**. No package. That is correct.

---

## 2. What you need from the build team

For every deployment you need **one** of these:

| You were given | Use this method |
|---|---|
| `<Name>.<version>.pdpkg.zip` (a single zip) | **Method A — PAC CLI** (easiest) |
| An unzipped `<Name>.<version>.pdpkg` folder | **Method B — GUI** |
| Both | Either; A is faster, B shows the customer experience |

Inside a `.pdpkg` (zipped or not) you will always find:

```
<Name>.<version>.pdpkg\
 ├─ <PackageName>.dll        <- the package assembly  (e.g. DeploymentPackage.dll)
 ├─ <PackageName>.pdb        <- optional
 ├─ [Content_Types].xml
 └─ PkgAssets\               <- folder name may differ; see note below
      ├─ ImportConfig.xml    <- solution list + import order
      ├─ manifest.ppkg.json
      └─ *.zip               <- the solution files
```

> **Note on the assets folder name:** it is whatever the package's
> `GetImportPackageDataFolderName` returns. PAC CLI packages use `PkgAssets`.
> Older Visual Studio template packages use `PkgFolder`.
> **Copy it with its original name — never rename it.**

---

## 3. Method A — PAC CLI (recommended)

No file copying. Works directly on the `.pdpkg.zip`.

### One-time setup

```powershell
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
pac install latest
```

### Every deployment

```powershell
# 1. authenticate to the target environment (name it so you can switch later)
pac auth create --environment https://TARGET.crm.dynamics.com --name DevEnv

# 2. confirm you are pointed at the right environment
pac auth list
pac org who

# 3. deploy
pac package deploy --package "C:\path\to\YourPackage.1.0.0.pdpkg.zip" --logFile "C:\PackageDeployer\logs\deploy.log"
```

Switching environments later:

```powershell
pac auth create --environment https://UAT.crm.dynamics.com --name UatEnv
pac auth select --name UatEnv
```

---

## 4. Method B — Package Deployer GUI

### Step 1 — Clean out the previous package

**Do this every time, before copying a new package in.** Leftover solution
zips from a previous deployment cause wrong or failed imports.

```powershell
$tool = "C:\PackageDeployer\PackageDeployertool"

Remove-Item "$tool\PkgAssets"  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$tool\PkgFolder"  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$tool\*.pdb"      -Force -ErrorAction SilentlyContinue
Remove-Item "$tool\PackageDeployer.tokens.dat" -Force -ErrorAction SilentlyContinue
```

For the package DLL, delete only the package assembly — **not** the Microsoft
DLLs. Package assemblies do not start with `Microsoft.`, `System.`, `Azure.`,
or `Newtonsoft.`:

```powershell
Get-ChildItem "$tool\*.dll" |
  Where-Object { $_.Name -notmatch '^(Microsoft|System|Azure|Newtonsoft|SolutionPackagerLib)' } |
  Remove-Item -Force
```

### Step 2 — Copy the new package in

```powershell
$tool = "C:\PackageDeployer\PackageDeployertool"
$pkg  = "C:\path\to\YourPackage.1.0.0.pdpkg"   # the UNZIPPED pdpkg folder

Copy-Item "$pkg\PkgAssets" -Destination $tool -Recurse -Force
Copy-Item "$pkg\*.dll"     -Destination $tool -Force
Copy-Item "$pkg\*.pdb"     -Destination $tool -Force -ErrorAction SilentlyContinue
```

Result — the tool folder should now look like:

```
PackageDeployertool\
 ├─ PackageDeployer.exe
 ├─ <PackageName>.dll        <- NEW
 ├─ PkgAssets\               <- NEW
 │    └─ ImportConfig.xml
 └─ Microsoft.*.dll ...
```

### Step 3 — Unblock (MANDATORY)

Windows flags anything that came from a download or email. .NET then refuses
to load the package assembly and the tool reports **"No Import packages
found"** with no further explanation.

```powershell
Get-ChildItem "C:\PackageDeployer" -Recurse -File | Unblock-File
```

> Run this in **PowerShell**, not Command Prompt.
> From cmd: `powershell -Command "Get-ChildItem 'C:\PackageDeployer' -Recurse -File | Unblock-File"`

### Step 4 — Verify before launching

```powershell
$tool = "C:\PackageDeployer\PackageDeployertool"
Test-Path "$tool\PackageDeployer.exe"          # must be True
Test-Path "$tool\PkgAssets\ImportConfig.xml"   # must be True
Get-ChildItem "$tool\*.dll" | Where-Object { $_.Name -notmatch '^(Microsoft|System|Azure|Newtonsoft|SolutionPackagerLib)' }
# ^ must return exactly ONE dll — your package assembly
```

If more than one non-Microsoft DLL is listed, an old package assembly is still
present. Delete it, or the tool will show **"Multiple import packages were
found"** and you may pick the wrong one.

Also sanity-check that `ImportConfig.xml` references files that actually exist:

```powershell
$cfg = "$tool\PkgAssets\ImportConfig.xml"
([xml](Get-Content $cfg)).configdatastorage.solutions.configsolutionfile.solutionpackagefilename |
  ForEach-Object { "{0,-8} {1}" -f (Test-Path "$tool\PkgAssets\$_"), $_ }
```

Every line must start with `True`.

### Step 5 — Run

```
Double-click PackageDeployer.exe
```

1. **Continue**
2. Deployment type → **Microsoft 365** → select **Region** → **Login**
3. Sign in with an account holding **System Administrator** on the target
4. Select the target **environment** → **Login**
5. Select the package → **Next**
6. Review the solution list and order → **Next**
7. **Ready to Import** → **Next**
8. Wait. Large packages take **45–120 minutes**. Do not close the window.
9. **Next** → **Finish**

---

## 5. Pre-flight checklist

- [ ] Correct **target environment** confirmed (`pac org who`, or the org name in the GUI)
- [ ] Account has **System Administrator**
- [ ] Environment **backup / restore point** taken
- [ ] Target is **not** in admin mode blocking imports
- [ ] Installed solution versions on target are **equal or lower** (downgrade is not supported)
- [ ] Required **connectors and licences** exist in the target tenant
- [ ] Machine will not sleep; power connected

---

## 6. Post-deployment checklist

- [ ] Every solution in `ImportConfig.xml` appears under **Solutions** at the expected version
- [ ] Import log contains no `Failure` / `MissingDependency`
- [ ] **Connection references** — bind each to a valid connection
- [ ] **Environment variables** — populate empty values (empty values silently break flows)
- [ ] **Cloud flows turned on** (patch imports frequently deactivate them)
- [ ] Security roles assigned
- [ ] Smoke test the PCF controls and key custom pages

---

## 7. Clean up after deploying

Leave the tool folder empty so the next developer starts clean:

```powershell
$tool = "C:\PackageDeployer\PackageDeployertool"
Remove-Item "$tool\PkgAssets" -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem "$tool\*.dll","$tool\*.pdb" |
  Where-Object { $_.Name -notmatch '^(Microsoft|System|Azure|Newtonsoft|SolutionPackagerLib)' } |
  Remove-Item -Force
Remove-Item "$tool\PackageDeployer.tokens.dat" -Force -ErrorAction SilentlyContinue
```

`PackageDeployer.tokens.dat` caches your sign-in — delete it if the next
person will use a different account.

---

## 8. Troubleshooting

| Message / symptom | Cause | Fix |
|---|---|---|
| `No Import packages found` | Files blocked by Windows | Step 3 — `Unblock-File`, then relaunch |
| `No Import packages found` (after unblocking) | Package DLL or assets folder missing / wrong name | Step 4 verification; do not rename `PkgAssets` |
| `No Import packages found` (still) | Folder is under Downloads / OneDrive / a very long path | Move to a short local path such as `C:\PD` |
| `Multiple import packages were found` | Old package DLL left behind | Step 1 cleanup, keep exactly one non-Microsoft DLL |
| `Get-ChildItem is not recognized` | You are in Command Prompt | Use PowerShell, or prefix with `powershell -Command "..."` |
| Login works, no environments listed | Missing System Administrator, or wrong region | Verify role; reselect region |
| A solution fails to import | Missing dependency or version conflict | Read the log before retrying |
| `... is a lower version` | Target already has a newer build | Use a clean environment; downgrades are not supported |
| Appears stuck on one solution | Large solutions genuinely take 20–40 min | Wait; check the log is still being written to |
| Unmanaged solution rejected | AppSource requires managed solutions | Get a managed build from the build team |

---

## 9. Logs

| Method | Location |
|---|---|
| GUI | `%APPDATA%\Microsoft\PackageDeployer\PackageDeployer-<date>.log` |
| PAC CLI | the path passed to `--logFile` |
| PowerShell module | the path passed to `-LogWriteDirectory` |

Paste the `%APPDATA%` path into File Explorer to open it.
**Always attach the log when escalating a failure.**

---

## 10. Rules — do not break these

- Never rename `PkgAssets` / `PkgFolder`, `ImportConfig.xml`, or any solution zip
  (numeric filename prefixes control import order)
- Never hand-edit `ImportConfig.xml` or `manifest.ppkg.json` — request a new build
- The package `.dll` and its assets folder must come from the **same build**
- Never mix files from two different package versions in the tool folder
- Do not delete or replace the `Microsoft.*` / `System.*` DLLs in `PackageDeployertool`
