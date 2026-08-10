# SAMI Kanban WorkServer

This repository contains the SAMI Kanban application shell. Live board data, audit history, project documents, logs, backups, and runtime mirrors are intentionally excluded.

## Local setup

1. Copy `data/projects.example.json` to `data/projects.json`.
2. Copy `data/kanban_config.example.json` to `data/kanban_config.json`.
3. Optionally set `SAMI_KANBAN_TEAM_ROOT` to the canonical shared WorkServer directory.
4. Run `run_kanban.bat`.

When `SAMI_KANBAN_TEAM_ROOT` is not set, the server uses the local source directory. Never commit live `data/projects.json`, `data/card_updates.jsonl`, `project_files`, logs, or credentials.

## Production user launch

Normal users use one **SAMI Kanban** shortcut. It opens the hosted production release directly at:

`http://SAH0235190:8788/`

The hosted service runs on `SAH0235190` (`10.23.77.57`) and reads the production authority under `C:\SAMI_KANBAN`. Team ESMI is used for backup, archive, and project-document integration; it is not in the normal click-to-open path.

The normal shortcut must not start `bootstrap_kanban.ps1`, copy a runtime mirror, run Robocopy, start a local server, probe a health endpoint, or scan Team ESMI. The old **SAMI Project Portfolio** launcher is retained only as a recoverable compatibility file and must not be restored as the normal shortcut.

For a new or migrated user, install the direct shortcut with:

```powershell
.\tools\install_sami_kanban_hosted_shortcut.ps1
```

The installer creates a direct `.url` shortcut, preserves the SAMI icon, backs up any old `.lnk` launcher, and does not copy or run the application runtime. Use `-NoLaunch` when staging the shortcut for another user. The root `install_sami_project_portfolio.ps1` remains as a compatibility entry point and now delegates to the hosted shortcut installer.

Verify the hosted release without changing production:

```powershell
Invoke-RestMethod http://SAH0235190:8788/api/health
Invoke-RestMethod http://SAH0235190:8788/api/app-version/status
```

If DNS is temporarily unavailable, the equivalent direct endpoint is `http://10.23.77.57:8788/`. Do not use the old `127.0.0.1:8011` launcher for normal access.
