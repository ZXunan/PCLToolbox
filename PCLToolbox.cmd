@echo off
setlocal
cd /d "%~dp0"
title PCLToolbox
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCLToolbox.ps1"
set ERR=%ERRORLEVEL%
if not "%ERR%"=="0" (
  echo.
  echo PCLToolbox exited with code %ERR%.
  echo Log: %LOCALAPPDATA%\PCLDownloadFix
  pause
)
exit /b %ERR%