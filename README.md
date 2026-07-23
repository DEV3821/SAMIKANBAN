# SAMI Kanban WorkServer

This repository contains the SAMI Kanban application shell. Live board data, audit history, project documents, logs, backups, and runtime mirrors are intentionally excluded.

## Local setup

1. Copy `data/projects.example.json` to `data/projects.json`.
2. Copy `data/kanban_config.example.json` to `data/kanban_config.json`.
3. Optionally set `SAMI_KANBAN_TEAM_ROOT` to the canonical shared WorkServer directory.
4. Run `run_kanban.bat`.

When `SAMI_KANBAN_TEAM_ROOT` is not set, the server uses the local source directory. Never commit live `data/projects.json`, `data/card_updates.jsonl`, `project_files`, logs, or credentials.

## Existing-user updates (zero install)

Existing users, including Robyn, keep using their current **SAMI Project Portfolio** Desktop or Start Menu shortcut. Do not rerun the per-user installer for normal UI releases.

On each launch, the existing bootstrap process:

1. Reads the current application files from the canonical Team ESMI WorkServer.
2. Refreshes the user's runtime mirror under `%LOCALAPPDATA%\SAMI-Kanban-WorkServer\site`.
3. Starts the local server in the background.
4. Opens the portfolio in a Microsoft Edge app-style window.

Normal UI updates require no administrator rights, PWA installation, dependency installation, or manual file copying. The installer under `dist\SAMI_Project_Portfolio_User_Installer` is for first-time setup only. If Team ESMI is unavailable, the existing launcher warning and local fallback rules still apply.
