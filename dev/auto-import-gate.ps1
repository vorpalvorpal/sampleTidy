# Metadata-only gate for auto-import.cmd. Prints a hash of input_dir (depth 2) + DB size/mtime
# + the Sydney date (ruling R14: the first tick of each Sydney day passes the gate).
# $Input is PowerShell's automatic pipeline variable, so the parameter is $InputDir
# (still passed as -Input by auto-import.cmd).
param([Alias('Input')][string]$InputDir, [string]$Db)
$lines = Get-ChildItem -LiteralPath $InputDir -Force -Depth 1 -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne '.DS_Store' } |
  ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($InputDir.Length), $(if ($_.PSIsContainer) {0} else {$_.Length}), $_.LastWriteTimeUtc.Ticks } |
  Sort-Object { $_ } -CaseSensitive
$d = Get-Item -LiteralPath $Db
$syd = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'AUS Eastern Standard Time').ToString('yyyy-MM-dd')
$text = ($lines -join "`n") + "`nDB|$($d.Length)|$($d.LastWriteTimeUtc.Ticks)" + "`n$syd"
$sha = [Security.Cryptography.SHA256]::Create()
([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLower()
