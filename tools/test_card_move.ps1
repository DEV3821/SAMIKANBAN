param([switch]$KeepTemp)
$ErrorActionPreference = 'Stop'

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PowerShellExe = (Get-Command powershell.exe).Source
$ServerScript = Join-Path $RepoRoot 'serve_kanban.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SAMI-card-move-' + [Guid]::NewGuid().ToString('N'))
$CanonicalRoot = Join-Path $TempRoot 'canonical'
$RuntimeRoot = Join-Path $TempRoot 'runtime'
$ServerLog = Join-Path $TempRoot 'server.log'
$ServerProcess = $null

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  return $port
}

function Write-JsonFile {
  param([string]$Path, $Value)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Api {
  param([string]$Url, [ValidateSet('GET','POST')][string]$Method = 'GET', $Body = $null)
  try {
    $params = @{ UseBasicParsing = $true; Uri = $Url; Method = $Method; TimeoutSec = 8 }
    if ($null -ne $Body) {
      $params.ContentType = 'application/json; charset=utf-8'
      $params.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
    }
    $response = Invoke-WebRequest @params
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $(try { $response.Content | ConvertFrom-Json } catch { $null }); Raw = $response.Content }
  } catch {
    $response = $_.Exception.Response
    if ($null -eq $response) { throw }
    $raw = ''
    try { $reader = New-Object System.IO.StreamReader($response.GetResponseStream()); $raw = $reader.ReadToEnd(); $reader.Dispose() } catch { }
    return [pscustomobject]@{ Status = [int]$response.StatusCode.value__; Json = $(try { $raw | ConvertFrom-Json } catch { $null }); Raw = $raw }
  }
}

function Stop-SamiServer {
  param($Server)
  if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
    Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
  }
}

