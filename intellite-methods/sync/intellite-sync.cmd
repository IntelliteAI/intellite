@echo off
rem Starts the Intellite sync (Windows PowerShell).
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0sync.ps1" %*
