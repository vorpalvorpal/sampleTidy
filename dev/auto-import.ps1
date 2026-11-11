#Requires -Version 7
# Auto-import trigger (Windows, PowerShell 7), run every few minutes by Task Scheduler
# (dev/windows/install-task.ps1). Counterpart of auto-import.sh and kept at parity with it:
# the same gate, lock, run-health record, retry, notices and exit codes.
# dev/auto-import.cmd is only a Task Scheduler shim that forwards here.
# Does nothing unless this machine holds the live DB and something under the input
# folder (or the DB file) changed since the last good run. Metadata only (the gate script).
# Gate rules: never skip silently except on an unchanged gate. A listing failure (any
# error while listing the input) logs, notifies once a day and exits 3 before the gate is
# compared; an empty listing never skips; the gate is written after a good run only if the
# listing works and nothing in the input changed (by time) since the run began. The exit
# code is Rscript's, so an rc 3 (the deployment's hooks failed to load) reaches the scheduler.
# Test overrides: SAMPLETIDY_AUTOIMPORT_{DB,INPUT,REPORT,RSCRIPT,LOG,CODE,RUN,GIT,OFF,NOTIFY,
# STALE_HOURS}, SAMPLETIDY_NOTIFY_DESKTOP, SAMPLETIDY_{INPUT_DIR,REPORT_DIR,TIMEZONE} and
# R_ENVIRON_USER (the environ file read).
# Deployment config (process env, then R's user environ file: R_ENVIRON_USER, else
# $HOME\.Renviron, else $R_USER\.Renviron, else Documents\.Renviron): SAMPLETIDY_NOTIFY_COMMAND
# is a single path, run as `<cmd> <title> <message>` for each notification (a .ps1 runs under
# this same pwsh; when unset or missing the desktop notification is shown, a balloon on
# Windows and a log line elsewhere; a non-zero exit is logged only). SAMPLETIDY_NOTIFY_FLUSH is
# run with no arguments once per run, right after the lock is taken (e.g. to resend
# notifications queued while offline); its output goes to the log and its exit status is ignored.
# SAMPLETIDY_GATE_WATCH is a folder whose metadata listing joins the gate hash, so a change
# there alone starts R (whose writer check then decides); unset, the hash is unchanged. A
# listing failure there hashes a fixed line instead: it never exits 3 or notifies.
# Code: main's last commit is checked out detached into SAMPLETIDY_AUTOIMPORT_RUN (default
# %LOCALAPPDATA%\sampleTidy-run) on every run and that copy is run, never this working tree;
# SAMPLETIDY_AUTOIMPORT_CODE runs a given tree instead (tests). It never fetches.
# Lock (R-22.H): the directory $REPORT\.imports.lock holding `pid`, created atomically.
# Run-health record ($REPORT\.imports.health) as in the .sh: it drives retry-after-failure,
# one notice per failed run, a once-per-local-day "no success for N hours" notice, and the
# SAMPLETIDY_AUTOIMPORT_PREV_FAILURE text that appears in status.json problems.
# Arguments: -PrintConfig or --print-config prints the resolved values and exits;
# -RenvironFile <f> reads <f> as the environ file (and gives it to R as R_ENVIRON_USER); any
# other argument is ignored, so a stray one cannot stop the scheduled run.
param([switch]$PrintConfig, [string]$RenvironFile, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$HERE = $PSScriptRoot
if ($RenvironFile) { $env:R_ENVIRON_USER = $RenvironFile }

# env KEY: the variable's value, or $null when unset or empty (empty counts as unset).
function env([string]$Key) { $v = [Environment]::GetEnvironmentVariable($Key); if ($v) { $v } }

# R's user environ file: R_ENVIRON_USER, else $HOME\.Renviron, else $R_USER\.Renviron, else the
# Documents folder (R for Windows' rule; off Windows ~/.Renviron). Read once, no side effects:
# a file that exists but cannot be read leaves $ENVIRON_ERR for the log.
$ENVIRON = env R_ENVIRON_USER
if (-not $ENVIRON) {
  if (env HOME) { $ENVIRON = Join-Path (env HOME) '.Renviron' }
  elseif (env R_USER) { $ENVIRON = Join-Path (env R_USER) '.Renviron' }
  else {
    $folder = if ($IsWindows) { 'MyDocuments' } else { 'UserProfile' }
    $ENVIRON = Join-Path ([Environment]::GetFolderPath($folder)) '.Renviron'
  }
}
$ENVIRON_LINES = @(); $ENVIRON_ERR = $null
if (Test-Path -LiteralPath $ENVIRON -PathType Leaf) {
  try { $ENVIRON_LINES = [IO.File]::ReadAllLines($ENVIRON) } catch { $ENVIRON_ERR = "cannot read the environ file $ENVIRON ($($_.Exception.Message))" }
}
# The environ file as R reads it, once: each KEY=value line has one pair of surrounding ' or "
# removed, then ${VAR}, ${VAR-dflt} (dflt only if VAR is unset) and ${VAR:-dflt} (also if empty)
# expanded, nested and inside quotes too (a quoted dflt loses its quotes). VAR is a key set on an
# earlier line of the file, else the process environment; a bare $VAR and ~ stay literal.
# A line that expands to empty leaves its key unset. CRLF lines are read cleanly.
$ENVIRON_VALS = @{}
function unquote([string]$V) {
  if ($V.Length -ge 2 -and ($V[0] -ceq "'" -or $V[0] -ceq '"') -and $V[-1] -ceq $V[0]) { $V.Substring(1, $V.Length - 2) } else { $V }
}
function expand([string]$S) {
  $out = [Text.StringBuilder]::new(); $i = 0; $n = $S.Length
  while ($i -lt $n) {
    if ($S[$i] -cne '$' -or $i + 1 -ge $n -or $S[$i + 1] -cne '{') { [void]$out.Append($S[$i]); $i++; continue }
    $d = 1; $j = $i + 2
    while ($j -lt $n -and $d -gt 0) {
      if ($S[$j] -ceq '$' -and $j + 1 -lt $n -and $S[$j + 1] -ceq '{') { $d++; $j += 2; continue }
      if ($S[$j] -ceq '}') { $d-- }
      $j++
    }
    if ($d -gt 0) { [void]$out.Append($S[$i]); $i++; continue }   # no closing brace: literal
    $whole = $S.Substring($i, $j - $i); $inner = $S.Substring($i + 2, $j - $i - 3)
    $m = [regex]::Match($inner, '^([A-Za-z_][A-Za-z0-9_]*)(.*)$', 'Singleline')
    if (-not $m.Success) { [void]$out.Append($whole); $i = $j; continue }
    $name = $m.Groups[1].Value; $rest = $m.Groups[2].Value
    $v = if ($ENVIRON_VALS.ContainsKey($name)) { $ENVIRON_VALS[$name] } else { [Environment]::GetEnvironmentVariable($name) }   # $null: unset
    if ($rest -eq '') { if ($null -ne $v) { [void]$out.Append($v) } }
    elseif ($rest.StartsWith(':-') -or $rest.StartsWith('-')) {
      $colon = $rest.StartsWith(':-')
      if ($null -eq $v -or ($colon -and $v -eq '')) { [void]$out.Append((expand (unquote $rest.Substring($(if ($colon) { 2 } else { 1 }))))) }
      else { [void]$out.Append($v) }
    } else { [void]$out.Append($whole) }
    $i = $j
  }
  $out.ToString()
}
foreach ($l in $ENVIRON_LINES) {
  $l = $l.TrimEnd("`r")
  $eq = $l.IndexOf('=')
  if ($l.StartsWith('#') -or $eq -lt 1) { continue }
  $v = expand (unquote $l.Substring($eq + 1))
  $ENVIRON_VALS[$l.Substring(0, $eq)] = if ($v -eq '') { $null } else { $v }
}
# renviron_get KEY: the value R gives KEY from the file ($null when unset).
function renviron_get([string]$Key) { if ($ENVIRON_VALS.ContainsKey($Key)) { $ENVIRON_VALS[$Key] } }
# cfg KEY: the process environment, then R's environ file ($null when neither has it).
function cfg([string]$Key) { $v = env $Key; if (-not $v) { $v = renviron_get $Key }; if ($v) { $v } }

# $WATCH holds INPUT (a variable named $INPUT would collide with PowerShell's automatic $input).
# Deployment values, resolved with no side effects: the SAMPLETIDY_AUTOIMPORT_* test
# override, then the process environment, then R's user environ file, then a default.
$LAD = env LOCALAPPDATA
$DB = env SAMPLETIDY_AUTOIMPORT_DB
if (-not $DB) { $DB = Join-Path $LAD 'R\data\R\sampleTidy\monitoring.duckdb' }
$WATCH = env SAMPLETIDY_AUTOIMPORT_INPUT
if (-not $WATCH) {
  $WATCH = cfg SAMPLETIDY_INPUT_DIR
  # batches arrive beside a folder named input, so watch its parent
  if ($WATCH) {
    $t = $WATCH.TrimEnd('\', '/')
    if ((Split-Path -Leaf $t) -ceq 'input') { $WATCH = Split-Path -Parent $t }
  }
}
$REPORT = env SAMPLETIDY_AUTOIMPORT_REPORT
if (-not $REPORT) { $REPORT = cfg SAMPLETIDY_REPORT_DIR }
if (-not $REPORT) { $REPORT = Join-Path $LAD 'R\data\R\sampleTidy\reports' }
$ZONE = cfg SAMPLETIDY_TIMEZONE
if (-not $ZONE) { $ZONE = 'UTC' }
$NOTIFY = env SAMPLETIDY_AUTOIMPORT_NOTIFY   # test override, then deployment config
if (-not $NOTIFY) { $NOTIFY = cfg SAMPLETIDY_NOTIFY_COMMAND }
$FLUSH = cfg SAMPLETIDY_NOTIFY_FLUSH
$GWATCH = cfg SAMPLETIDY_GATE_WATCH
$LOG = env SAMPLETIDY_AUTOIMPORT_LOG
if (-not $LOG) { $LOG = Join-Path $LAD 'sampleTidy\autoimport.log' }
$RSCRIPT = env SAMPLETIDY_AUTOIMPORT_RSCRIPT
if (-not $RSCRIPT) { $RSCRIPT = 'Rscript' }
$OFF = env SAMPLETIDY_AUTOIMPORT_OFF
if (-not $OFF) { $OFF = Join-Path $HOME '.sampletidy-autoimport-off' }
$STALE_HOURS = env SAMPLETIDY_AUTOIMPORT_STALE_HOURS
if (-not $STALE_HOURS) { $STALE_HOURS = '24' }

if ($PrintConfig -or $Rest -contains '--print-config') {
  "DB=$DB"; "INPUT=$WATCH"; "REPORT=$REPORT"; "TIMEZONE=$ZONE"; "LOG=$LOG"
  "NOTIFY=$NOTIFY"; "NOTIFY_FLUSH=$FLUSH"; "WATCH=$GWATCH"
  exit 0
}

if (-not (Test-Path -LiteralPath $DB -PathType Leaf)) { exit 0 }   # not the writer machine
# Off switch: a regular file (agents append a line each) pauses auto-import; remove it to resume.
if (Test-Path -LiteralPath $OFF -PathType Leaf) { exit 0 }

$utf8 = [Text.UTF8Encoding]::new($false)                           # UTF-8, no BOM
[void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($LOG))))
function logline([string]$Msg) {
  [IO.File]::AppendAllText($LOG, "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg`n", $utf8)
}
if ($ENVIRON_ERR) { logline $ENVIRON_ERR }
if (-not $WATCH -or -not (Test-Path -LiteralPath $WATCH -PathType Container)) {
  logline "input folder not found: $WATCH"; exit 0
}
$STATE = Join-Path $REPORT '.imports.state'; $GATE = Join-Path $REPORT '.imports.gate'
$LOCK = Join-Path $REPORT '.imports.lock'; $HEALTH = Join-Path $REPORT '.imports.health'
$NOTIFIED = Join-Path $REPORT '.imports.notified'
[void][IO.Directory]::CreateDirectory($REPORT)

