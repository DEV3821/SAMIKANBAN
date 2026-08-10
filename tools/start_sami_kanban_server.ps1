[CmdletBinding()]
param(
  [string]$InstallRoot = 'C:\SAMI_KANBAN',
  [int]$Port = 8788
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$appRoot = Join-Path $root 'app'
$logRoot = Join-Path $root 'logs'
$serverScript = Join-Path $appRoot 'serve_kanban.ps1'
$startLog = Join-Path $logRoot 'kanban_start.log'
$mutex = $null
$ownsMutex = $false

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Write-StartLog {
  param([string]$Message)
  Add-Content -LiteralPath $startLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

try {
  if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    throw "Kanban server script is missing: $serverScript"
  }

  $mutex = New-Object System.Threading.Mutex($false, 'Global\SAMI_KANBAN_SERVER', [ref]$ownsMutex)
  if (-not $ownsMutex) {
    Write-StartLog 'A SAMI Kanban server instance already owns the global mutex; exiting.'
    exit 0
  }

  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Write-StartLog "Starting local-authoritative Kanban: root=$root app=$appRoot port=$Port"
  & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $serverScript `
    -Root $appRoot `
    -SourceRoot $appRoot `
    -CanonicalRoot $root `
    -LocalMirrorRoot $appRoot `
    -RuntimeMode team-canonical `
    -Port $Port `
    -BindAddress '0.0.0.0' `
    -LogPath (Join-Path $logRoot 'kanban_server.log')
  $exitCode = $LASTEXITCODE
  Write-StartLog "Kanban server exited with code $exitCode"
  exit $exitCode
} catch {
  Write-StartLog "START ERROR: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
  exit 1
} finally {
  if ($mutex -and $ownsMutex) {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
  }
}
