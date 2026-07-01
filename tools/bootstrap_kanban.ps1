[CmdletBinding()]
param(
  [string]$TeamRoot,
  [int]$Port = 8011,
  [switch]$NoBrowser,
  [switch]$AllowLocalFallback
)

$ErrorActionPreference = 'Stop'
$ProductName = 'SAMI Project Portfolio'
$Url = "http://127.0.0.1:$Port"
$HealthUrl = "$Url/api/health"
$DefaultCanonicalRoot = '\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer'
$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
$runtimeRoot = Join-Path $localBase 'site'
$logsRoot = Join-Path $localBase 'logs'
$pidPath = Join-Path $localBase 'kanban_server.pid'
$bootstrapLog = Join-Path $logsRoot 'bootstrap_kanban.log'
$serverLog = Join-Path $logsRoot 'kanban_server.log'
$serverOutputLog = Join-Path $logsRoot 'kanban_server.stdout.log'
$serverErrorLog = Join-Path $logsRoot 'kanban_server.error.log'

New-Item -ItemType Directory -Path $runtimeRoot, $logsRoot -Force | Out-Null

function Write-BootstrapLog {
  param([string]$Message)
  Add-Content -LiteralPath $bootstrapLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Throw-MissingFile {
  param([string]$Path, [string]$Purpose)
  $message = "Required file not found for ${Purpose}: $Path"
  throw [System.IO.FileNotFoundException]::new($message, $Path)
}

function Assert-RequiredFile {
  param([string]$Path, [string]$Purpose)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-MissingFile -Path $Path -Purpose $Purpose
  }
  return [System.IO.Path]::GetFullPath($Path)
}

function Assert-RequiredDirectory {
  param([string]$Path, [string]$Purpose)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Required directory not found for ${Purpose}: $Path"
  }
  return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-PowerShellExecutable {
  $explicitPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $explicitPath -PathType Leaf) {
    return [System.IO.Path]::GetFullPath($explicitPath)
  }

  $fallback = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
  if ($fallback) {
    $fallbackPath = if ($fallback.Path) { $fallback.Path } else { $fallback.Source }
    if ($fallbackPath -and (Test-Path -LiteralPath $fallbackPath -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($fallbackPath)
    }
  }

  throw "PowerShell executable not found. Checked '$explicitPath' and PATH entry 'powershell.exe'."
}

function Test-TeamCanonicalRoot {
  param([string]$Path, [int]$TimeoutSeconds = 20)
  $job = Start-Job -ScriptBlock {
    param($Root)
    try {
      [pscustomobject]@{
        rootExists = [bool](Test-Path -LiteralPath $Root -PathType Container)
        indexExists = [bool](Test-Path -LiteralPath (Join-Path $Root 'index.html') -PathType Leaf)
        serverExists = [bool](Test-Path -LiteralPath (Join-Path $Root 'serve_kanban.ps1') -PathType Leaf)
        projectsExists = [bool](Test-Path -LiteralPath (Join-Path $Root 'data\projects.json') -PathType Leaf)
        auditExists = [bool](Test-Path -LiteralPath (Join-Path $Root 'data\card_updates.jsonl') -PathType Leaf)
        projectFilesExists = [bool](Test-Path -LiteralPath (Join-Path $Root 'project_files') -PathType Container)
        error = ''
      }
    } catch {
      [pscustomobject]@{ rootExists=$false; indexExists=$false; serverExists=$false; projectsExists=$false; auditExists=$false; projectFilesExists=$false; error=$_.Exception.Message }
    }
  } -ArgumentList $Path
  try {
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
      Write-BootstrapLog "Team ESMI reachability check timed out after $TimeoutSeconds seconds: $Path"
      Stop-Job -Job $job -ErrorAction SilentlyContinue
      return [pscustomobject]@{ rootExists=$false; indexExists=$false; serverExists=$false; projectsExists=$false; auditExists=$false; projectFilesExists=$false; error='reachability timeout' }
    }
    return Receive-Job -Job $job
  } finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  }
}

function Test-FileWritableWithoutChange {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stream.Dispose()
    return $true
  } catch { return $false }
}

