#Requires -Version 7
# Hourly auto-import trigger (Windows, PowerShell 7). Counterpart of auto-import.sh;
# dev/auto-import.cmd is only the Task Scheduler shim that forwards here.
# Does nothing unless this machine holds the live DB and something under the input
# folder (or the DB file) changed since the last good run. Metadata only (the gate script).
# Gate rules: skip only on an unchanged gate whose state is not pending; the gate is
# written after a good run (rc 0) only. The exit code is Rscript's, so an rc 3 (the
# deployment's hooks failed to load) reaches the scheduler.
# Test overrides: SAMPLETIDY_AUTOIMPORT_{DB,INPUT,REPORT,RSCRIPT,LOG,OFF},
# SAMPLETIDY_{INPUT_DIR,REPORT_DIR,TIMEZONE}. No R environ file is read here.
# Lock (R-22.H): the directory $REPORT\.imports.lock holding `pid`, created atomically.
# Arguments: -PrintConfig or --print-config prints the resolved values and exits; any
# other argument is ignored, so a stray one cannot stop the hourly run.
param([switch]$PrintConfig, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$HERE = $PSScriptRoot

# env KEY: the variable's value, or $null when unset or empty (empty counts as unset).
function env([string]$Key) { $v = [Environment]::GetEnvironmentVariable($Key); if ($v) { $v } }

# $WATCH holds INPUT (a variable named $INPUT would collide with PowerShell's automatic $input).
# Deployment values, resolved with no side effects: the SAMPLETIDY_AUTOIMPORT_* test
# override, then the process environment, then a default.
$LAD = env LOCALAPPDATA
$DB = env SAMPLETIDY_AUTOIMPORT_DB
if (-not $DB) { $DB = Join-Path $LAD 'R\data\R\sampleTidy\monitoring.duckdb' }
$WATCH = env SAMPLETIDY_AUTOIMPORT_INPUT
if (-not $WATCH) {
  $WATCH = env SAMPLETIDY_INPUT_DIR
  # batches arrive beside a folder named input, so watch its parent
  if ($WATCH) {
    $t = $WATCH.TrimEnd('\', '/')
    if ((Split-Path -Leaf $t) -ceq 'input') { $WATCH = Split-Path -Parent $t }
  }
}
$REPORT = env SAMPLETIDY_AUTOIMPORT_REPORT
if (-not $REPORT) { $REPORT = env SAMPLETIDY_REPORT_DIR }
if (-not $REPORT) { $REPORT = Join-Path $LAD 'R\data\R\sampleTidy\reports' }
$ZONE = env SAMPLETIDY_TIMEZONE
if (-not $ZONE) { $ZONE = 'UTC' }
$LOG = env SAMPLETIDY_AUTOIMPORT_LOG
if (-not $LOG) { $LOG = Join-Path $LAD 'sampleTidy\autoimport.log' }
$RSCRIPT = env SAMPLETIDY_AUTOIMPORT_RSCRIPT
if (-not $RSCRIPT) { $RSCRIPT = 'Rscript' }
$OFF = env SAMPLETIDY_AUTOIMPORT_OFF
if (-not $OFF) { $OFF = Join-Path $HOME '.sampletidy-autoimport-off' }

if ($PrintConfig -or $Rest -contains '--print-config') {
  "DB=$DB"; "INPUT=$WATCH"; "REPORT=$REPORT"; "TIMEZONE=$ZONE"; "LOG=$LOG"
  exit 0
}

if (-not (Test-Path -LiteralPath $DB -PathType Leaf)) { exit 0 }   # not the writer machine
# Off switch: the file's existence pauses auto-import (agents append a line each); remove it to resume.
if (Test-Path -LiteralPath $OFF) { exit 0 }

$utf8 = [Text.UTF8Encoding]::new($false)                           # UTF-8, no BOM
[void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($LOG))))
function logline([string]$Msg) {
  [IO.File]::AppendAllText($LOG, "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg`n", $utf8)
}
if (-not $WATCH -or -not (Test-Path -LiteralPath $WATCH -PathType Container)) {
  logline "input folder not found: $WATCH"; exit 0
}
$STATE = Join-Path $REPORT '.imports.state'; $GATE = Join-Path $REPORT '.imports.gate'
$LOCK = Join-Path $REPORT '.imports.lock'
[void][IO.Directory]::CreateDirectory($REPORT)

