@echo off
setlocal
pushd "%~dp0" >nul
if errorlevel 1 (
  echo Unable to access the Team ESMI SAMI folder.
  pause
  exit /b 1
)
set "TEAM_ROOT=%CD%"
set "REPAIR_ROOT=%LOCALAPPDATA%\SAMI-Kanban-WorkServer\icon-repair"
if not exist "%REPAIR_ROOT%" mkdir "%REPAIR_ROOT%"
copy /y "%TEAM_ROOT%\Repair_SAMI_Project_Portfolio_Icon.ps1" "%REPAIR_ROOT%\Repair_SAMI_Project_Portfolio_Icon.ps1" >nul
if errorlevel 1 (
  echo Unable to copy the SAMI icon repair into the local user cache.
  popd
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPAIR_ROOT%\Repair_SAMI_Project_Portfolio_Icon.ps1" -TeamRoot "%TEAM_ROOT%" %*
set "REPAIR_EXIT=%ERRORLEVEL%"
popd
endlocal & exit /b %REPAIR_EXIT%
