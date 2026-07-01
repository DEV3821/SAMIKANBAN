@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SOURCE_ROOT=%~dp0"
if "%SOURCE_ROOT:~-1%"=="\" set "SOURCE_ROOT=%SOURCE_ROOT:~0,-1%"
set "LOCAL_BASE=%LOCALAPPDATA%\SAMI-Kanban-WorkServer"
set "LOCAL_SITE=%LOCAL_BASE%\site"
set "LOCAL_LOGS=%LOCAL_BASE%\logs"
set "LOCAL_RUNTIME=%LOCAL_BASE%\runtime"
set "RUNTIME_PS1=%LOCAL_RUNTIME%\serve_kanban.ps1"
set "URL=http://127.0.0.1:8011"
set "LOG=%LOCAL_LOGS%\run_kanban.log"
set "SERVER_LOG=%LOCAL_LOGS%\kanban_server.log"
set "BOOTSTRAP_LOG=%LOCAL_LOGS%\kanban_bootstrap.log"
set "SYNC_OK=0"
set "SYNC_RESULT=not run"

mkdir "%LOCAL_BASE%" >nul 2>&1
mkdir "%LOCAL_SITE%" >nul 2>&1
mkdir "%LOCAL_LOGS%" >nul 2>&1
mkdir "%LOCAL_RUNTIME%" >nul 2>&1

>>"%LOG%" echo.
>>"%LOG%" echo(==================================================
>>"%LOG%" echo(SAMI Kanban run started %date% %time%
>>"%LOG%" echo(Source root: %SOURCE_ROOT%
>>"%LOG%" echo(Local site: %LOCAL_SITE%
>>"%LOG%" echo(Local logs: %LOCAL_LOGS%
>>"%LOG%" echo(Local runtime: %LOCAL_RUNTIME%
>>"%LOG%" echo(Dashboard URL: %URL%

where robocopy >nul 2>&1
if errorlevel 1 (
  >>"%LOG%" echo(ERROR: robocopy was not found. Windows robocopy is required for mirror sync.
  goto fail
)

robocopy "%SOURCE_ROOT%" "%LOCAL_SITE%" "index.html" "serve_kanban.ps1" /R:1 /W:1 /COPY:DAT /NP /NFL /NDL >nul
set "ROOT_SYNC_RESULT=!ERRORLEVEL!"
robocopy "%SOURCE_ROOT%\assets" "%LOCAL_SITE%\assets" "sami-gosa-logo.jpg" /R:1 /W:1 /COPY:DAT /NP /NFL /NDL >nul
set "ASSET_SYNC_RESULT=!ERRORLEVEL!"
robocopy "%SOURCE_ROOT%\data" "%LOCAL_SITE%\data" "projects.json" "card_updates.jsonl" "kanban_config.json" "project_file_index.json" "card_activity_index.json" /R:1 /W:1 /COPY:DAT /NP /NFL /NDL >nul
set "DATA_SYNC_RESULT=!ERRORLEVEL!"
set "SYNC_RESULT=root=!ROOT_SYNC_RESULT! asset=!ASSET_SYNC_RESULT! data=!DATA_SYNC_RESULT!"
>>"%LOG%" echo(lightweight robocopy results: !SYNC_RESULT!
if !ROOT_SYNC_RESULT! GEQ 8 goto sync_fail
if !ASSET_SYNC_RESULT! GEQ 8 goto sync_fail
if !DATA_SYNC_RESULT! GEQ 8 goto sync_fail
set "SYNC_OK=1"
if exist "%LOCAL_SITE%\project_files" >>"%LOG%" echo(WARNING: Legacy local project_files exists but is ignored and is not synchronized.
goto sync_done

:sync_fail
>>"%LOG%" echo(ERROR: lightweight robocopy failed: !SYNC_RESULT!.
goto fail

:sync_done

if not exist "%LOCAL_SITE%\index.html" (
  >>"%LOG%" echo(ERROR: Local index.html missing: %LOCAL_SITE%\index.html
  goto fail
)
if not exist "%LOCAL_SITE%\data\projects.json" (
  >>"%LOG%" echo(ERROR: Local data\projects.json missing: %LOCAL_SITE%\data\projects.json
  goto fail
)

copy /Y "%LOCAL_SITE%\serve_kanban.ps1" "%RUNTIME_PS1%" >nul 2>&1
if errorlevel 1 (
  >>"%LOG%" echo(ERROR: Could not copy server script to local runtime: %RUNTIME_PS1%
  goto fail
)

>>"%LOG%" echo(Local index.html exists: yes
>>"%LOG%" echo(Local data\projects.json exists: yes
>>"%LOG%" echo(Local runtime PS1: %RUNTIME_PS1%

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8011' -TimeoutSec 2 | Out-Null; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
  set "SERVER_UP=0"
  >>"%LOG%" echo(Port check: 127.0.0.1:8011 did not respond.
) else (
  set "SERVER_UP=1"
  >>"%LOG%" echo(Port check: 127.0.0.1:8011 responded.
)

if "!SERVER_UP!"=="0" (
  >>"%LOG%" echo(Starting local server from local mirror.
  >>"%BOOTSTRAP_LOG%" echo(==================================================
  >>"%BOOTSTRAP_LOG%" echo(Launcher starting PowerShell %date% %time%
  >>"%BOOTSTRAP_LOG%" echo(Runtime PS1: %RUNTIME_PS1%
  >>"%BOOTSTRAP_LOG%" echo(RootPath: %LOCAL_SITE%
  >>"%BOOTSTRAP_LOG%" echo(Server log: %SERVER_LOG%
  start "SAMI Kanban Server" /min cmd /c ""powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%RUNTIME_PS1%" -RootPath "%LOCAL_SITE%" -SourceRoot "%SOURCE_ROOT%" -Port 8011 -LogPath "%SERVER_LOG%" >> "%BOOTSTRAP_LOG%" 2>&1"
  set "STARTED_OK=0"
  for /L %%I in (1,1,10) do (
    if "!STARTED_OK!"=="0" (
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8011' -TimeoutSec 1 | Out-Null; exit 0 } catch { exit 1 }" >nul 2>&1
      if not errorlevel 1 set "STARTED_OK=1"
      if "!STARTED_OK!"=="0" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 1" >nul 2>&1
    )
  )
  if "!STARTED_OK!"=="1" (
    >>"%LOG%" echo(Server responded after startup.
  ) else (
    >>"%LOG%" echo(ERROR: Server did not respond after startup. Check bootstrap and server logs.
    goto fail
  )
) else (
  >>"%LOG%" echo(Existing server detected on port 8011. Not starting another server.
)

>>"%LOG%" echo(Opening dashboard: %URL%
start "" "%URL%"
>>"%LOG%" echo(SAMI Kanban run finished %date% %time%
endlocal
exit /b 0

:fail
>>"%LOG%" echo(SAMI Kanban run failed %date% %time%
endlocal
exit /b 1
