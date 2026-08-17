# Package Deployer Studio

A Windows desktop front-end for the Microsoft **Package Deployer** tool and the
**Power Platform CLI** — sign in, browse environments and solutions, build a
deployment package, and deploy it, without typing a command.

No install, no build step. A single PowerShell script and a `.bat` launcher.

---

## Install

1. Download the latest zip from [Releases](../../releases).
2. **Right-click the zip, Properties, tick Unblock**, then extract it.
   Windows blocks anything that arrived from a download, and .NET will
   otherwise refuse to load the package assembly with a misleading error.
3. Double-click **`Install.cmd`**. It asks whether to unblock the files — say **Yes**.

The installer needs no admin rights. It copies the app to
`%LOCALAPPDATA%\Programs\PackageDeployerStudio`, unblocks it, creates Start Menu
and desktop shortcuts, and registers an entry in **Apps and features**.

Then add Microsoft's `PackageDeployertool` folder to the install folder — it is
**not** redistributed here. Get it from the
[Package Deployer NuGet package](https://www.nuget.org/packages/Microsoft.CrmSdk.XrmTooling.PackageDeployment.WPF)
and extract its `tools\` folder. If you drop it next to `Install.cmd` *before*
installing, the installer copies it across for you.

**Uninstall** — Apps and features, or `Install.ps1 -Uninstall`. Your
`PackageDeployertool` folder is left alone.

### Running without installing

Extract the zip anywhere with a short path and double-click
`PackageDeployerStudio.bat`. The folder should look like:

```
C:\PD\
 ├─ PackageDeployerStudio.bat
 ├─ PackageDeployerStudio.ps1
 └─ PackageDeployertool\
      ├─ PackageDeployer.exe
      └─ Microsoft.*.dll ...
```

### Requirements

| | |
|---|---|
| Windows + PowerShell 5.1 | built in — nothing to install |
| [PAC CLI](https://learn.microsoft.com/power-platform/developer/cli/introduction) | for Environment, Solutions, Create Package, CLI deploy |
| .NET SDK | for `dotnet publish` when building a package |

```powershell
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
pac install latest
```

---

## Getting around

**Sidebar** — Create Package, Deploy, Environment, Solutions. The hamburger
button collapses it to icons only when you want the width back; the state is
remembered.

**Light and dark** — the button in the top right toggles the theme. Also
remembered between sessions.

**Activity panel** — a proper list, not a console: timestamp, colour-coded
level badge, message. Filter it down to *Steps and results* or *Problems only*
when you are showing someone, or collapse it with the chevron for more room.
**Save** writes the full transcript to `.\logs\`.

**Nothing overlaps** — long jobs run on a background runspace. The window stays
responsive, a progress card covers the page area, and starting a second action
while one is running is refused with a note in the log rather than corrupting
the first. `Do all 1-4` chains its steps through completion callbacks, so each
one waits for the last to finish.

---

## The four pages

### Environment

1. Name the connection, click **Sign in**. A console window opens with the
   Microsoft sign-in page — MFA included. Tick **Use device code** if the
   browser popup does not appear.
2. **Load environments** lists every environment you can reach.
3. Pick one and click **Use selected environment** (or double-click it). The
   sidebar shows what you are pointed at, everywhere in the app.

Also: **Saved connections**, **Switch to named**, **Clear all**.

### Solutions

Lists every solution in the selected environment, with version and managed flag.

- **Export checked** — managed, unmanaged, or both, into a folder you choose.
  Exports can drop straight into the Create Package list.
- **Import** a solution zip, with publish / activate plug-ins / force overwrite /
  stage and upgrade.

### Create Package

Builds a Package Deployer package:

```
pac package init -o <name>
pac package add-solution -p <zip>     (once per solution, in list order)
dotnet publish
```

The result is wired into the Deploy page automatically.

### Deploy

Two routes to the same place:

- **PAC CLI** — `pac package deploy`, with a confirmation showing the target org
  and a timestamped log in `.\logs\`.
- **The GUI tool** — Clean → Load → Verify → Launch, automating every manual step
  in the Package Deployer runbook.

| Step | What it does |
|---|---|
| **Clean** | Removes the previous package: assets folder, package `.dll`/`.pdb`, cached sign-in. Never touches the tool's own files. |
| **Load** | Takes a `.pdpkg` folder or `.pdpkg.zip`, finds the real package root even when nested, copies the assets folder **under its original name**, then unblocks everything. |
| **Verify** | Exactly one package assembly, `ImportConfig.xml` parses, every solution zip it references exists, nothing still blocked. |
| **Launch** | Starts `PackageDeployer.exe`. |

#### Snapshot — do this once

With the tool folder clean, click **Snapshot** on the Deploy page. It records the
files that ship with the tool, so **Clean** removes exactly what is foreign
instead of guessing by filename.

> This matters. The cleanup snippet in Microsoft's own runbook filters on
> `^(Microsoft|System|Azure|Newtonsoft|SolutionPackagerLib)`. A stock tool folder
> contains **`netstandard.dll`**, which does not match — that snippet deletes it.
> Package Deployer Studio protects it either way.

---

## Troubleshooting

Click **Self-test** in the log toolbar. It reports PowerShell version, STA mode,
UI pump health, tool folder, baseline, and the resolved paths and versions of
`pac` and `dotnet`. Every error logs its exception type and script line number.
**Save** writes the log to `.\logs\`.

| Symptom | Cause | Fix |
|---|---|---|
| Sign-in does nothing | Browser popup blocked | Tick **Use device code instead** |
| `pac not found` | Installed after the app started | Restart the app so it picks up `PATH` |
| "X is still running" in the log | You started a second action | Wait — this is the guard doing its job |
| `No Import packages found` | Files blocked by Windows | Run **Load** again |
| `Multiple import packages were found` | Old package assembly left behind | **Clean**, then **Load** |
| No environments listed | Not signed in, or no System Administrator role | Sign in; check your role |

---

## Performance and security notes

**Performance**

- Long operations run in a background runspace; the UI thread only drains a
  message queue on a 120 ms timer.
- **Load** unblocks only the files it just copied. The full 550-file tool folder
  is unblocked once, on first run, and never again.
- Unblocking deletes the `Zone.Identifier` stream directly rather than calling
  `Unblock-File` per file.
- The tool-folder baseline is cached in memory and invalidated by file timestamp.
- The activity list is capped and scrolls once per batch instead of once per line.

**Security**

- Every delete is guarded by a canonical path-containment check, so **Clean**
  and package-project removal cannot touch anything outside their own folder.
- Zip extraction validates each entry's resolved path before writing — a
  `..\..\` entry in a `.pdpkg.zip` is blocked and logged, not extracted.
- Log output is scrubbed for client secrets, passwords, bearer tokens and JWTs
  before it reaches the screen or a saved file.
- Environment URLs must be `https`, must not embed credentials, and are flagged
  if they do not look like Dataverse.
- No credential is ever stored by this app. Authentication lives in the PAC
  CLI's own profile store; `settings.json` holds only paths and preferences.
- Destructive actions — import, deploy, clean-and-rebuild, clear connections —
  all confirm first, showing the target environment.

---

## Releasing a new version

1. Bump `$script:AppVersion` in `PackageDeployerStudio.ps1`.
2. Tag and push:
   ```bash
   git tag v1.2.2
   git push origin v1.2.2
   ```

GitHub Actions parses the script and the XAML, builds the zip, and attaches it to
a new Release. Anyone can then download and run it.

---

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with Microsoft. The Package Deployer tool and the Power Platform
CLI are Microsoft products under their own licence terms and are not
redistributed here.
