[CmdletBinding()]
param(
  [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PowerShellExe = (Get-Command powershell.exe).Source
$CscriptExe = Join-Path $env:SystemRoot 'System32\cscript.exe'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SAMI-legacy-launcher-' + [Guid]::NewGuid().ToString('N'))
$InstallRoot = Join-Path $TempRoot 'installed-app'
$CanonicalRoot = Join-Path $TempRoot 'canonical'
$LocalAppData = Join-Path $TempRoot 'localappdata'
$RuntimeRoot = Join-Path $LocalAppData 'SAMI-Kanban-WorkServer\site'
$ServerPid = 0

function Write-JsonFile {
  param([string]$Path, $Value)
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  return $port
}

function Stop-OwnedServer {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return }
  $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if ($processInfo -and $processInfo.CommandLine -match [Regex]::Escape($TempRoot)) {
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
  }
}

try {
  New-Item -ItemType Directory -Path $InstallRoot, (Join-Path $InstallRoot 'tools'), (Join-Path $CanonicalRoot 'data'), (Join-Path $CanonicalRoot 'project_files'), $LocalAppData -Force | Out-Null

  Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools\launch_sami_portfolio.vbs') -Destination (Join-Path $InstallRoot 'tools\launch_sami_portfolio.vbs') -Force
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools\bootstrap_kanban.ps1') -Destination (Join-Path $InstallRoot 'tools\bootstrap_kanban.ps1') -Force
  foreach ($relative in @('index.html', 'serve_kanban.ps1', 'meeting_pack.ps1', 'data\app_version.json')) {
    $destination = Join-Path $CanonicalRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $destination -Force
  }

  $projects = [ordered]@{
    meta = @{ name = 'Synthetic legacy launcher compatibility'; source = 'isolated-fixture' }
    projects = @(
      @{ id = 'legacy-alpha'; title = 'Legacy Alpha'; status = 'running'; context = 'Synthetic'; lastUpdated = '2026-08-03T10:00:00+09:30' }
    )
  }
  Write-JsonFile -Path (Join-Path $CanonicalRoot 'data\projects.json') -Value $projects
  [System.IO.File]::WriteAllText((Join-Path $CanonicalRoot 'data\card_updates.jsonl'), '', [System.Text.UTF8Encoding]::new($false))

  $port = Get-FreePort
  $oldLocalAppData = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = $LocalAppData
  try {
    $launcher = Join-Path $InstallRoot 'tools\launch_sami_portfolio.vbs'
    $arguments = @('//nologo', $launcher, '-TeamRoot', $CanonicalRoot, '-Port', [string]$port, '-NoBrowser')
    & $CscriptExe @arguments
    if ($LASTEXITCODE -ne 0) { throw "Legacy launcher exited with code $LASTEXITCODE." }

    $url = "http://127.0.0.1:$port"
    $health = $null
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
      Start-Sleep -Milliseconds 250
      try {
        $health = Invoke-RestMethod -Uri "$url/api/health" -TimeoutSec 2
        if ($health.ok) { break }
      } catch { }
    }
    if (-not $health -or -not $health.ok) { throw 'Legacy launcher did not produce a healthy server.' }
    $ServerPid = [int]$health.pid
    if ([string]$health.mode -ne 'team-canonical') { throw "Unexpected runtime mode: $($health.mode)" }
    if (-not ([string]$health.canonicalRoot).Equals([System.IO.Path]::GetFullPath($CanonicalRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Unexpected canonical root: $($health.canonicalRoot)"
    }

    foreach ($relative in @('index.html', 'serve_kanban.ps1', 'meeting_pack.ps1', 'data\app_version.json', 'data\projects.json', 'data\card_updates.jsonl')) {
      if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot $relative) -PathType Leaf)) { throw "Runtime file missing: $relative" }
    }
    $runtimeVersion = (Get-Content -LiteralPath (Join-Path $RuntimeRoot 'data\app_version.json') -Raw | ConvertFrom-Json).version
    $expectedVersion = (Get-Content -LiteralPath (Join-Path $RepoRoot 'data\app_version.json') -Raw | ConvertFrom-Json).version
    if ($runtimeVersion -ne $expectedVersion) { throw "Runtime version did not refresh: $runtimeVersion (expected $expectedVersion)" }

    Write-Output 'LEGACY_LAUNCHER_COMPATIBILITY_OK'
    Write-Output "LEGACY_RUNTIME_MODE=$($health.mode)"
    Write-Output "LEGACY_RUNTIME_VERSION=$runtimeVersion"
  } finally {
    if ($oldLocalAppData) { $env:LOCALAPPDATA = $oldLocalAppData } else { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
  }
} finally {
  Stop-OwnedServer -ProcessId $ServerPid
  if (-not $KeepTemp -and (Test-Path -LiteralPath $TempRoot -PathType Container)) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  } elseif ($KeepTemp) {
    Write-Output "LEGACY_FIXTURE_ROOT=$TempRoot"
  }
}
