@echo off
setlocal
echo SAMI Project Portfolio debug launcher
echo App root: %~dp0
echo Runtime: %LOCALAPPDATA%\SAMI-Kanban-WorkServer\site
echo Logs: %LOCALAPPDATA%\SAMI-Kanban-WorkServer\logs
echo.
set "LOCAL_TOOLS=%LOCALAPPDATA%\SAMI-Kanban-WorkServer\launcher-cache\tools"
if not exist "%LOCAL_TOOLS%" mkdir "%LOCAL_TOOLS%"
copy /y "%~dp0tools\bootstrap_kanban.ps1" "%LOCAL_TOOLS%\bootstrap_kanban.ps1" >nul
set "SOURCE_ROOT=%~dp0"
if "%SOURCE_ROOT:~0,2%"=="\\" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCAL_TOOLS%\bootstrap_kanban.ps1" -TeamRoot "%SOURCE_ROOT:~0,-1%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCAL_TOOLS%\bootstrap_kanban.ps1"
)
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo Launch failed. Recent bootstrap log:
  powershell.exe -NoProfile -Command "Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer\logs\bootstrap_kanban.log') -Tail 30 -ErrorAction SilentlyContinue"
) else (
  echo Launch completed. The background server is single-instance and remains hidden.
)
echo.
pause
endlocal & exit /b %RESULT%
