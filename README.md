# SAMI Kanban WorkServer

This repository contains the SAMI Kanban application shell. Live board data, audit history, project documents, logs, backups, and runtime mirrors are intentionally excluded.

## Local setup

1. Copy `data/projects.example.json` to `data/projects.json`.
2. Copy `data/kanban_config.example.json` to `data/kanban_config.json`.
3. Optionally set `SAMI_KANBAN_TEAM_ROOT` to the canonical shared WorkServer directory.
4. Run `run_kanban.bat`.

When `SAMI_KANBAN_TEAM_ROOT` is not set, the server uses the local source directory. Never commit live `data/projects.json`, `data/card_updates.jsonl`, `project_files`, logs, or credentials.
