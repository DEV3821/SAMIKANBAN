# SAMI Kanban client launcher runbook

## Normal production path

The normal user action is a single **SAMI Kanban** shortcut that opens:

`http://SAH0235190:8788/`

The IP fallback is `http://10.23.77.57:8788/`. The browser shortcut must not invoke Team ESMI, PowerShell, Python, Node, Robocopy, a local server, a health-check loop, or a recursive project scan.

Production authority remains `C:\SAMI_KANBAN\data`; the hosted app is served from `C:\SAMI_KANBAN\app` on `SAH0235190`. Do not change production data, PINs, or SAMI Intelligence while repairing a client shortcut.

## Incident evidence: old launcher

The migrated laptop had one user-facing entry:

`%APPDATA%\Microsoft\Windows\Start Menu\Programs\SAMI Project Portfolio.lnk`

It targeted `wscript.exe` with `Launch SAMI Project Portfolio.vbs`. That VBS checked the Team ESMI UNC path and started `launcher-cache\tools\bootstrap_kanban.ps1`. The bootstrap copied files and data from Team ESMI, started a local PowerShell server on `127.0.0.1:8011`, waited for local health, and then opened Edge.

The latest log block measured approximately 50 seconds from bootstrap entry to Edge open (`18:51:58` to `18:52:48` on 2026-08-10). The VBS UNC preflight occurred before the bootstrap log, making the user-visible delay consistent with about one minute. The old path never requested the production URL.

The old shortcut and launcher chain are backed up under:

`C:\Temp\SAMI-Kanban-ClientLauncher-20260810-191022`

## Migration procedure

Run the hosted shortcut installer in the user context:

```powershell
.\tools\install_sami_kanban_hosted_shortcut.ps1 -NoLaunch
```

It creates `SAMI Kanban.url`, preserves the SAMI icon, moves old `SAMI Project Portfolio.lnk` files to a recoverable backup, and writes a direct compatibility VBS. For a staged deployment, copy the installer and icon through the approved delivery channel; the recipient does not need to browse Team ESMI at click time.

After migration, confirm:

```powershell
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Filter '*SAMI*' | Select-Object Name,FullName
Get-NetTCPConnection -LocalPort 8011 -ErrorAction SilentlyContinue
Get-Process | Where-Object { $_.Path -like '*SAMI-Kanban-WorkServer*' }
```

The normal shortcut inventory should show one `SAMI Kanban.url`, no old `SAMI Project Portfolio.lnk`, no client-owned listener on port 8011, and no client-owned `serve_kanban.ps1` process.

## Release verification

The production service currently corresponds to application commit `ac10513`. During client acceptance, browser speculative connections exposed a single-threaded listener stall. The minimal server safeguard sets a 2-second request-read timeout and a 5-second write timeout; it does not change application logic, data, PINs, or the project scan schedule. The deployed `serve_kanban.ps1` SHA256 is:

`10c154e440990e4b5a1f484c4cf74ce41061577429f49c50acf98613a6b4208f`

Verify from a client without restarting anything:

```powershell
$health = Invoke-RestMethod 'http://SAH0235190:8788/api/health'
$version = Invoke-RestMethod 'http://SAH0235190:8788/api/app-version/status'
$health
$version
```

The hosted board should report the production runtime and the expected card set. Browser cache or service-worker work is only required if the hosted page itself serves stale assets; do not clear the whole browser profile as a shortcut fix.

## Acceptance record

One controlled normal shortcut launch opened the hosted document in approximately 2.1 seconds; a concurrent health request completed in approximately 317 ms. A five-shortcut/five-direct browser stress sample was stopped after Edge reused the profile and accumulated tabs, which reproduced contention against the single-threaded listener. The service was restarted, the timeout safeguard was deployed, and the final health/data/hash checks passed. Do not describe the multi-tab stress sample as five independent user launches.

## Robyn delivery

The source-of-truth deployment artefact is `tools\install_sami_kanban_hosted_shortcut.ps1`. The shared package is:

`\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer\installers\SAMI_Project_Portfolio_User_Installer`

The hosted-launcher files were delivered there on 2026-08-10. The previous shared files are recoverable from:

`\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer\backups\client-hosted-shortcut-source-20260810-195828`

Use the package installer in Robyn's user context and record the resulting shortcut path and acceptance timing. Do not distribute the legacy bootstrap as the normal launcher and do not ask Robyn to launch the application from Team ESMI.
