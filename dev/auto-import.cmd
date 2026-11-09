@echo off
rem Task Scheduler shim for the Windows auto-import trigger: all logic is in
rem auto-import.ps1 (PowerShell 7), which this forwards every argument to.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-import.ps1" %*
exit /b %ERRORLEVEL%
