param([switch]$KeepTemp)
$ErrorActionPreference = 'Stop'

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PowerShellExe = (Get-Command powershell.exe).Source
$ServerScript = Join-Path $RepoRoot 'serve_kanban.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SAMI-board-order-' + [Guid]::NewGuid().ToString('N'))
$CanonicalRoot = Join-Path $TempRoot 'canonical'
$RuntimeRoot = Join-Path $TempRoot 'runtime-a'
$OfflineRuntimeRoot = Join-Path $TempRoot 'runtime-offline'
$ServerLog = Join-Path $TempRoot 'server.log'
$OfflineServerLog = Join-Path $TempRoot 'offline-server.log'
$ServerProcess = $null
$OfflineServerProcess = $null

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-FreePort {
  $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()
  return $port
}

function Write-JsonFile {
  param([string]$Path, $Value)
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function New-SyntheticRoot {
  param([string]$Root, [bool]$WithProjects)
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $Root 'data'), (Join-Path $Root 'project_files') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'index.html') -Destination (Join-Path $Root 'index.html') -Force
  if ($WithProjects) {
    $projects = [ordered]@{
      meta = @{ name = 'Synthetic board-order test'; source = 'isolated-fixture' }
      projects = @(
        @{ id='order-alpha'; title='Synthetic Alpha'; status='running'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' },
        @{ id='order-beta'; title='Synthetic Beta'; status='backlog'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' },
        @{ id='order-gamma'; title='Synthetic Gamma'; status='running'; context='Synthetic'; lastUpdated='2026-08-03T10:00:00+09:30' }
      )
    }
    Write-JsonFile -Path (Join-Path $Root 'data\projects.json') -Value $projects
    [System.IO.File]::WriteAllText((Join-Path $Root 'data\card_updates.jsonl'), '', [System.Text.UTF8Encoding]::new($false))
  }
}

function Start-SamiServer {
  param([string]$Root, [string]$Canonical, [string]$Log, [ValidateSet('team-canonical','offline')][string]$Mode)
  $port = Get-FreePort
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -SourceRoot "{2}" -TeamRoot "{3}" -CanonicalRoot "{3}" -LocalMirrorRoot "{1}" -RuntimeMode {4} -Port {5} -LogPath "{6}"' -f $ServerScript, $Root, $RepoRoot, $Canonical, $Mode, $port, $Log
  $process = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $url = "http://127.0.0.1:$port"
  for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 200
    try {
      $health = Invoke-WebRequest -UseBasicParsing -Uri "$url/api/health" -TimeoutSec 2
      if ($health.StatusCode -eq 200) { return [pscustomobject]@{ Process = $process; Port = $port; Url = $url } }
    } catch { }
    if ($process.HasExited) { throw "SAMI server exited before becoming healthy. Log: $Log" }
  }
  throw "SAMI server did not become healthy. Log: $Log"
}