function gate_hash { (& (Join-Path $HERE 'auto-import-gate.ps1') -Input $WATCH -Db $DB -TimeZone $ZONE | Out-String).Trim() }

# Atomic lock (R-22.H). CreateDirectory succeeds on an existing folder, so it cannot be
# the test-and-set. Instead a private folder holding `pid` is built beside the lock and
# renamed onto it: the rename fails if the lock exists (a non-empty folder on Unix too).
function acquire_lock {
  $tmp = "$LOCK.new.$PID"
  try {
    [void][IO.Directory]::CreateDirectory($tmp)
    [IO.File]::WriteAllText((Join-Path $tmp 'pid'), "$PID`n", $utf8)
    [IO.Directory]::Move($tmp, $LOCK)
    return $true
  } catch { return $false }
  finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
}

$haveLock = $false
$rc = 0
try {
  if (-not (acquire_lock)) {
    $lpid = $null
    $pf = Join-Path $LOCK 'pid'
    if (Test-Path -LiteralPath $pf) { $lpid = (Get-Content -LiteralPath $pf -TotalCount 1 -ErrorAction SilentlyContinue) }
    $dead = $lpid -and -not (Get-Process -Id ([int]($lpid -replace '\D', '0')) -ErrorAction SilentlyContinue)
    $item = Get-Item -LiteralPath $LOCK -Force -ErrorAction SilentlyContinue   # the dot-name is hidden
    $old = $item -and ($item.LastWriteTime -lt (Get-Date).AddMinutes(-120))
    if ($dead -or $old) {
      try { Move-Item -LiteralPath $LOCK -Destination "$LOCK.dead.$PID" -Force -ErrorAction Stop
            Remove-Item -LiteralPath "$LOCK.dead.$PID" -Recurse -Force -ErrorAction SilentlyContinue } catch {}
      logline "took over a stale lock (pid $(if ($lpid) { $lpid } else { 'none' }))"
    }
    if (-not (($dead -or $old) -and (acquire_lock))) {
      logline "auto-import already in progress (lock held by pid $(if ($lpid) { $lpid } else { '?' })); skipping"
      exit 0   # the finally below does not release: $haveLock is still false
    }
  }
  $haveLock = $true

  $NOW = gate_hash
  if ($NOW -and (Test-Path -LiteralPath $GATE) -and (Test-Path -LiteralPath $STATE) `
      -and ((Get-Content -LiteralPath $GATE -TotalCount 1) -ceq $NOW) `
      -and -not ((Get-Content -LiteralPath $STATE -Raw) -match '"pending"\s*:\s*true')) {
    exit 0
  }

  logline 'auto-import start'
  $env:SAMPLETIDY_AUTOIMPORT_INPUT = $WATCH
  $env:SAMPLETIDY_AUTOIMPORT_DB = $DB
  $env:SAMPLETIDY_AUTOIMPORT_REPORT = $REPORT
  # & hands control back even for a .cmd/.bat Rscript. 2>&1 folds stderr in (each line
  # arrives as an ErrorRecord; "$_" is its text) and the writer appends it to the log.
  $w = [IO.StreamWriter]::new([IO.FileStream]::new($LOG, 'Append', 'Write', 'ReadWrite'), $utf8)
  try {
    $ErrorActionPreference = 'Continue'
    & $RSCRIPT (Join-Path $HERE 'auto-import.R') 2>&1 | ForEach-Object { $w.WriteLine("$_") }
    $rc = $LASTEXITCODE
  } finally { $w.Dispose(); $ErrorActionPreference = 'Stop' }
  if ($null -eq $rc) { $rc = 1 }

  if ($rc -eq 0) {
    $NOW = gate_hash
    if ($NOW) {
      $tmpg = "$GATE.tmp.$PID"
      [IO.File]::WriteAllText($tmpg, "$NOW`n", $utf8)
      Move-Item -LiteralPath $tmpg -Destination $GATE -Force
    }
  }
} finally {
  if ($haveLock) { Remove-Item -LiteralPath $LOCK -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $rc