# The local day (SAMPLETIDY_TIMEZONE, an IANA id; an unknown one falls back to the machine's zone).
function local_day {
  $zone = $null
  try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($ZONE) } catch {}
  if (-not $zone) { $zone = [TimeZoneInfo]::Local }
  [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $zone).ToString('yyyy-MM-dd')
}

# Run an external command with arguments; a .ps1 runs as a child of this same pwsh. Returns
# its exit code and leaves its output (stdout and stderr, as text lines) in $script:cmd_out.
# Throws when it cannot be started (e.g. not executable).
function run_cmd([string]$Cmd, [string[]]$CmdArgs) {
  $script:cmd_out = @()
  $ErrorActionPreference = 'Continue'
  try {
    if ($Cmd -like '*.ps1') {
      $script:cmd_out = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $Cmd @CmdArgs 2>&1 | ForEach-Object { "$_" })
    } else {
      $script:cmd_out = @(& $Cmd @CmdArgs 2>&1 | ForEach-Object { "$_" })
    }
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = 'Stop' }
}

function desktop_notice([string]$Title, [string]$Message) {
  $prog = env SAMPLETIDY_NOTIFY_DESKTOP
  try {
    if ($prog) {
      [void](run_cmd $prog @($Title, $Message))
    } elseif ($IsWindows) {
      Add-Type -AssemblyName System.Windows.Forms, System.Drawing
      $n = [Windows.Forms.NotifyIcon]::new()
      try {
        $n.Icon = [Drawing.SystemIcons]::Information; $n.Visible = $true
        $n.ShowBalloonTip(10000, $Title, $Message, [Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 5   # the balloon goes with its icon
      } finally { $n.Dispose() }
    } else {
      logline "notice: $Title`: $Message"
    }
  } catch { logline "desktop notice failed: $($_.Exception.Message)" }
}

function notify([string]$Title, [string]$Message) {
  if ($NOTIFY) {
    if (Test-Path -LiteralPath $NOTIFY -PathType Leaf) {
      $nrc = $null
      try { $nrc = run_cmd $NOTIFY @($Title, $Message) } catch { logline "notify command not executable: $NOTIFY" }
      if ($null -ne $nrc) {
        if ($nrc -ne 0) { logline "notify command exited $nrc" }
        return
      }
    } else { logline "notify command not found: $NOTIFY" }
  }
  desktop_notice $Title $Message
}
# Notify once per key (kept in $NOTIFIED).
function notify_once([string]$Key, [string]$Title, [string]$Message) {
  if ((Test-Path -LiteralPath $NOTIFIED -PathType Leaf) -and ([IO.File]::ReadAllLines($NOTIFIED) -ccontains $Key)) { return }
  [IO.File]::AppendAllText($NOTIFIED, "$Key`n", $utf8)
  notify $Title $Message
}

# The health record is read by pattern, as the .sh does, so a hand-edited or R-written file
# still reads. A value that is not what the key holds (a number, a UTC time) is no value.
function jget([string]$Key) {
  $m = [regex]::Match($script:healthText, '"' + $Key + '"\s*:\s*"?([^",}]*)"?')
  if ($m.Success) { $m.Groups[1].Value } else { '' }
}
function utc_time([string]$S) {
  $t = [DateTime]::MinValue
  if ([DateTime]::TryParseExact($S, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t)) { $t }
}
function utc_stamp { [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
# write_health <state> <started> <ended|''> <rc|''> <last_success|''>, by temp file and rename
function write_health([string]$State, [string]$Started, [string]$Ended, [string]$HRc, [string]$Succ) {
  $q = { param($v) if ($v -and $v -ne 'null') { '"' + $v + '"' } else { 'null' } }
  $json = '{{"state":"{0}","pid":{1},"started_at":{2},"ended_at":{3},"rc":{4},"last_success_at":{5}}}' -f `
    $State, $PID, (& $q $Started), (& $q $Ended), $(if ($HRc) { $HRc } else { 'null' }), (& $q $Succ)
  $tmp = "$HEALTH.tmp.$PID"
  [IO.File]::WriteAllText($tmp, "$json`n", $utf8)
  Move-Item -LiteralPath $tmp -Destination $HEALTH -Force
}

# A listing of the folder, to depth 2, as the .sh's find does: an error while listing is a
# failure (a partial listing must not match the gate), and .DS_Store is ignored.
function list_tree([string]$Path) {
  $err = $null
  $items = @(Get-ChildItem -LiteralPath $Path -Force -Depth 1 -ErrorAction SilentlyContinue -ErrorVariable err |
    Where-Object { $_.Name -ne '.DS_Store' })
  [pscustomobject]@{ Items = $items; Failed = [bool]$err; Error = $(if ($err) { "$($err[0])" } else { '' }) }
}
# Is anything in the folder (depth 2) created or changed after $Since? (Unlistable: no.)
function changed_since([string]$Path, [DateTime]$Since) {
  foreach ($i in (list_tree $Path).Items) {
    if ($i.LastWriteTimeUtc -gt $Since -or $i.CreationTimeUtc -gt $Since) { return $true }
  }
  $false
}

function gate_hash {
  $a = @{ Input = $WATCH; Db = $DB; TimeZone = $ZONE }
  if ($GWATCH) { $a.Watch = $GWATCH }
  (& (Join-Path $HERE 'auto-import-gate.ps1') @a | Out-String).Trim()
}

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
    # The lock's pid, or $null when its first line is not a number (never read as pid 0).
    $lpid = $null
    $pf = Join-Path $LOCK 'pid'
    if (Test-Path -LiteralPath $pf -PathType Leaf) {
      $first = Get-Content -LiteralPath $pf -TotalCount 1 -ErrorAction SilentlyContinue
      $n = 0
      if ($first -and [int]::TryParse($first.Trim(), [ref]$n) -and $n -gt 0) { $lpid = $n }
    }
    $dead = $lpid -and -not (Get-Process -Id $lpid -ErrorAction SilentlyContinue)
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

  # Flush command (deployment config): once per run, before the health record is read.
  if ($FLUSH) {
    if (Test-Path -LiteralPath $FLUSH -PathType Leaf) {
      try {
        [void](run_cmd $FLUSH @())
        foreach ($l in $script:cmd_out) { [IO.File]::AppendAllText($LOG, "$l`n", $utf8) }
      } catch { logline "flush command not executable: $FLUSH" }
    } else { logline "flush command not found: $FLUSH" }
  }

  # Previous run (R-22.H): a record still "running" while we hold the lock is a crash; a
  # non-zero rc is a failure. Either retries past the gate and is notified once per failed
  # started_at; the text goes to R for the status note.
  $env:SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = ''
  $script:healthText = if (Test-Path -LiteralPath $HEALTH -PathType Leaf) { try { [IO.File]::ReadAllText($HEALTH) } catch { '' } } else { '' }
  $pState = jget state; $pRc = jget rc; $pStart = jget started_at; $pSucc = jget last_success_at
  if (-not (utc_time $pSucc)) { $pSucc = '' }
  if ($pRc -notmatch '^-?\d+$') { $pRc = '' }
  $retry = $false
  if ($pState -ceq 'running') {
    $env:SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = "The import started $pStart did not finish"; $retry = $true
  } elseif ($pState -ceq 'done' -and $pRc -and $pRc -ne '0') {
    $env:SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = "The import started $pStart failed (rc $pRc)"; $retry = $true
  }
  if ($retry) { notify_once "fail:$pStart" 'sampleTidy import failed' "$($env:SAMPLETIDY_AUTOIMPORT_PREV_FAILURE); retrying" }
  # Staleness: no success for STALE_HOURS, once per local day (SAMPLETIDY_TIMEZONE), even if the gate skips.
  if ($pSucc -and (([DateTime]::UtcNow - (utc_time $pSucc)).TotalSeconds -gt ([double]$STALE_HOURS * 3600))) {
    notify_once "stale:$(local_day)" 'sampleTidy import stale' "No successful import since $pSucc (over $STALE_HOURS hours)"
  }

  # The marker for the re-check: anything newer arrived (or changed) during the run.
  $marker = [DateTime]::UtcNow
  $inList = list_tree $WATCH
  if ($inList.Failed) {
    logline "cannot list ${WATCH}: $($inList.Error)"
    notify_once "listfail:$(local_day)" 'sampleTidy import cannot read its input' `
      "The input folder cannot be listed ($WATCH). Check its permissions (on macOS the launcher may need Full Disk Access)."
    exit 3
  }
  $NOW = gate_hash
  $empty = ($inList.Items.Count -eq 0)
  if ($empty) { logline "input listing is empty ($WATCH); running anyway" }
  if (-not $retry -and -not $empty -and $NOW -and (Test-Path -LiteralPath $GATE) -and (Test-Path -LiteralPath $STATE) `
      -and ((Get-Content -LiteralPath $GATE -TotalCount 1) -ceq $NOW) `
      -and -not ((Get-Content -LiteralPath $STATE -Raw) -match '"pending"\s*:\s*true')) {
    exit 0
  }

  # Run the last commit on main, never the working tree: a development session's uncommitted
  # edits must not reach the live DB. A detached worktree outside the repo is moved to main's
  # commit on every run (no fetch: what is on this machine's main is what runs). CODE overrides.
  $RUN = env SAMPLETIDY_AUTOIMPORT_CODE
  $short = $null
  if (-not $RUN) {
    $GIT = env SAMPLETIDY_AUTOIMPORT_GIT
    if (-not $GIT) { $GIT = 'git' }
    $REPO = Split-Path -Parent $HERE
    $RUN = env SAMPLETIDY_AUTOIMPORT_RUN
    if (-not $RUN) { $RUN = Join-Path $LAD 'sampleTidy-run' }
    $ok = $false
    try {
      $ErrorActionPreference = 'Continue'
      $sha = @(& $GIT -C $REPO rev-parse --verify -q 'main^{commit}' 2>$null)
      if ($LASTEXITCODE -eq 0 -and $sha) {
        if (Test-Path -LiteralPath (Join-Path $RUN '.git')) {
          $out = @(& $GIT -C $RUN checkout -q --detach $sha[0] 2>&1)
        } else {
          $out = @(& $GIT -C $REPO worktree prune 2>&1)
          $out += @(& $GIT -C $REPO worktree add -q --detach $RUN main 2>&1)
        }
        $ok = ($LASTEXITCODE -eq 0)
        foreach ($l in $out) { [IO.File]::AppendAllText($LOG, "$l`n", $utf8) }
        if ($ok) { $short = "$(& $GIT -C $RUN rev-parse --short HEAD 2>$null)" }
      }
    } catch { $ok = $false } finally { $ErrorActionPreference = 'Stop' }
    if (-not $ok) { logline "could not prepare $RUN"; exit 1 }
  }
  $startedAt = utc_stamp
  write_health 'running' $startedAt '' '' $pSucc
  logline "auto-import start ($(if ($short) { $short } else { $RUN }))"
  $env:SAMPLETIDY_AUTOIMPORT_INPUT = $WATCH
  $env:SAMPLETIDY_AUTOIMPORT_DB = $DB
  $env:SAMPLETIDY_AUTOIMPORT_REPORT = $REPORT
  # & hands control back even for a .cmd/.bat Rscript. 2>&1 folds stderr in (each line
  # arrives as an ErrorRecord; "$_" is its text) and the writer appends it to the log.
  $w = [IO.StreamWriter]::new([IO.FileStream]::new($LOG, 'Append', 'Write', 'ReadWrite'), $utf8)
  try {
    $ErrorActionPreference = 'Continue'
    & $RSCRIPT (Join-Path (Join-Path $RUN 'dev') 'auto-import.R') 2>&1 | ForEach-Object { $w.WriteLine("$_") }
    $rc = $LASTEXITCODE
  } catch {   # e.g. RSCRIPT not found: log it (a scheduled task's stderr goes nowhere)
    $w.WriteLine("could not run ${RSCRIPT}: $_"); $rc = 1
  } finally { $w.Dispose(); $ErrorActionPreference = 'Stop' }
  if ($null -eq $rc) { $rc = 1 }
  $ended = utc_stamp
  $succ = if ($rc -eq 0) { $ended } else { $pSucc }
  write_health 'done' $startedAt $ended "$rc" $succ

  if ($rc -eq 0) {
    # Post-run gate: only if the listing works and nothing changed (by time) in the input, or
    # the watch folder when set, since the marker. Otherwise leave it stale so the next tick runs.
    $post = $null
    if (-not (list_tree $WATCH).Failed) { $post = gate_hash }
    if ($post -and -not (changed_since $WATCH $marker) -and (-not $GWATCH -or -not (changed_since $GWATCH $marker))) {
      $tmpg = "$GATE.tmp.$PID"
      [IO.File]::WriteAllText($tmpg, "$post`n", $utf8)
      Move-Item -LiteralPath $tmpg -Destination $GATE -Force
    } else {
      logline 'input changed during the run; next tick will re-check'
    }
  }
} finally {
  if ($haveLock) { Remove-Item -LiteralPath $LOCK -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $rc