function Copy-CanonicalCacheFile {
  param([string]$RelativePath)
  $source = Assert-RequiredFile -Path (Join-Path $canonicalRoot $RelativePath) -Purpose "canonical cache source '$RelativePath'"
  $destination = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $RelativePath))
  $parent = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $copyNeeded = -not (Test-Path -LiteralPath $destination -PathType Leaf)
  if (-not $copyNeeded) {
    $copyNeeded = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
  }
  if ($copyNeeded) {
    Write-BootstrapLog "Refresh canonical cache: $source -> $destination"
    Copy-Item -LiteralPath $source -Destination $destination -Force
  } else {
    Write-BootstrapLog "Canonical cache already current: $destination"
  }
}

function Convert-ToExtendedPath {
  param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  if ($full.StartsWith('\\?\')) { return $full }
  if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
  return '\\?\' + $full
}

function Reconcile-MissingProjectFiles {
  param([string[]]$LocalRoots, [string]$CanonicalProjectFilesRoot)
  $canonicalFull = [System.IO.Path]::GetFullPath($CanonicalProjectFilesRoot).TrimEnd('\')
  foreach ($localRoot in $LocalRoots | Select-Object -Unique) {
    if ([string]::IsNullOrWhiteSpace($localRoot) -or -not (Test-Path -LiteralPath $localRoot -PathType Container)) { continue }
    $localFull = [System.IO.Path]::GetFullPath($localRoot).TrimEnd('\')
    if ($localFull.Equals($canonicalFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    Write-BootstrapLog "Reconciling missing project files only: $localFull -> $canonicalFull"
    $enumerationErrors = @()
    $localItems = @(Get-ChildItem -LiteralPath $localFull -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +enumerationErrors)
    foreach ($enumerationError in $enumerationErrors) { Write-BootstrapLog "Reconciliation enumeration skip: $($enumerationError.Exception.GetType().FullName): $($enumerationError.Exception.Message)" }
    foreach ($item in $localItems) {
      if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-BootstrapLog "Reconciliation skipped reparse point: $($item.FullName)"
        continue
      }
      $relative = $item.FullName.Substring($localFull.Length).TrimStart('\')
      if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('..')) { continue }
      $destination = [System.IO.Path]::GetFullPath((Join-Path $canonicalFull $relative))
      $approvedPrefix = $canonicalFull + '\'
      if (-not $destination.StartsWith($approvedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-BootstrapLog "Reconciliation rejected path outside canonical root: $destination"
        continue
      }
      try {
        $destinationExtended = Convert-ToExtendedPath $destination
        if ($item.PSIsContainer) {
          if (-not [System.IO.Directory]::Exists($destinationExtended)) {
            [System.IO.Directory]::CreateDirectory($destinationExtended) | Out-Null
            Write-BootstrapLog "Reconciliation created missing directory: $destination"
          } else { Write-BootstrapLog "Reconciliation skipped existing directory: $destination" }
        } elseif (-not [System.IO.File]::Exists($destinationExtended)) {
          $sourceExtended = Convert-ToExtendedPath $item.FullName
          if (-not [System.IO.File]::Exists($sourceExtended)) {
            Write-BootstrapLog "Reconciliation skipped vanished or unavailable local cache file: $($item.FullName)"
            continue
          }
          $destinationParent = Split-Path -Parent $destination
          $destinationParentExtended = Convert-ToExtendedPath $destinationParent
          if (-not [System.IO.Directory]::Exists($destinationParentExtended)) { [System.IO.Directory]::CreateDirectory($destinationParentExtended) | Out-Null }
          [System.IO.File]::Copy($sourceExtended, $destinationExtended, $false)
          Write-BootstrapLog "Reconciliation copied missing file: $($item.FullName) -> $destination"
        } else { Write-BootstrapLog "Reconciliation skipped existing file: $destination" }
      } catch {
        Write-BootstrapLog "Reconciliation error for '$($item.FullName)': $($_.Exception.GetType().FullName): $($_.Exception.Message)"
      }
    }
  }
}

function Resolve-EdgeExecutable {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
    [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'))
  }
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles})) {
    [void]$candidates.Add((Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe'))
  }
  $edgeCommand = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
  if ($edgeCommand) {
    $commandPath = if ($edgeCommand.Path) { $edgeCommand.Path } else { $edgeCommand.Source }
    if ($commandPath) { [void]$candidates.Add($commandPath) }
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
    Write-BootstrapLog "Edge candidate not found: $candidate"
  }
  return $null
}

function Write-ExceptionDiagnostics {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)
  $exception = $ErrorRecord.Exception
  Write-BootstrapLog "ERROR type: $($exception.GetType().FullName)"
  Write-BootstrapLog "ERROR message: $($exception.Message)"
  if ($exception -is [System.IO.FileNotFoundException] -and $exception.FileName) {
    Write-BootstrapLog "ERROR missing FileName: $($exception.FileName)"
  }
  if ($ErrorRecord.FullyQualifiedErrorId) { Write-BootstrapLog "ERROR id: $($ErrorRecord.FullyQualifiedErrorId)" }
  if ($ErrorRecord.TargetObject) { Write-BootstrapLog "ERROR target: $($ErrorRecord.TargetObject)" }
  if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
    Write-BootstrapLog "ERROR position: $($ErrorRecord.InvocationInfo.PositionMessage -replace '[\r\n]+', ' ')"
  }
  if ($ErrorRecord.ScriptStackTrace) { Write-BootstrapLog "ERROR stack: $($ErrorRecord.ScriptStackTrace -replace '[\r\n]+', ' | ')" }
  if ($exception.InnerException) {
    Write-BootstrapLog "ERROR inner type: $($exception.InnerException.GetType().FullName)"
    Write-BootstrapLog "ERROR inner message: $($exception.InnerException.Message)"
  }
}

function Get-Health {
  try { return Invoke-RestMethod -Uri $HealthUrl -Method Get -TimeoutSec 2 } catch { return $null }
}

function Get-ListeningProcessId {
  try {
    $connection = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
    return [int]$connection.OwningProcess
  } catch {
    try {
      $line = netstat -ano -p tcp | Select-String -Pattern "127\.0\.0\.1:$Port\s+.*LISTENING\s+(\d+)" | Select-Object -First 1
      if ($line -and $line.Matches.Count) { return [int]$line.Matches[0].Groups[1].Value }
    } catch {}
  }
  return 0
}

function Test-LegacyKanbanProcess {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $false }
  try {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    return $process -and $process.Name -match '^powershell(\.exe)?$' -and $process.CommandLine -match 'serve_kanban\.ps1' -and $process.CommandLine -match 'SAMI-Kanban-WorkServer'
  } catch { return $false }
}

function Stop-OwnedServer {
  param([int]$ProcessId, [string]$Reason)
  if (-not (Test-LegacyKanbanProcess -ProcessId $ProcessId)) {
    throw "Port $Port is in use by another application (PID $ProcessId). Close that application or contact SAMI support, then try again."
  }
  Write-BootstrapLog "Stopping existing Kanban server PID $ProcessId ($Reason)."
  Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  for ($i = 0; $i -lt 20 -and (Get-ListeningProcessId); $i++) { Start-Sleep -Milliseconds 250 }
}

function Copy-AppFile {
  param([string]$RelativePath)
  $source = Join-Path $sourceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Write-BootstrapLog "Optional app file not found; skipped: $source"
    return
  }
  $source = Assert-RequiredFile -Path $source -Purpose "copying app file '$RelativePath'"
  $destination = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $RelativePath))
  $parent = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [void](Assert-RequiredDirectory -Path $parent -Purpose "destination for '$RelativePath'")
  Write-BootstrapLog "Copy app file: $source -> $destination"
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-AppDirectory {
  param([string]$RelativePath)
  $source = Join-Path $sourceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    Write-BootstrapLog "Optional app directory not found; skipped: $source"
    return
  }
  $source = Assert-RequiredDirectory -Path $source -Purpose "copying app directory '$RelativePath'"
  $destination = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $RelativePath))
  New-Item -ItemType Directory -Path $destination -Force | Out-Null
  [void](Assert-RequiredDirectory -Path $destination -Purpose "destination for app directory '$RelativePath'")
  foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
    if (-not (Test-Path -LiteralPath $item.FullName)) { throw "App asset disappeared before copy: $($item.FullName)" }
    Write-BootstrapLog "Copy app asset: $($item.FullName) -> $destination"
    Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
  }
}

