@echo off
setlocal
title Uninstall SAMI Project Portfolio
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall_SAMI_Project_Portfolio_For_User.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
endlocal & exit /b %RESULT%
