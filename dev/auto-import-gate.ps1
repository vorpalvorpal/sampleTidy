# Metadata-only gate for auto-import.cmd. Prints a hash of input_dir (depth 2) + DB size/mtime
# + the local date in -TimeZone (ruling R14: the first tick of each local day passes the gate).
# $Input is PowerShell's automatic pipeline variable, so the parameter is $InputDir
# (still passed as -Input by auto-import.cmd).
param([Alias('Input')][string]$InputDir, [string]$Db, [string]$TimeZone)
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
$sha = [Security.Cryptography.SHA256]::Create()
([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLower()