function Stop-SamiServer {
  param($Server)
  if ($Server -and $Server.Process -and -not $Server.Process.HasExited) {
    Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Api {
  param([string]$Url, [ValidateSet('GET','POST')][string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{})
  try {
    $params = @{ UseBasicParsing = $true; Uri = $Url; Method = $Method; TimeoutSec = 5; Headers = $Headers }
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

try {
  New-SyntheticRoot -Root $CanonicalRoot -WithProjects $true
  New-SyntheticRoot -Root $RuntimeRoot -WithProjects $false
  New-SyntheticRoot -Root $OfflineRuntimeRoot -WithProjects $true
  $portServer = Start-SamiServer -Root $RuntimeRoot -Canonical $CanonicalRoot -Log $ServerLog -Mode 'team-canonical'
  $ServerProcess = $portServer

  $initial = Invoke-Api -Url "$($portServer.Url)/api/board-order"
  Assert-True ($initial.Status -eq 200) 'Missing board_order.json did not return HTTP 200.'
  Assert-True (-not $initial.Json.exists) 'Opening the board created board_order.json unexpectedly.'
  Assert-True ($initial.Json.lanes.backlog[0] -eq 'order-beta') 'Default backlog order did not preserve projects.json ordering.'
  Assert-True ($initial.Json.lanes.running.Count -eq 2) 'Default running lane was not reconciled.'

  $validLanes = @{ backlog = @('order-beta'); running = @('order-gamma','order-alpha'); blocked = @(); done = @() }
  $firstSave = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 0; clientSessionId = 'synthetic-client-a'; movedCardId = 'order-alpha'; auditAction = 'card_reordered'; lanes = $validLanes }
  Assert-True ($firstSave.Status -eq 200) 'First canonical board-order save failed.'
  Assert-True ($firstSave.Json.revision -eq 1) 'First board-order save did not commit revision 1.'
  Assert-True (Test-Path -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -PathType Leaf) 'Canonical board_order.json was not created after reorder.'
  Assert-True (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'data\board_order.json') -PathType Leaf) 'Runtime board-order mirror was not updated after canonical success.'

  $secondLanes = @{ backlog = @('order-beta'); running = @('order-alpha','order-gamma'); blocked = @(); done = @() }
  $secondSave = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 1; clientSessionId = 'synthetic-client-b'; movedCardId = 'order-gamma'; auditAction = 'card_reordered'; lanes = $secondLanes }
  Assert-True ($secondSave.Status -eq 200 -and $secondSave.Json.revision -eq 2) 'Second board-order save did not increment the revision.'
  Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $CanonicalRoot 'data') -Filter 'board_order.json.bak-*').Count -ge 1) 'Existing board_order.json did not receive a pre-write backup.'

  $stale = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 1; clientSessionId = 'synthetic-stale'; lanes = $secondLanes }
  Assert-True ($stale.Status -eq 409) 'Stale board-order revision did not return HTTP 409.'
  $afterStale = Invoke-Api -Url "$($portServer.Url)/api/board-order"
  Assert-True ($afterStale.Status -eq 200 -and $afterStale.Json.revision -eq 2) 'Stale submission changed or failed to preserve the authoritative order.'

  $duplicate = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 2; clientSessionId = 'synthetic-duplicate'; lanes = @{ backlog=@('order-beta'); running=@('order-alpha','order-alpha','order-gamma'); blocked=@(); done=@() } }
  Assert-True ($duplicate.Status -eq 400) 'Duplicate board-order IDs were not rejected.'
  $wrongLane = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 2; clientSessionId = 'synthetic-wrong-lane'; lanes = @{ backlog=@('order-beta','order-alpha'); running=@('order-gamma'); blocked=@(); done=@() } }
  Assert-True ($wrongLane.Status -eq 400) 'Wrong-lane board-order IDs were not rejected.'
  $unknown = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 2; clientSessionId = 'synthetic-unknown'; lanes = @{ backlog=@('order-beta'); running=@('order-alpha','order-gamma'); blocked=@('deleted-card'); done=@() } }
  Assert-True ($unknown.Status -eq 400) 'Unknown board-order IDs were not rejected.'

  $partial = @{ schemaVersion = 1; revision = 7; updatedAt = '2026-08-03T10:00:00+09:30'; updatedBySession = 'fixture'; changeId = 'fixture-partial'; lanes = @{ backlog=@('order-beta'); running=@('order-alpha','deleted-card','order-beta'); blocked=@(); done=@() } }
  Write-JsonFile -Path (Join-Path $CanonicalRoot 'data\board_order.json') -Value $partial
  $reconciled = Invoke-Api -Url "$($portServer.Url)/api/board-order"
  Assert-True ($reconciled.Status -eq 200 -and $reconciled.Json.revision -eq 7) 'Existing order was not loaded.'
  Assert-True ($reconciled.Json.lanes.backlog.Count -eq 1 -and $reconciled.Json.lanes.running.Count -eq 2 -and $reconciled.Json.lanes.running[0] -eq 'order-alpha' -and $reconciled.Json.lanes.running[1] -eq 'order-gamma') 'Unknown and wrong-lane order entries were not ignored.'
  Assert-True ($reconciled.Json.warnings.Count -ge 2) 'Order reconciliation warnings were not reported.'

  [System.IO.File]::WriteAllText((Join-Path $CanonicalRoot 'data\board_order.json'), '{ malformed', [System.Text.UTF8Encoding]::new($false))
  $malformed = Invoke-Api -Url "$($portServer.Url)/api/board-order"
  Assert-True ($malformed.Status -eq 200 -and $malformed.Json.valid -eq $false) 'Malformed board_order.json did not degrade safely.'
  Assert-True ($malformed.Json.lanes.backlog.Count -eq 1 -and $malformed.Json.lanes.running.Count -eq 2) 'Malformed order did not preserve the usable project ordering.'

  Remove-Item -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -Force
  $restore = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 0; clientSessionId = 'synthetic-restore'; lanes = $validLanes }
  Assert-True ($restore.Status -eq 200) 'Board order could not be restored after malformed-fixture testing.'
  $runtimeBeforeFailure = [System.IO.File]::ReadAllText((Join-Path $RuntimeRoot 'data\board_order.json'))
  Remove-Item -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -Force
  New-Item -ItemType Directory -Path (Join-Path $CanonicalRoot 'data\board_order.json') -Force | Out-Null
  $canonicalFailure = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 0; clientSessionId = 'synthetic-failure'; lanes = $validLanes }
  Assert-True ($canonicalFailure.Status -ne 200) 'Canonical write failure was reported as success.'
  Assert-True ([System.IO.File]::ReadAllText((Join-Path $RuntimeRoot 'data\board_order.json')) -eq $runtimeBeforeFailure) 'Runtime order changed when canonical order write failed.'
  Remove-Item -LiteralPath (Join-Path $CanonicalRoot 'data\board_order.json') -Recurse -Force
  $restoreAgain = Invoke-Api -Url "$($portServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 0; clientSessionId = 'synthetic-restore-again'; lanes = $validLanes }
  Assert-True ($restoreAgain.Status -eq 200) 'Board order could not be restored after canonical-write failure testing.'

  $orderBeforeProjectSave = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\board_order.json'))
  $projectBody = Get-Content -LiteralPath (Join-Path $CanonicalRoot 'data\projects.json') -Raw | ConvertFrom-Json
  $projectSave = Invoke-Api -Url "$($portServer.Url)/api/projects" -Method POST -Body $projectBody
  Assert-True ($projectSave.Status -eq 200) 'Older-client-style projects.json save failed.'
  Assert-True ([System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\board_order.json')) -eq $orderBeforeProjectSave) 'Older-client-style project save modified board_order.json.'

  $auditText = [System.IO.File]::ReadAllText((Join-Path $CanonicalRoot 'data\card_updates.jsonl'))
  Assert-True ($auditText -match 'card_reordered') 'card_reordered audit event was not written.'
  Assert-True ($auditText -notmatch '(?i)(password|secret|token|apikey)\s*[:=]') 'Synthetic board-order audit output contained a secret-like field.'

  Stop-SamiServer -Server $ServerProcess
  $ServerProcess = $null

  $offlineServer = Start-SamiServer -Root $OfflineRuntimeRoot -Canonical (Join-Path $TempRoot 'missing-canonical') -Log $OfflineServerLog -Mode 'offline'
  $OfflineServerProcess = $offlineServer
  $offlineGet = Invoke-Api -Url "$($offlineServer.Url)/api/board-order"
  Assert-True ($offlineGet.Status -eq 200 -and $offlineGet.Json.canonicalAvailable -eq $false) 'Unavailable Team ESMI did not return a safe read-only board-order state.'
  $offlinePost = Invoke-Api -Url "$($offlineServer.Url)/api/board-order" -Method POST -Body @{ expectedRevision = 0; clientSessionId = 'synthetic-offline'; lanes = @{ backlog=@('order-beta'); running=@('order-alpha','order-gamma'); blocked=@(); done=@() } }
  Assert-True ($offlinePost.Status -eq 503) 'Unavailable Team ESMI did not block persistent board-order writes.'
  Stop-SamiServer -Server $OfflineServerProcess
  $OfflineServerProcess = $null
  Write-Output 'BOARD_ORDER_SERVER_TESTS_OK'
} finally {
  Stop-SamiServer -Server $ServerProcess
  Stop-SamiServer -Server $OfflineServerProcess
  if ($KeepTemp) { Write-Output "KEPT_TEMP_ROOT=$TempRoot" }
  elseif (Test-Path -LiteralPath $TempRoot) { [System.IO.Directory]::Delete($TempRoot, $true) }
}
