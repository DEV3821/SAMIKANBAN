[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$productName = 'SAMI Project Portfolio'
$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
$desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktopRoot)) { $desktopRoot = Join-Path $env:USERPROFILE 'Desktop' }
$programsRoot = [Environment]::GetFolderPath('Programs')

try {
  foreach ($shortcut in @((Join-Path $desktopRoot "$productName.lnk"), (Join-Path $programsRoot "$productName.lnk"))) {
    if (Test-Path -LiteralPath $shortcut -PathType Leaf) { Remove-Item -LiteralPath $shortcut -Force }
  }
  foreach ($path in @((Join-Path $localBase 'Launch SAMI Project Portfolio.vbs'), (Join-Path $localBase 'launcher-cache'))) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  }
  Write-Host 'SAMI Project Portfolio shortcuts and launcher cache were removed.'
  Write-Host 'Runtime data and logs were preserved.'
  exit 0
} catch {
  [Console]::Error.WriteLine("Uninstall failed: $($_.Exception.Message)")
  exit 1
}
