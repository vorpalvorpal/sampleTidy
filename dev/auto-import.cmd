@echo off
rem Hourly auto-import trigger (Windows). Counterpart of auto-import.sh. UNTESTED.
rem Exits at once unless this machine holds the live DB. Metadata-only gate, then Rscript.
setlocal EnableExtensions
set "HERE=%~dp0"
if not defined SAMPLETIDY_AUTOIMPORT_DB set "SAMPLETIDY_AUTOIMPORT_DB=%LOCALAPPDATA%\R\data\R\sampleTidy\monitoring.duckdb"
if not exist "%SAMPLETIDY_AUTOIMPORT_DB%" exit /b 0
rem Input dir: the SharePoint "assets" folder. PLACEHOLDER if SAMPLETIDY_INPUT_DIR is not in the environment:
if not defined SAMPLETIDY_AUTOIMPORT_INPUT (
  if defined SAMPLETIDY_INPUT_DIR (for %%I in ("%SAMPLETIDY_INPUT_DIR%\..") do set "SAMPLETIDY_AUTOIMPORT_INPUT=%%~fI") else exit /b 0
)
if not defined SAMPLETIDY_AUTOIMPORT_REPORT (
  if defined PKM_VAULT (set "V=%PKM_VAULT%") else set "V=%USERPROFILE%\pkm"
  set "SAMPLETIDY_AUTOIMPORT_REPORT=%V%\0 Misc\00 Misc\00.09 Import triage"
)
if not defined SAMPLETIDY_AUTOIMPORT_LOG set "SAMPLETIDY_AUTOIMPORT_LOG=%LOCALAPPDATA%\sampleTidy\autoimport.log"
if not defined SAMPLETIDY_AUTOIMPORT_RSCRIPT set "SAMPLETIDY_AUTOIMPORT_RSCRIPT=Rscript"
set "STATE=%SAMPLETIDY_AUTOIMPORT_REPORT%\.imports.state"
set "GATE=%SAMPLETIDY_AUTOIMPORT_REPORT%\.imports.gate"

set "NOW="
for /f "delims=" %%H in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%auto-import-gate.ps1" -Input "%SAMPLETIDY_AUTOIMPORT_INPUT%" -Db "%SAMPLETIDY_AUTOIMPORT_DB%"') do set "NOW=%%H"

if exist "%GATE%" if exist "%STATE%" if defined NOW (
  set /p OLD=<"%GATE%"
  setlocal EnableDelayedExpansion
  if "!OLD!"=="!NOW!" (
    findstr /R /C:"\"pending\" *: *true" "%STATE%" >nul 2>&1
    if errorlevel 1 exit /b 0
  )
  endlocal
)

if not exist "%LOCALAPPDATA%\sampleTidy" mkdir "%LOCALAPPDATA%\sampleTidy"
echo === %DATE% %TIME% auto-import start>>"%SAMPLETIDY_AUTOIMPORT_LOG%"
"%SAMPLETIDY_AUTOIMPORT_RSCRIPT%" "%HERE%auto-import.R" >>"%SAMPLETIDY_AUTOIMPORT_LOG%" 2>&1
if errorlevel 1 exit /b 1
set "NOW="
for /f "delims=" %%H in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%auto-import-gate.ps1" -Input "%SAMPLETIDY_AUTOIMPORT_INPUT%" -Db "%SAMPLETIDY_AUTOIMPORT_DB%"') do set "NOW=%%H"
if defined NOW (
  if not exist "%SAMPLETIDY_AUTOIMPORT_REPORT%" mkdir "%SAMPLETIDY_AUTOIMPORT_REPORT%"
  >"%GATE%" echo %NOW%
)
exit /b 0
