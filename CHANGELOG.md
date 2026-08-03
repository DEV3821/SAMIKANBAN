# SAMI Kanban WorkServer Change Log

## 2026-08-03 — 2026.08.03.144147

- Added server-managed Project Update History for Next Action set, changed, cleared, and baseline events with server timestamps, reliable actors only, deterministic snapshots, stale-revision protection, atomic project/audit writes, and idempotent retries.
- Preserved Additional Notes exactly as entered, including paragraphs, whitespace, punctuation, Unicode and literal markup; the drawer, Project Context, and Meeting Pack expose Notes separately from automatic history.
- History synchronises automatically between open Kanban users; receiving users get one configured update chime after the visible refresh, with initiating-user echoes suppressed.
- Added linked project-folder metadata scanning with temporary/backup exclusion, stable-access deferral, exact folder mapping, metadata-only file records, rename/delete reconciliation, shared index revisioning, and one-time `project_file_added` history events.
- New files are detected only after their metadata is stable; file contents are never opened, read, parsed, uploaded or summarised.
- Added preview-first `tools/migrate_project_history.ps1` with expected-revision apply protection, timestamped backups, rollback verification, optional explicit file baseline establishment, and migration state idempotency.
- Added isolated synthetic history and file-detection regression suites; existing card-move, board-order, drag-state, launcher, sync workflow, and Meeting Pack checks remain covered.
- Existing dragging, cross-lane movement, auto-scroll, keyboard movement, and Start Menu installations remain supported; the normal Team ESMI refresh requires no reinstall.

## 2026-08-03 — 2026.08.03.122015

- Dragging is easier and can begin from the non-interactive card surface, while buttons, links, inputs, labels, file controls and Project Context controls remain protected.
- Cards can now be dragged between workflow lanes.
- Cross-lane dragging updates card status and shared ordering through one atomic server-side operation with revision checks, backups, rollback and a `card_moved` audit event.
- The board automatically scrolls near the screen edge during dragging and retains a clear ghost, placeholder and insertion marker.
- Remote reordered and moved cards now update visually before the notification chime; canonical projects and board order are fetched, reconciled, rendered and DOM-verified as one bounded refresh.
- Alt+Up / Alt+Down reorders within a lane and Alt+Left / Alt+Right moves cards between lanes with the same revision and audit protections.
- Existing Start Menu installations receive the update automatically. No reinstall is required; the launcher, shortcut structure, runtime path, port, and canonical-root discovery are unchanged.

## 2026-08-03 — 2026.08.03.101550

- Added within-lane card reordering for Backlog, In Progress, Blocked, and Done using a dedicated drag handle and Alt+Up / Alt+Down keyboard movement.
- Added shared `data/board_order.json` persistence with canonical Team ESMI revision checks, backups, atomic writes, stale-order HTTP 409 handling, and non-destructive reconciliation.
- Added lightweight two-second visible sync-state polling with slower hidden polling and full portfolio/order fetches only after a verified shared signature change.
- Added coalesced remote update notifications and remote chimes for changes made by another Kanban session, with self-echo suppression and Off/Low/Normal sound preferences preserved.
- Reordering requires unlocked editing, Team ESMI availability, and cleared search/filter state. This earlier release did not support cross-lane drag; the 2026.08.03.122015 hotfix adds the bounded atomic move path.
- Existing installations receive the updated application shell through the normal Team ESMI bootstrap refresh. Reinstalling is not required; the launcher, shortcut structure, runtime path, port, and canonical-root discovery are unchanged.

## 2026-07-17 — 2026.07.17.081709

- Published the validated SAMI Project Portfolio application shell to the canonical Team ESMI location: `\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer`.
- Corrected the workflow palette to the required Backlog/In Progress/Blocked/Done colours: grey, teal, red, and green. The obsolete Ready lane remains hidden.
- Hardened deployment so release metadata is not rewritten during publication, destinations must remain inside the canonical SAMI application folder, and protected runtime paths are rejected explicitly.
- Preserved live portfolio data and history. Before/after hashes for `data/projects.json` and `data/card_updates.jsonl` were identical; `project_files` and logs were unchanged. Normal timestamped application-shell deployment backups were created.
- Verified root, canonical, packaged-payload, and installed-client application-shell hashes. Required JSON fields, DOM IDs, markup nesting, clipboard fallback, save-only/test-only sound behaviour, silent polling, filtered lane counts, empty states, and Meeting Pack exports passed validation.
- Proved the existing installed shortcut updates without reinstalling: an older local client (`2026.07.14.120850`) detected `Update available from Team ESMI`, the existing shortcut refreshed and restarted the local shell, and local/canonical versions finished at `2026.07.17.081709` in shared mode.
- Verified local-first fallback using an isolated client and nonexistent canonical root. The application returned HTTP 200 in `local-fallback` mode with cached portfolio and audit data retained.

## 2026-07-16

- Added Copy Project Context for AI: per-card button (aria-label "Copy full project context for AI") that builds a clean Markdown dossier from existing metadata/index only — no project-file contents are opened or read — with clipboard success/failure handling (toast, icon ✓ revert after ~2s, escaped textarea fallback).
- Completed Project Health terminology: all user-visible risk labels now read "Project health" / On track / Needs attention / At risk / Not assessed. Internal schema fields `risk` and `riskColour` (and `risk_changed` activity history) are unchanged.
- Added optional update chime and sound-preference control (off / low / normal), with a Play test sound action that never mutates or saves project state; Web Audio failures degrade safely.
- Coordinated authoritative manual-save feedback (`onManualSaveSuccess`) so a successful manual save produces exactly one "Project updated" toast, one save flash, one "Updated just now" badge, and at most one chime. Background refresh, import, drawer open, test sound and copy-context no longer trigger the save chime.
- Save-button state now blocks duplicate submissions while a save is pending and shows Saving… / Saved / Save failed / idle with controls disabled during the pending write.
- Silent shared-source refresh: poll/sync paths now use a common quiet-refresh path; a quiet toast appears only when shared-source revision/content actually changes, deduplicated, and never fires the manual-save chime/highlight.
- Live lane counts recompute through the normal render/filter path and stay accurate after add/edit/move/delete/search/background refresh; lane-specific empty-state text is shown for each of the four lanes (no Ready lane).
- Local release validation performed through file inspection, Node syntax checks, and a local server running against an isolated test copy of `projects.example.json`. No production/Team ESMI data was used.

## 2026-06-23

- Added Recently Updated card badges using existing `lastUpdated` metadata, with `data/card_updates.jsonl` as a read-only fallback when a card has no timestamp.
- Added a Recently Updated strip showing the latest five updated cards; strip items scroll to and briefly highlight the matching board card.
- Added a lightweight Recent toggle that emphasizes cards updated in the last seven days without changing the default board order or hiding cards by default.
- Changed Presentation Mode from selected-card presentation to a one-click fullscreen, read-only full-board portfolio wall.
- Presentation Mode now shows all Backlog, In Progress, Blocked, and Done cards with title, status, risk, lead, next action, review date, and last-updated badge.
- Preserved the existing edit/save/sync model: audit-first save flow, `projects.json` canonical board data, `card_updates.jsonl` append behavior, edit token protection, stale revision checks, and Team ESMI/local mirror write targets.
- Created timestamped backups before editing: `index.html.bak-20260623-133452` locally and on the Team ESMI UNC source.
- Local implementation validation performed through file inspection and server checks; no real two-PC validation was performed.
