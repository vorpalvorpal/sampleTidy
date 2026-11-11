#Requires -Version 7
# Registers the Windows auto-import trigger (dev/auto-import.ps1 of THIS checkout) as a
# scheduled task. No admin rights are needed: the task is this user's own and runs only while
# they are logged on.
#   install-task.ps1 [-Print] [-Uninstall] [-Launcher conhost|none] [-Name <n>] [-RenvironFile <f>]
#                    [-Script <p>] [-Interval <minutes>] [-TimeLimit <ISO 8601 duration>]
# -Print writes the task XML to stdout and touches nothing. -Uninstall deletes the task. The
# task runs every 10 minutes and at logon (StartWhenAvailable catches up a missed tick); a run
# that is still going when the next is due makes that one a no-op (IgnoreNew).
# -Launcher conhost (default) starts pwsh through `conhost.exe --headless`, so no console
# window flashes every 10 minutes (a hidden task still shows one for a console program);
# -Launcher none starts pwsh directly. -Name is the task name (default sampleTidy-autoimport);
# a second task with another name and -RenvironFile <f> runs against a separate environ file.
# -Script <p> registers another PowerShell script instead (it must exist; another package's job),
# -Interval <minutes> is the repeat (default 10) and -TimeLimit the longest a run may take, as an
# ISO 8601 duration such as PT30M or PT2H (default PT4H). A bad value stops it before anything is written.
# The task never fetches code: auto-import.ps1 runs the main branch of the checkout it lives in.
# Registration goes through schtasks.exe (SAMPLETIDY_SCHTASKS names another program, for tests).
# The task's WorkingDirectory is the report folder's parent: R reads a .Renviron from its
# working directory, so it must be a folder that holds none.
param(
  [switch]$Print,
  [switch]$Uninstall,
  [ValidateSet('conhost', 'none')][string]$Launcher = 'conhost',
  [string]$Name = 'sampleTidy-autoimport',
  [string]$RenvironFile,
  [string]$Script,
  [string]$Interval = '10',
  [string]$TimeLimit = 'PT4H'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$SCH = [Environment]::GetEnvironmentVariable('SAMPLETIDY_SCHTASKS')
if (-not $SCH) { $SCH = 'schtasks.exe' }

# schtasks <args...>: run it, show what it said, and stop with its exit code when it fails.
function schtasks([string[]]$SchArgs) {
  $out = @(& $SCH @SchArgs 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    [Console]::Error.WriteLine(($out -join "`n"))
    exit $code
  }
  $out
}

if ($Uninstall) {
  schtasks @('/delete', '/tn', $Name, '/f')
  return
}

# Refuse bad values before anything is built or registered.
function refuse([string]$Why) { [Console]::Error.WriteLine("install-task.ps1: $Why"); exit 2 }
if ($Interval -notmatch '^[0-9]+$' -or [int64]$Interval -lt 1) { refuse "-Interval must be a whole number of minutes, 1 or more (got '$Interval')" }
if ($TimeLimit -notmatch '^P(?=[0-9]|T[0-9])([0-9]+D)?(T(?=[0-9])([0-9]+H)?([0-9]+M)?([0-9]+S)?)?$') { refuse "-TimeLimit must be an ISO 8601 duration such as PT30M or PT2H (got '$TimeLimit')" }

# The task's pieces, all absolute. The checkout is two folders up from this script (dev\windows).
$checkout = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($PSBoundParameters.ContainsKey('Script')) {
  if (-not $Script -or -not (Test-Path -LiteralPath $Script -PathType Leaf)) { refuse "-Script not found: $Script" }
  $trigger = [IO.Path]::GetFullPath($Script)
  $what = "scheduled job $([IO.Path]::GetFileName($trigger))"
} else {
  $trigger = Join-Path (Join-Path $checkout 'dev') 'auto-import.ps1'
  $what = 'sampleTidy auto-import trigger: imports new input files when something changed.'
}
$pwsh = $null
if ($IsWindows) {   # the Store alias path is stable across updates; ProcessPath is versioned
  $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { $pwsh = $cmd.Source }
}
if (-not $pwsh) { $pwsh = [Environment]::ProcessPath }
$user = if ($IsWindows) { [Security.Principal.WindowsIdentity]::GetCurrent().Name } else { [Environment]::UserName }

# The report folder (SAMPLETIDY_REPORT_DIR, else the environ file, else the default), as the trigger finds it.
function env_or_file([string]$Key) {
  $v = [Environment]::GetEnvironmentVariable($Key)
  if ($v) { return $v }
  $f = $RenvironFile
  if (-not $f) { $f = [Environment]::GetEnvironmentVariable('R_ENVIRON_USER') }
  if (-not $f) {
    $h = [Environment]::GetEnvironmentVariable('HOME'); $ru = [Environment]::GetEnvironmentVariable('R_USER')
    $dir = if ($h) { $h } elseif ($ru) { $ru } else { [Environment]::GetFolderPath($(if ($IsWindows) { 'MyDocuments' } else { 'UserProfile' })) }
    $f = Join-Path $dir '.Renviron'
  }
  if (Test-Path -LiteralPath $f -PathType Leaf) {
    foreach ($l in [IO.File]::ReadAllLines($f)) {
      $l = $l.TrimEnd("`r")
      if ($l.StartsWith("$Key=", [StringComparison]::Ordinal)) { $v = $l.Substring($Key.Length + 1) }
    }
    if ($v -and $v.Length -ge 2 -and ($v[0] -ceq "'" -or $v[0] -ceq '"') -and $v[-1] -ceq $v[0]) { $v = $v.Substring(1, $v.Length - 2) }
  }
  $v
}
$report = env_or_file 'SAMPLETIDY_REPORT_DIR'
if (-not $report) { $report = Join-Path ([Environment]::GetEnvironmentVariable('LOCALAPPDATA')) 'R\data\R\sampleTidy\reports' }
$workdir = Split-Path -Parent ([IO.Path]::GetFullPath($report).TrimEnd('\', '/'))

$psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$trigger`""
if ($RenvironFile) { $psArgs += " -RenvironFile `"$RenvironFile`"" }
if ($Launcher -eq 'conhost') { $command = 'conhost.exe'; $arguments = "--headless `"$pwsh`" $psArgs" }
else { $command = $pwsh; $arguments = $psArgs }

function x([string]$S) { [Security.SecurityElement]::Escape($S) }
$start = (Get-Date).AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss")
$xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(x $what)</Description>
    <URI>\$(x $Name)</URI>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT$($Interval)M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(x $user)</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(x $user)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$(x $TimeLimit)</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(x $command)</Command>
      <Arguments>$(x $arguments)</Arguments>
      <WorkingDirectory>$(x $workdir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

if ($Print) { $xml; return }

# schtasks wants the file's declared encoding to match its bytes: UTF-8, no BOM.
$file = [IO.Path]::GetTempFileName()
try {
  [IO.File]::WriteAllText($file, $xml, [Text.UTF8Encoding]::new($false))
  schtasks @('/create', '/xml', $file, '/tn', $Name, '/f')
} finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
