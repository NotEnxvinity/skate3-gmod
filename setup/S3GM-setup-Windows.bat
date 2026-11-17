@echo off
rem S3GM setup for Windows: drag your Skate 3 .iso onto this, or double-click it.
rem It runs setup-files\windows-setup.ps1 (everything but the launchers lives there).
set "S3GM_PS1=%~dp0setup-files\windows-setup.ps1"
if not exist "%S3GM_PS1%" set "S3GM_PS1=%~dp0windows-setup.ps1"
set PYTHONDONTWRITEBYTECODE=1
powershell -NoProfile -ExecutionPolicy Bypass -File "%S3GM_PS1%" %*
rem The setup starts itself again without a console, so this black window
rem closes right away and the setup window shows the progress. It only stays
rem open when PowerShell itself failed to start the setup.
if errorlevel 1 pause