try {
  New-Item -ItemType Directory -Path (Join-Path $CanonicalRoot 'data'), (Join-Path $CanonicalRoot 'project_files'), (Join-Path $RuntimeRoot 'data'), (Join-Path $RuntimeRoot 'project_files') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'index.html') -Destination (Join-Path $RuntimeRoot 'index.html') -Force
  $projects = [ordered]@{
    meta = @{ name = 'Synthetic card-move transaction test'; source = 'isolated-fixture' }
    projects = @(
      @{ id='move-alpha'; title='Synthetic Alpha'; status='running'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' },
      @{ id='move-beta'; title='Synthetic Beta'; status='running'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' },
      @{ id='move-gamma'; title='Synthetic Gamma'; status='backlog'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' }
    )
  }
  Write-JsonFile -Path (Join-Path $CanonicalRoot 'data\projects.json') -Value $projects
  [System.IO.File]::WriteAllText((Join-Path $CanonicalRoot 'data\card_updates.jsonl'), '', [System.Text.UTF8Encoding]::new($false))
  foreach ($id in @('move-alpha','move-beta','move-gamma')) { New-Item -ItemType Directory -Path (Join-Path $CanonicalRoot ('project_files\' + $id)) -Force | Out-Null }

  $port = Get-FreePort
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -SourceRoot "{2}" -TeamRoot "{3}" -CanonicalRoot "{3}" -LocalMirrorRoot "{1}" -RuntimeMode team-canonical -Port {4} -LogPath "{5}"' -f $ServerScript, $RuntimeRoot, $RepoRoot, $CanonicalRoot, $port, $ServerLog
  $process = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $ServerProcess = [pscustomobject]@{ Process = $process; Url = "http://127.0.0.1:$port" }
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    Start-Sleep -Milliseconds 200
    try { if ((Invoke-Api -Url "$($ServerProcess.Url)/api/health").Status -eq 200) { break } } catch { }
    if ($process.HasExited) { throw "SAMI server exited before becoming healthy. Log: $ServerLog" }
    if ($attempt -eq 59) { throw "SAMI server did not become healthy. Log: $ServerLog" }
  }

  $initialSync = (Invoke-Api -Url "$($ServerProcess.Url)/api/sync-state").Json
  $initialProjectsText = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\projects.json'))
  $first = Invoke-Api -Url "$($ServerProcess.Url)/api/card-move" -Method POST -Body @{
    cardId='move-alpha'; fromLane='running'; toLane='backlog'; toIndex=1
    expectedProjectsRevision=$initialSync.projectsRevision; expectedBoardOrderRevision=0; clientSessionId='synthetic-move-client-a'
  }
  Assert-True ($first.Status -eq 200) "Initial card move failed: $($first.Raw)"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$first.Json.changeId)) 'Card move did not produce a logical change ID.'
  $projectsAfterFirst = (Invoke-Api -Url "$($ServerProcess.Url)/data/projects.json?test=1").Json
  $orderAfterFirst = (Invoke-Api -Url "$($ServerProcess.Url)/api/board-order").Json
  Assert-True (($projectsAfterFirst.projects | Where-Object id -eq 'move-alpha').status -eq 'backlog') 'Cross-lane move did not update project status.'
  Assert-True ($orderAfterFirst.lanes.running.Count -eq 1 -and $orderAfterFirst.lanes.backlog.Count -eq 2) 'Cross-lane move did not update both lane lists.'
  Assert-True ($orderAfterFirst.lanes.backlog[1] -eq 'move-alpha') 'Cross-lane move did not insert at the requested destination index.'
  Assert-True ($first.Json.boardOrderRevision -eq 1 -and $first.Json.projectsRevision) 'Card move did not return final revisions.'
  $audit = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\card_updates.jsonl'))
  Assert-True (([regex]::Matches($audit, '"action":"card_moved"')).Count -eq 1) 'Card move did not produce exactly one card_moved audit event.'
  Assert-True ($audit -notmatch '(?i)(password|secret|token|apikey)\s*[:=]') 'Card move audit output contained sensitive fields.'

  $currentSync = (Invoke-Api -Url "$($ServerProcess.Url)/api/sync-state").Json
  $staleProjects = Invoke-Api -Url "$($ServerProcess.Url)/api/card-move" -Method POST -Body @{
    cardId='move-beta'; fromLane='running'; toLane='done'; toIndex=0
    expectedProjectsRevision=$initialSync.projectsRevision; expectedBoardOrderRevision=1; clientSessionId='synthetic-stale-project'
  }
  Assert-True ($staleProjects.Status -eq 409) 'Stale project revision did not return HTTP 409.'
  $staleOrder = Invoke-Api -Url "$($ServerProcess.Url)/api/card-move" -Method POST -Body @{
    cardId='move-beta'; fromLane='running'; toLane='done'; toIndex=0
    expectedProjectsRevision=$currentSync.projectsRevision; expectedBoardOrderRevision=0; clientSessionId='synthetic-stale-order'
  }
  Assert-True ($staleOrder.Status -eq 409) 'Stale board-order revision did not return HTTP 409.'

  $projectsBeforeRollback = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\projects.json'))
  $orderBeforeRollback = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\board_order.json'))
  Remove-Item -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $CanonicalRoot 'data\board_order.json') -Force | Out-Null
  $rollbackSync = (Invoke-Api -Url "$($ServerProcess.Url)/api/sync-state").Json
  $rollback = Invoke-Api -Url "$($ServerProcess.Url)/api/card-move" -Method POST -Body @{
    cardId='move-beta'; fromLane='running'; toLane='done'; toIndex=0
    expectedProjectsRevision=$rollbackSync.projectsRevision; expectedBoardOrderRevision=0; clientSessionId='synthetic-rollback'
  }
  Assert-True ($rollback.Status -ne 200) 'A canonical write failure was reported as a successful card move.'
  Assert-True ([System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\projects.json')) -eq $projectsBeforeRollback) 'Projects were not rolled back after the board-order write failed.'
  Assert-True (Test-Path -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -PathType Container) 'Rollback fixture did not retain the failing board-order target.'
  Remove-Item -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -Recurse -Force
  [System.IO.File]::WriteAllText((Join-Path $CanonicalRoot 'data\board_order.json'), $orderBeforeRollback, [System.Text.UTF8Encoding]::new($false))

  Assert-True ([System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\projects.json')) -ne '') 'Synthetic projects file was unexpectedly emptied.'
  Write-Output 'CARD_MOVE_TRANSACTION_TESTS_OK'
} finally {
  Stop-SamiServer -Server $ServerProcess
  if ($KeepTemp) { Write-Output "KEPT_TEMP_ROOT=$TempRoot" }
  elseif (Test-Path -LiteralPath $TempRoot) { [System.IO.Directory]::Delete($TempRoot, $true) }
}
