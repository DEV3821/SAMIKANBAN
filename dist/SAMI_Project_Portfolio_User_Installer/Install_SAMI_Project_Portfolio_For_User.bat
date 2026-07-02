@echo off
setlocal
title Install SAMI Project Portfolio
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install_SAMI_Project_Portfolio_For_User.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo Installation failed. Review the message above or contact SAMI support.
  pause
)
endlocal & exit /b %RESULT%
