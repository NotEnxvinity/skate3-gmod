@echo off
rem S3GM setup for Windows: double-click this. It runs windows-setup.ps1 beside it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-setup.ps1" %*
pause
