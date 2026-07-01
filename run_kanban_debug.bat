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
set "FAILED=0"

echo SAMI Kanban debug launcher
echo.
echo Source root: %SOURCE_ROOT%
echo Local site: %LOCAL_SITE%
echo Local logs: %LOCAL_LOGS%
echo Local runtime: %LOCAL_RUNTIME%
echo Dashboard URL: %URL%
echo.

mkdir "%LOCAL_BASE%" >nul 2>&1
mkdir "%LOCAL_SITE%" >nul 2>&1
mkdir "%LOCAL_LOGS%" >nul 2>&1
mkdir "%LOCAL_RUNTIME%" >nul 2>&1

>>"%LOG%" echo.
>>"%LOG%" echo(==================================================
>>"%LOG%" echo(SAMI Kanban DEBUG run started %date% %time%
>>"%LOG%" echo(Source root: %SOURCE_ROOT%
>>"%LOG%" echo(Local site: %LOCAL_SITE%
>>"%LOG%" echo(Local logs: %LOCAL_LOGS%
>>"%LOG%" echo(Local runtime: %LOCAL_RUNTIME%
>>"%LOG%" echo(Dashboard URL: %URL%

echo Syncing lightweight web app and data to local mirror...
where robocopy >nul 2>&1
if errorlevel 1 (
  set "SYNC_RESULT=robocopy not found"
  set "FAILED=1"
  echo robocopy result: robocopy not found
  >>"%LOG%" echo(ERROR: robocopy was not found. Windows robocopy is required for mirror sync.
) else (
  robocopy "%SOURCE_ROOT%" "%LOCAL_SITE%" "index.html" "serve_kanban.ps1" /R:1 /W:1 /COPY:DAT /NP
  set "ROOT_SYNC_RESULT=!ERRORLEVEL!"
  robocopy "%SOURCE_ROOT%\assets" "%LOCAL_SITE%\assets" "sami-gosa-logo.jpg" /R:1 /W:1 /COPY:DAT /NP
  set "ASSET_SYNC_RESULT=!ERRORLEVEL!"
  robocopy "%SOURCE_ROOT%\data" "%LOCAL_SITE%\data" "projects.json" "card_updates.jsonl" "kanban_config.json" "project_file_index.json" "card_activity_index.json" /R:1 /W:1 /COPY:DAT /NP
  set "DATA_SYNC_RESULT=!ERRORLEVEL!"
  set "SYNC_RESULT=root=!ROOT_SYNC_RESULT! asset=!ASSET_SYNC_RESULT! data=!DATA_SYNC_RESULT!"
  echo lightweight robocopy results: !SYNC_RESULT!
  >>"%LOG%" echo(lightweight robocopy results: !SYNC_RESULT!
  if !ROOT_SYNC_RESULT! GEQ 8 set "FAILED=1"
  if !ASSET_SYNC_RESULT! GEQ 8 set "FAILED=1"
  if !DATA_SYNC_RESULT! GEQ 8 set "FAILED=1"
  if "!FAILED!"=="1" (
    set "FAILED=1"
    >>"%LOG%" echo(ERROR: lightweight robocopy failed: !SYNC_RESULT!.
  )
  if exist "%LOCAL_SITE%\project_files" echo WARNING: Legacy local project_files exists but is ignored and is not synchronized.
  if exist "%LOCAL_SITE%\project_files" >>"%LOG%" echo(WARNING: Legacy local project_files exists but is ignored and is not synchronized.
)

if exist "%LOCAL_SITE%\index.html" (
  echo Local index.html exists: yes
  >>"%LOG%" echo(Local index.html exists: yes
) else (
  echo Local index.html exists: no
  >>"%LOG%" echo(ERROR: Local index.html missing: %LOCAL_SITE%\index.html
  set "FAILED=1"
)

if exist "%LOCAL_SITE%\data\projects.json" (
  echo Local data\projects.json exists: yes
  >>"%LOG%" echo(Local data\projects.json exists: yes
) else (
  echo Local data\projects.json exists: no
  >>"%LOG%" echo(ERROR: Local data\projects.json missing: %LOCAL_SITE%\data\projects.json
  set "FAILED=1"
)

if "!FAILED!"=="0" (
  copy /Y "%LOCAL_SITE%\serve_kanban.ps1" "%RUNTIME_PS1%" >nul 2>&1
  if errorlevel 1 (
    echo Local runtime PS1 exists: no
    >>"%LOG%" echo(ERROR: Could not copy server script to local runtime: %RUNTIME_PS1%
    set "FAILED=1"
  ) else (
    echo Local runtime PS1 exists: yes
    >>"%LOG%" echo(Local runtime PS1: %RUNTIME_PS1%
  )
)

echo.
echo Checking port 8011...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8011' -TimeoutSec 2 | Out-Null; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
  set "SERVER_UP=0"
  echo Port 8011 responds: no
  >>"%LOG%" echo(Port check: 127.0.0.1:8011 did not respond.
) else (
  set "SERVER_UP=1"
  echo Port 8011 responds: yes
  >>"%LOG%" echo(Port check: 127.0.0.1:8011 responded.
)

if "!FAILED!"=="0" (
  if "!SERVER_UP!"=="0" (
    echo Starting server from local mirror...
    >>"%LOG%" echo(Starting local server from local mirror.
    >>"%BOOTSTRAP_LOG%" echo(==================================================
    >>"%BOOTSTRAP_LOG%" echo(Debug launcher starting PowerShell %date% %time%
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
      echo Server responded after startup.
      >>"%LOG%" echo(Server responded after startup.
    ) else (
      echo ERROR: Server still did not respond after startup.
      >>"%LOG%" echo(ERROR: Server did not respond after startup. Check bootstrap and server logs.
      set "FAILED=1"
    )
  ) else (
    echo Existing server detected. Not starting another server.
    >>"%LOG%" echo(Existing server detected on port 8011. Not starting another server.
  )
)

if "!FAILED!"=="0" (
  echo.
  echo Opening dashboard: %URL%
  >>"%LOG%" echo(Opening dashboard: %URL%
  start "" "%URL%"
)

if "!FAILED!"=="1" (
  echo.
  echo Last 30 lines of run_kanban.log:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path -LiteralPath '%LOG%') { Get-Content -LiteralPath '%LOG%' -Tail 30 } else { 'run_kanban.log does not exist.' }"
  echo.
  echo Last 30 lines of kanban_bootstrap.log:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path -LiteralPath '%BOOTSTRAP_LOG%') { Get-Content -LiteralPath '%BOOTSTRAP_LOG%' -Tail 30 } else { 'kanban_bootstrap.log does not exist.' }"
  echo.
  echo Last 30 lines of kanban_server.log:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path -LiteralPath '%SERVER_LOG%') { Get-Content -LiteralPath '%SERVER_LOG%' -Tail 30 } else { 'kanban_server.log does not exist.' }"
)

>>"%LOG%" echo(SAMI Kanban DEBUG run finished %date% %time%
echo.
echo Done. Logs:
echo %LOG%
echo %BOOTSTRAP_LOG%
echo %SERVER_LOG%
echo.
pause
if "!FAILED!"=="1" (
  endlocal
  exit /b 1
) else (
  endlocal
  exit /b 0
)
