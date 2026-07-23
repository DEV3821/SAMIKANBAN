[CmdletBinding()]
param(
  [string]$TeamRoot = $PSScriptRoot,
  [switch]$NoPopup
)

$ErrorActionPreference = 'Stop'
$productName = 'SAMI Project Portfolio'
$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
$cacheRoot = Join-Path $localBase 'launcher-cache'
$localIconRoot = Join-Path $localBase 'assets'
$logsRoot = Join-Path $localBase 'logs'
$logPath = Join-Path $logsRoot 'icon_repair.log'

function Write-RepairLog {
  param([string]$Message)
  Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

try {
  $TeamRoot = [System.IO.Path]::GetFullPath($TeamRoot).TrimEnd('\')
  $iconSource = Join-Path $TeamRoot 'assets\sami_project_portfolio_v2.ico'
  $bootstrapSource = Join-Path $TeamRoot 'tools\bootstrap_kanban.ps1'
  $serverSource = Join-Path $TeamRoot 'serve_kanban.ps1'
  foreach ($required in @($iconSource, $bootstrapSource, $serverSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required Team file is missing: $required" }
  }

  New-Item -ItemType Directory -Path $cacheRoot, (Join-Path $cacheRoot 'assets'), (Join-Path $cacheRoot 'tools'), $localIconRoot, $logsRoot -Force | Out-Null
  Write-RepairLog '=================================================='
  Write-RepairLog "Icon repair started from Team root: $TeamRoot"

  $stableIcon = Join-Path $localIconRoot 'sami_project_portfolio_v2.ico'
  Copy-Item -LiteralPath $iconSource -Destination $stableIcon -Force
  Copy-Item -LiteralPath $iconSource -Destination (Join-Path $cacheRoot 'assets\sami_project_portfolio_v2.ico') -Force
  Copy-Item -LiteralPath $iconSource -Destination (Join-Path $cacheRoot 'assets\sami_project_portfolio.ico') -Force
  Copy-Item -LiteralPath $bootstrapSource -Destination (Join-Path $cacheRoot 'tools\bootstrap_kanban.ps1') -Force
  Copy-Item -LiteralPath $serverSource -Destination (Join-Path $cacheRoot 'serve_kanban.ps1') -Force

  $desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  if ([string]::IsNullOrWhiteSpace($desktopRoot)) { $desktopRoot = Join-Path $env:USERPROFILE 'Desktop' }
  $programsRoot = [Environment]::GetFolderPath('Programs')
  $shortcutPaths = @(
    (Join-Path $desktopRoot "$productName.lnk"),
    (Join-Path $programsRoot "$productName.lnk")
  )
  $desiredIcon = "$stableIcon,0"
  $updated = 0
  $shell = New-Object -ComObject WScript.Shell
  try {
    foreach ($shortcutPath in $shortcutPaths) {
      if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        Write-RepairLog "Shortcut not found; skipped: $shortcutPath"
        continue
      }
      $shortcut = $shell.CreateShortcut($shortcutPath)
      $shortcut.IconLocation = $desiredIcon
      $shortcut.Save()
      $updated++
      Write-RepairLog "Shortcut icon updated: $shortcutPath -> $desiredIcon"
    }
  } finally {
    if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
  }

  $refreshTool = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
  if (Test-Path -LiteralPath $refreshTool -PathType Leaf) {
    Start-Process -FilePath $refreshTool -ArgumentList '-show' -WindowStyle Hidden -ErrorAction SilentlyContinue
  }

  $message = "$productName icon repaired. Updated $updated shortcut(s). No reinstall was required."
  Write-RepairLog $message
  Write-Host $message
  if (-not $NoPopup) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($message, 0, $productName, 64) } catch {}
  }
  exit 0
} catch {
  $message = "$productName icon repair failed: $($_.Exception.Message)"
  try { Write-RepairLog $message } catch {}
  Write-Error $message
  if (-not $NoPopup) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($message, 0, $productName, 16) } catch {}
  }
  exit 1
}
