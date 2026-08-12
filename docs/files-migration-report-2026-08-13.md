# SAMI Kanban Files Migration Report — 2026-08-13

Status: AMBER — implementation deployed and HTTP acceptance is green; a real second laptop session was not available from this workstation.

## Diagnosis

The Files action called `api/project-folder/open`, which launched `explorer.exe` on SAH0235190 and returned server-local paths. It did not provide a directory listing or file response over HTTP, so a remote browser could not use the result.

## Architecture and migration

- Canonical server root: `C:\SAMI_KANBAN`
- Canonical project repository: `C:\SAMI_KANBAN\project_files`
- Legacy source inspected: `\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer\project_files`
- Board: 50 cards; 31 cards linked to folders; 19 cards without folders.
- Copy mode: Robocopy `/E /COPY:DAT /DCOPY:DAT /Z`; Team_ESMI was not modified.
- Source inventory: 703 files, 1,325,136,326 bytes.
- Target inventory: 709 files, 1,328,568,290 bytes.
- Source entries missing from target: 0; size mismatches: 0.
- Target-only entries: 6 pre-existing cross-card-import files; preserved.
- Orphan folders preserved: `_Review_Queue`, `axon-mitis-secure-remote-gateway`, `vue-motion-dc-relocation`.
- Manifest: `\\SAH0235190\C$\SAMI_KANBAN\migration\files-migration-manifest-20260813.csv`

Selected SHA-256 verification matched for `project_files\sami-kanban\README.md`; board/config/index files were backed up before deployment.

## Implementation

- Added `GET /api/projects/<id>/files[/<relative-path>]`.
- Added inline HTTP responses for browser-viewable files and `?download=1` attachments.
- Added project-ID/card-folder reconciliation, traversal protection, encoded traversal rejection, and reparse-point rejection.
- Repaired the existing Files panel with folders, navigation, metadata, Open/View, Download, empty state, and bounded errors.
- New project folders continue to use immutable project IDs under the server repository.

## Acceptance evidence

- Health: `http://SAH0235190:8788/api/health` returned 200, `ok=true`, app version `2026.08.13.120000`.
- Root listing: `sami-kanban` returned 8 items.
- Nested listing: `card-002-ris-upgrade-ris-web-dependency-chain/03_Meetings` returned 2 items.
- DOCX view/download: 200; correct Office MIME type and filename with spaces.
- PDF view/download: 200; `application/pdf` and attachment filename with spaces.
- Traversal and nonexistent project requests were rejected.
- Existing regression tests passed: project file detection, project history, board order, card move, idle connection, and legacy launcher compatibility.

## Rollback

- Git checkpoint: `checkpoint-files-migration-20260813`.
- Production backup: `\\SAH0235190\C$\SAMI_KANBAN\backups\checkpoint-files-migration-20260813`.