function Initialize-LiveFileIfMissing {
  param([string]$RelativePath)
  $destination = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot $RelativePath))
  if (Test-Path -LiteralPath $destination -PathType Leaf) {
    Write-BootstrapLog "Protected runtime file exists and was not overwritten: $destination"
    return
  }
  $source = Join-Path $sourceRoot $RelativePath
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Write-BootstrapLog "Protected runtime file is absent; source is also absent, so nothing was copied: $source"
    return
  }
  $source = Assert-RequiredFile -Path $source -Purpose "initialising absent protected runtime file '$RelativePath'"
  $parent = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [void](Assert-RequiredDirectory -Path $parent -Purpose "protected runtime file destination")
  Write-BootstrapLog "Initialising absent protected runtime file (no overwrite): $source -> $destination"
  Copy-Item -LiteralPath $source -Destination $destination
}

try {
  $appRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
  if ([string]::IsNullOrWhiteSpace($TeamRoot)) { $TeamRoot = $env:SAMI_KANBAN_TEAM_ROOT }
  if ([string]::IsNullOrWhiteSpace($TeamRoot)) { $TeamRoot = $DefaultCanonicalRoot }
  $canonicalRoot = [System.IO.Path]::GetFullPath($TeamRoot).TrimEnd('\')

  Write-BootstrapLog '=================================================='
  Write-BootstrapLog "Bootstrap script path: $PSCommandPath"
  Write-BootstrapLog "PSScriptRoot: $PSScriptRoot"
  Write-BootstrapLog "Resolved app root: $appRoot"
  Write-BootstrapLog "Requested TeamRoot/canonical root: $canonicalRoot"
  Write-BootstrapLog "Runtime mirror path: $runtimeRoot"
  Write-BootstrapLog "Local mirror root: $runtimeRoot"
  Write-BootstrapLog "Runtime logs path: $logsRoot"
  Write-BootstrapLog "Final browser/app URL: $Url"
  Write-BootstrapLog "PID file path: $pidPath"

  $powerShellExe = Resolve-PowerShellExecutable
  $teamProbe = Test-TeamCanonicalRoot -Path $canonicalRoot
  $teamBaseReachable = $teamProbe.rootExists -and $teamProbe.indexExists -and $teamProbe.serverExists -and $teamProbe.projectsExists
  $teamReachable = [bool]($teamBaseReachable -and $teamProbe.projectFilesExists -and $teamProbe.auditExists)
  $fallbackAllowed = $AllowLocalFallback -or $env:SAMI_KANBAN_ALLOW_LOCAL_FALLBACK -match '^(?i:true|1|yes)$'
  $runtimeMode = if ($teamReachable) { 'team-canonical' } elseif ($fallbackAllowed) { 'local-fallback' } else { 'offline' }
  $sourceRoot = if ($teamReachable) { $canonicalRoot } else { $appRoot }
  $sourceRoot = Assert-RequiredDirectory -Path $sourceRoot -Purpose 'application content source'

  $env:SAMI_KANBAN_TEAM_ROOT = $canonicalRoot
  $env:SAMI_KANBAN_CANONICAL_ROOT = $canonicalRoot
  $env:SAMI_KANBAN_RUNTIME_MODE = $runtimeMode
  Write-BootstrapLog "Team ESMI reachable: $teamReachable"
  if ($teamProbe.error) { Write-BootstrapLog "Team ESMI probe warning: $($teamProbe.error)" }
  Write-BootstrapLog "Selected runtime mode: $runtimeMode"
  Write-BootstrapLog "Application content source: $sourceRoot"

  $runtimeServeScript = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'serve_kanban.ps1'))
  # Keep the locally installed server implementation active until an explicit Team deployment occurs.
  $sourceServeScript = [System.IO.Path]::GetFullPath((Join-Path $appRoot 'serve_kanban.ps1'))
  if (-not (Test-Path -LiteralPath $sourceServeScript -PathType Leaf)) {
    $canonicalServeFallback = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'serve_kanban.ps1'))
    Write-BootstrapLog "Local serve_kanban.ps1 not found; checking application source: $canonicalServeFallback"
    $sourceServeScript = Assert-RequiredFile -Path $canonicalServeFallback -Purpose 'server source fallback'
  } else {
    $sourceServeScript = Assert-RequiredFile -Path $sourceServeScript -Purpose 'server source'
  }

  Write-BootstrapLog "Resolved TeamRoot/canonical root: $canonicalRoot"
  Write-BootstrapLog "serve_kanban.ps1 source path: $sourceServeScript"
  Write-BootstrapLog "serve_kanban.ps1 runtime path: $runtimeServeScript"
  Write-BootstrapLog "PowerShell executable path: $powerShellExe"
  $initialListeningPid = Get-ListeningProcessId
  Write-BootstrapLog "Port $Port already listening: $([bool]$initialListeningPid)$(if ($initialListeningPid) { " (PID $initialListeningPid)" })"

  foreach ($relative in @('index.html','manifest.webmanifest','run_kanban.bat','run_kanban_debug.bat','run_kanban_silent.vbs','install_sami_project_portfolio.ps1','data\app_version.json')) { Copy-AppFile $relative }

  $toolsSource = Join-Path $sourceRoot 'tools'
  if (Test-Path -LiteralPath $toolsSource -PathType Container) {
    foreach ($pattern in @('*.ps1','*.vbs')) {
      Get-ChildItem -LiteralPath $toolsSource -Filter $pattern -File | ForEach-Object { Copy-AppFile ("tools\" + $_.Name) }
    }
  } else {
    Write-BootstrapLog "Optional tools directory not found; skipped: $toolsSource"
  }
  foreach ($directory in @('assets','static','css','js')) { Copy-AppDirectory $directory }

  $runtimeServeParent = Split-Path -Parent $runtimeServeScript
  [void](Assert-RequiredDirectory -Path $runtimeServeParent -Purpose 'runtime server destination')
  Write-BootstrapLog "Copy server script: $sourceServeScript -> $runtimeServeScript"
  Copy-Item -LiteralPath $sourceServeScript -Destination $runtimeServeScript -Force
  $runtimeServeScript = Assert-RequiredFile -Path $runtimeServeScript -Purpose 'runtime server launch'

  if ($teamReachable) {
    Copy-CanonicalCacheFile 'data\projects.json'
    Copy-CanonicalCacheFile 'data\card_updates.jsonl'
    if (Test-Path -LiteralPath (Join-Path $canonicalRoot 'data\kanban_config.json') -PathType Leaf) { Copy-CanonicalCacheFile 'data\kanban_config.json' }
  } else {
    Write-BootstrapLog "WARNING: Team ESMI is unreachable. Runtime mode is '$runtimeMode'; local cache is not canonical."
    foreach ($relative in @('data\projects.json','data\card_updates.jsonl','data\kanban_config.json','data\project_file_index.json','data\card_activity_index.json')) { Initialize-LiveFileIfMissing $relative }
  }

  $canonicalProjectsPath = Join-Path $canonicalRoot 'data\projects.json'
  $canonicalAuditPath = Join-Path $canonicalRoot 'data\card_updates.jsonl'
  $canonicalProjectFilesPath = Join-Path $canonicalRoot 'project_files'
  Write-BootstrapLog "Canonical projects readable: $([bool](Test-Path -LiteralPath $canonicalProjectsPath -PathType Leaf)); writable: $(Test-FileWritableWithoutChange $canonicalProjectsPath)"
  Write-BootstrapLog "Canonical audit readable: $([bool](Test-Path -LiteralPath $canonicalAuditPath -PathType Leaf)); writable: $(Test-FileWritableWithoutChange $canonicalAuditPath)"
  Write-BootstrapLog "Canonical project_files readable: $([bool](Test-Path -LiteralPath $canonicalProjectFilesPath -PathType Container))"

  $iconPath = Join-Path $runtimeRoot 'assets\sami_project_portfolio.ico'
  Write-BootstrapLog "Icon status: $(if (Test-Path -LiteralPath $iconPath -PathType Leaf) { "available at $iconPath" } else { "missing at $iconPath; Windows default will be used" })"

  if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
    $savedPid = 0
    [void][int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$savedPid)
    if ($savedPid -le 0 -or -not (Get-Process -Id $savedPid -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
      Write-BootstrapLog "Removed stale server PID file: $pidPath"
    }
  }

  $health = Get-Health
  if ($health -and $health.ok -and $health.app -eq $ProductName -and $health.serverScriptHash) {
    $runtimeServerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimeServeScript).Hash.ToLowerInvariant()
    $serverNeedsRestart = [string]$health.serverScriptHash -ne $runtimeServerHash -or
      [string]$health.mode -ne $runtimeMode -or
      -not ([string]$health.canonicalRoot).Equals($canonicalRoot, [System.StringComparison]::OrdinalIgnoreCase)
    if ($serverNeedsRestart) {
      Stop-OwnedServer -ProcessId ([int]$health.pid) -Reason 'updated server script or canonical runtime selection'
      $health = $null
      Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
  }

  if ($health -and $health.ok -and $health.app -eq $ProductName) {
    Write-BootstrapLog "Healthy server reused. PID: $($health.pid); app version: $($health.appVersion)"
    Set-Content -LiteralPath $pidPath -Value ([string]$health.pid) -Encoding ASCII
  } else {
    $listeningPid = Get-ListeningProcessId
    if ($listeningPid) {
      Stop-OwnedServer -ProcessId $listeningPid -Reason 'legacy or unhealthy Kanban endpoint'
      Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }

    [void](Assert-RequiredFile -Path $runtimeServeScript -Purpose 'server process launch')
    $runtimeProjects = Join-Path $runtimeRoot 'data\projects.json'
    [void](Assert-RequiredFile -Path $runtimeProjects -Purpose 'board loading')
    [void](Assert-RequiredFile -Path $powerShellExe -Purpose 'server process executable')

    $arguments = @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $runtimeServeScript + '"'),
      '-RootPath',('"' + $runtimeRoot + '"'),'-SourceRoot',('"' + $appRoot + '"'),
      '-TeamRoot',('"' + $canonicalRoot + '"'),'-CanonicalRoot',('"' + $canonicalRoot + '"'),
      '-LocalMirrorRoot',('"' + $runtimeRoot + '"'),'-RuntimeMode',$runtimeMode,
      '-Port',[string]$Port,'-LogPath',('"' + $serverLog + '"')
    )
    Write-BootstrapLog "Starting server executable: $powerShellExe"
    Write-BootstrapLog "Starting server script: $runtimeServeScript"
    $process = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverOutputLog -RedirectStandardError $serverErrorLog
    Set-Content -LiteralPath $pidPath -Value ([string]$process.Id) -Encoding ASCII
    Write-BootstrapLog "Started hidden server process. PID: $($process.Id)"
    Write-BootstrapLog "Server PID/port: $($process.Id)/$Port"

    $health = $null
    for ($i = 0; $i -lt 30 -and -not $health; $i++) { Start-Sleep -Milliseconds 500; $health = Get-Health }
    if (-not $health -or -not $health.ok) {
      Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
      throw "SAMI Project Portfolio server did not become healthy. Server log: $serverLog; error log: $serverErrorLog"
    }
    Write-BootstrapLog "Server health check passed. PID: $($health.pid); app version: $($health.appVersion)"
  }

  if ($NoBrowser) {
    Write-BootstrapLog 'Browser launch suppressed by -NoBrowser.'
  } else {
    $edgeExe = Resolve-EdgeExecutable
    if ($edgeExe) {
      $edgeExe = Assert-RequiredFile -Path $edgeExe -Purpose 'Microsoft Edge app-mode launch'
      Write-BootstrapLog "Edge executable path: $edgeExe"
      Write-BootstrapLog "Opening Edge app URL: $Url"
      Start-Process -FilePath $edgeExe -ArgumentList "--app=$Url"
      Write-BootstrapLog "Opened Microsoft Edge app window: $Url"
    } else {
      $uri = $null
      if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { throw "Invalid browser URL: $Url" }
      Write-BootstrapLog 'Edge executable path: not found; using the default browser.'
      Write-BootstrapLog "Opening default browser URL: $Url"
      Start-Process -FilePath $Url
      Write-BootstrapLog "Opened the default browser: $Url"
    }
  }
} catch {
  Write-ExceptionDiagnostics -ErrorRecord $_
  $missingPath = if ($_.Exception -is [System.IO.FileNotFoundException] -and $_.Exception.FileName) { " Missing path: $($_.Exception.FileName)" } else { '' }
  $userMessage = "$ProductName could not open. $($_.Exception.Message)$missingPath`n`nDiagnostic log: $bootstrapLog"
  [Console]::Error.WriteLine($userMessage)
  try { [void](New-Object -ComObject WScript.Shell).Popup($userMessage, 0, $ProductName, 16) } catch {}
  exit 1
}

exit 0
