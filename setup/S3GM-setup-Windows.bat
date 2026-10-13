@echo off
rem S3GM setup for Windows: drag your Skate 3 .iso onto this, or double-click it.
rem It runs windows-setup.ps1 beside it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-setup.ps1" %*
pause
