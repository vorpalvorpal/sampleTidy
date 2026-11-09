# Metadata-only gate for auto-import.ps1. Prints a hash of input_dir (depth 2) + DB size/mtime
# + the local date in -TimeZone (ruling R14: the first tick of each local day passes the gate).
# $Input is PowerShell's automatic pipeline variable, so the parameter is $InputDir
# (still passed as -Input by auto-import.ps1).
# -Watch (optional): a folder whose listing (depth 2: name, creation and write times) is hashed
# last, or the fixed line `WATCH|unlistable` when it cannot be listed. Without it the hash is
# as before.
param([Alias('Input')][string]$InputDir, [string]$Db, [string]$TimeZone, [string]$Watch)
$lines = Get-ChildItem -LiteralPath $InputDir -Force -Depth 1 -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne '.DS_Store' } |
  ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($InputDir.Length), $(if ($_.PSIsContainer) {0} else {$_.Length}), $_.LastWriteTimeUtc.Ticks } |
  Sort-Object { $_ } -CaseSensitive
$d = Get-Item -LiteralPath $Db
# The zone is an IANA id (empty means UTC). Windows PowerShell 5.1 cannot resolve one, so it
# uses the machine's local zone; .NET 6+ (pwsh 7) converts the id first.
if (-not $TimeZone) { $TimeZone = 'UTC' }
$zone = $null
try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) } catch {}
if (-not $zone -and [TimeZoneInfo].GetMethod('TryConvertIanaIdToWindowsId')) {
  $win = $null
  if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($TimeZone, [ref]$win)) {
    try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($win) } catch {}
  }
}
if (-not $zone) { $zone = [TimeZoneInfo]::Local }
$day = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $zone).ToString('yyyy-MM-dd')
$text = ($lines -join "`n") + "`nDB|$($d.Length)|$($d.LastWriteTimeUtc.Ticks)" + "`n$day"
if ($Watch) {
  $werr = $null
  $wl = @()
  if (Test-Path -LiteralPath $Watch -PathType Container) {
    $wl = Get-ChildItem -LiteralPath $Watch -Force -Depth 1 -ErrorAction SilentlyContinue -ErrorVariable werr |
      Where-Object { $_.Name -ne '.DS_Store' } |
      ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($Watch.Length), $_.CreationTimeUtc.Ticks, $_.LastWriteTimeUtc.Ticks } |
      Sort-Object { $_ } -CaseSensitive
  } else { $werr = 'missing' }
  $text += "`n" + $(if ($werr) { 'WATCH|unlistable' } else { $wl -join "`n" })
}
$sha = [Security.Cryptography.SHA256]::Create()
([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLower()
