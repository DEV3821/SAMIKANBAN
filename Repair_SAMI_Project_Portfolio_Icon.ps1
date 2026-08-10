[CmdletBinding()]
param(
  [string]$TeamRoot = $PSScriptRoot,
  [switch]$NoPopup
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'tools\install_sami_kanban_hosted_shortcut.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Hosted shortcut installer not found: $installer" }

try {
  & $installer -NoLaunch
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Hosted shortcut installer exited with code $LASTEXITCODE." }
  $message = 'SAMI Kanban hosted shortcut repaired. No Team ESMI bootstrap or local server was started.'
  Write-Host $message
  if (-not $NoPopup) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($message, 0, 'SAMI Kanban', 64) } catch {}
  }
  exit 0
} catch {
  $message = "SAMI Kanban shortcut repair failed: $($_.Exception.Message)"
  Write-Error $message
  if (-not $NoPopup) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($message, 0, 'SAMI Kanban', 16) } catch {}
  }
  exit 1
}
