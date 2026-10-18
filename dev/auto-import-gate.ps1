# Metadata-only gate for auto-import.cmd. Prints a hash of input_dir (depth 2) + DB size/mtime.
param([string]$Input, [string]$Db)
$lines = Get-ChildItem -LiteralPath $Input -Force -Depth 1 -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne '.DS_Store' } |
  ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($Input.Length), $(if ($_.PSIsContainer) {0} else {$_.Length}), $_.LastWriteTimeUtc.Ticks } |
  Sort-Object { $_ } -CaseSensitive
$d = Get-Item -LiteralPath $Db
$text = ($lines -join "`n") + "`nDB|$($d.Length)|$($d.LastWriteTimeUtc.Ticks)"
$sha = [Security.Cryptography.SHA256]::Create()
([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLower()
