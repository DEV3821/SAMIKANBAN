[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$MigrationScript = Join-Path $PSScriptRoot 'migrate_project_history.ps1'
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('SAMI-file-detection-' + [Guid]::NewGuid().ToString('N'))
$CanonicalRoot = Join-Path $TempRoot 'canonical'
$RuntimeRoot = Join-Path $TempRoot 'runtime'
$ServerLog = Join-Path $TempRoot 'server.log'
$ServerProcess = $null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Write-JsonFile([string]$Path, $Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 50) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Get-JsonFile([string]$Path) {
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Revision([string]$Path) {
  $item = Get-Item -LiteralPath $Path
  return $item.LastWriteTimeUtc.ToString('o') + '|' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-IndexEntry($Index, [string]$CardId) {
  $cards = $Index.cards
  if ($cards -is [System.Array]) {
    return @($cards | Where-Object { [string]$_.cardId -eq $CardId } | Select-Object -First 1)[0]
  }
  $property = $cards.PSObject.Properties[$CardId]
  if ($property) { return $property.Value }
  return $null
}

function Get-FreePort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  return $port
}

function Invoke-Migration([string[]]$Arguments) {
  $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MigrationScript @Arguments 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { throw "Migration command failed: $output" }
  if ([string]::IsNullOrWhiteSpace($output)) { throw 'Migration command returned no JSON report.' }
  return $output | ConvertFrom-Json
}

function Invoke-Api([string]$Url, [string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{}) {
  $parameters = @{ UseBasicParsing = $true; Uri = $Url; Method = $Method; TimeoutSec = 15; Headers = $Headers }
  if ($null -ne $Body) {
    $parameters.ContentType = 'application/json; charset=utf-8'
    $parameters.Body = $Body | ConvertTo-Json -Depth 50 -Compress
  }
  try {
    $response = Invoke-WebRequest @parameters
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = ($response.Content | ConvertFrom-Json); Raw = $response.Content }
  } catch {
    $httpResponse = $_.Exception.Response
    if ($null -eq $httpResponse) { throw }
    $reader = New-Object IO.StreamReader($httpResponse.GetResponseStream())
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    return [pscustomobject]@{ Status = [int]$httpResponse.StatusCode.value__; Json = $(try { $raw | ConvertFrom-Json } catch { $null }); Raw = $raw }
  }
}

function Get-ProjectCard($Payload, [string]$Id) {
  return @($Payload.projects | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

function Wait-ForServer($Process, [string]$BaseUrl) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 200
    try {
      $health = Invoke-Api "$BaseUrl/api/health"
      if ($health.Status -eq 200) { return }
    } catch { }
    if ($Process.HasExited) { throw "Server exited before health check. See $ServerLog" }
  }
  throw "Server did not become healthy. See $ServerLog"
}

function Wait-ForScannerInterval {
  Start-Sleep -Milliseconds 7200
}

try {
  $dataPath = Join-Path $CanonicalRoot 'data'
  $runtimeDataPath = Join-Path $RuntimeRoot 'data'
  $projectFilesRoot = Join-Path $CanonicalRoot 'project_files'
  $fileFolder = Join-Path $projectFilesRoot 'file-alpha'
  New-Item -ItemType Directory -Path $dataPath, $runtimeDataPath, $fileFolder, (Join-Path $fileFolder '01_Planning'), (Join-Path $fileFolder '02_Delivery'), (Join-Path $fileFolder 'backups'), (Join-Path $projectFilesRoot 'unmapped') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'index.html') -Destination (Join-Path $RuntimeRoot 'index.html') -Force

  $notes = "Keep this exact`r`n`r`nUnicode " + [char]0x2014 + " and <b>literal</b>"
  $projects = [ordered]@{
    meta = [ordered]@{ name = 'Synthetic file detection test'; source = 'isolated-fixture' }
    projects = @(
      [ordered]@{ id = 'file-alpha'; title = 'File Alpha'; status = 'running'; riskColour = 'green'; owner = 'Owner'; projectLead = 'Lead'; reviewDate = '2026-08-10'; nextAction = 'Baseline action'; next = 'Baseline action'; notes = $notes; folder = [ordered]@{ enabled = $true; relativePath = 'project_files/file-alpha' } }
      [ordered]@{ id = 'file-blank'; title = 'File Blank'; status = 'backlog'; riskColour = 'green'; nextAction = ''; next = ''; notes = '' }
    )
  }
  Write-JsonFile (Join-Path $dataPath 'projects.json') $projects
  [IO.File]::WriteAllText((Join-Path $dataPath 'card_updates.jsonl'), '', [Text.UTF8Encoding]::new($false))
  $index = [ordered]@{
    generatedAt = '2026-08-03T00:00:00.0000000+09:30'
    indexRevision = 0
    cards = [ordered]@{
      'file-alpha' = [ordered]@{ cardId = 'file-alpha'; title = 'File Alpha'; folderRelativePath = 'project_files/file-alpha'; fileCount = 0; files = @() }
    }
    reviewQueue = @()
  }
  Write-JsonFile (Join-Path $dataPath 'project_file_index.json') $index

  $existingFile = Join-Path $fileFolder '01_Planning\brief.docx'
  [IO.File]::WriteAllText($existingFile, 'existing baseline file', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fileFolder '~$brief.docx'), 'ignored temp', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fileFolder 'report.bak'), 'ignored backup', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fileFolder 'backups\old.pdf'), 'ignored backup folder', [Text.UTF8Encoding]::new($false))

  $trustedTimestamp = '2026-08-03T12:00:00.0000000+09:30'
  $preview = Invoke-Migration @('-CanonicalRoot', $CanonicalRoot, '-EstablishFileBaseline', '-MigrationId', 'file-detection-test-v1', '-TrustedTimestamp', $trustedTimestamp)
  Assert-True ($preview.previewOnly -eq $true) 'Migration preview did not remain preview-only.'
  Assert-True ($preview.baselineNextActionEventsProposed -eq 1) 'Migration proposed the wrong number of Next Action baselines.'
  Assert-True ($preview.fileBaselineEntriesProposed -eq 1) 'Migration did not discover exactly one baseline file.'
  Assert-True ($preview.filesIgnoredAsTemporary -ge 3) 'Temporary/backup files were not excluded from the baseline.'
  Assert-True ($preview.unmappedFolders -eq 1) 'Unmapped project folder was not reported.'

  $apply = Invoke-Migration @('-CanonicalRoot', $CanonicalRoot, '-Apply', '-EstablishFileBaseline', '-ExpectedProjectsRevision', [string]$preview.sourceProjectsRevision, '-MigrationId', 'file-detection-test-v1', '-TrustedTimestamp', $trustedTimestamp)
  Assert-True ($apply.appliedBaselineCardCount -eq 1) 'Migration apply did not write the Next Action baseline.'
  Assert-True ($apply.appliedFileBaselineCount -eq 1) 'Migration apply did not write the file baseline.'
  $afterMigration = Get-JsonFile (Join-Path $dataPath 'projects.json')
  $alpha = Get-ProjectCard $afterMigration 'file-alpha'
  Assert-True ([string]$alpha.notes -eq $notes) 'Migration changed manual Notes.'
  Assert-True (@($alpha.projectHistory).Count -eq 1) 'Migration did not add exactly one baseline history entry.'
  Assert-True ([string]$alpha.projectHistory[0].type -eq 'next_action_baseline') 'Migration history entry has the wrong type.'
  $afterIndex = Get-JsonFile (Join-Path $dataPath 'project_file_index.json')
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$afterIndex.fileBaselineCompletedAt)) 'File baseline completion marker is missing.'
  $baselineEntry = Get-IndexEntry $afterIndex 'file-alpha'
  Assert-True (@($baselineEntry.files).Count -eq 1) 'Baseline index contains the wrong file count.'
  Assert-True ([string]$baselineEntry.files[0].relativePath -eq '01_Planning/brief.docx') 'Baseline relative path is wrong.'
  Assert-True ((Test-Path -LiteralPath (Join-Path $dataPath 'project_history_migration.json') -PathType Leaf)) 'Migration state file is missing.'

  $currentRevision = Get-Revision (Join-Path $dataPath 'projects.json')
  $idempotent = Invoke-Migration @('-CanonicalRoot', $CanonicalRoot, '-Apply', '-EstablishFileBaseline', '-ExpectedProjectsRevision', $currentRevision, '-MigrationId', 'file-detection-test-v1', '-TrustedTimestamp', $trustedTimestamp)
  Assert-True ($idempotent.idempotent -eq $true) 'Migration rerun was not idempotent.'

  $port = Get-FreePort
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -SourceRoot "{2}" -TeamRoot "{3}" -CanonicalRoot "{3}" -LocalMirrorRoot "{1}" -RuntimeMode team-canonical -Port {4} -LogPath "{5}"' -f (Join-Path $RepoRoot 'serve_kanban.ps1'), $RuntimeRoot, $RepoRoot, $CanonicalRoot, $port, $ServerLog
  $ServerProcess = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $base = "http://127.0.0.1:$port"
  Wait-ForServer $ServerProcess $base
  $initialState = Invoke-Api "$base/api/sync-state"
  Assert-True ($initialState.Status -eq 200) 'Initial file scan sync-state failed.'
  Assert-True ($initialState.Json.projectFileBaselineReady -eq $true) 'Server did not recognize the migrated file baseline.'
  $initialProjects = (Invoke-Api "$base/data/projects.json").Json
  Assert-True (@((Get-ProjectCard $initialProjects 'file-alpha').projectHistory | Where-Object { $_.type -eq 'project_file_added' }).Count -eq 0) 'Existing baseline file created a false file-added event.'

  Wait-ForScannerInterval
  $newFile = Join-Path $fileFolder '02_Delivery\new-report.pdf'
  [IO.File]::WriteAllText($newFile, 'new file', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fileFolder '~$new-report.pdf'), 'ignored temp', [Text.UTF8Encoding]::new($false))
  $firstScan = Invoke-Api "$base/api/sync-state"
  Assert-True ($firstScan.Status -eq 200) 'First new-file scan failed.'
  Wait-ForScannerInterval
  $secondScan = Invoke-Api "$base/api/sync-state"
  Assert-True ($secondScan.Status -eq 200) 'Second stable-file scan failed.'
  $afterFileProjects = (Invoke-Api "$base/data/projects.json").Json
  $afterFileAlpha = Get-ProjectCard $afterFileProjects 'file-alpha'
  $fileEvents = @($afterFileAlpha.projectHistory | Where-Object { $_.type -eq 'project_file_added' })
  Assert-True ($fileEvents.Count -eq 1) 'Stable new file did not create exactly one project_file_added event.'
  Assert-True ([string]$fileEvents[0].files[0].relativePath -eq '02_Delivery/new-report.pdf') 'File-added history omitted the correct relative path.'
  $scannedIndex = Get-JsonFile (Join-Path $dataPath 'project_file_index.json')
  Assert-True (@((Get-IndexEntry $scannedIndex 'file-alpha').files).Count -eq 2) 'Shared file index did not include the new file.'
  Wait-ForScannerInterval
  $thirdScan = Invoke-Api "$base/api/sync-state"
  Assert-True ($thirdScan.Status -eq 200) 'Repeat file scan failed.'
  $repeatProjects = (Invoke-Api "$base/data/projects.json").Json
  Assert-True (@((Get-ProjectCard $repeatProjects 'file-alpha').projectHistory | Where-Object { $_.type -eq 'project_file_added' }).Count -eq 1) 'Repeat scan duplicated the file-added event.'

  $oldPath = Join-Path $fileFolder '01_Planning\brief.docx'
  $renamedPath = Join-Path $fileFolder '01_Planning\brief-renamed.docx'
  Move-Item -LiteralPath $oldPath -Destination $renamedPath
  Wait-ForScannerInterval
  [void](Invoke-Api "$base/api/sync-state")
  $renameIndex = Get-JsonFile (Join-Path $dataPath 'project_file_index.json')
  Assert-True (@((Get-IndexEntry $renameIndex 'file-alpha').files | Where-Object { $_.relativePath -eq '01_Planning/brief-renamed.docx' }).Count -eq 1) 'Rename was not reconciled in the shared file index.'
  $renameProjects = (Invoke-Api "$base/data/projects.json").Json
  Assert-True (@((Get-ProjectCard $renameProjects 'file-alpha').projectHistory | Where-Object { $_.type -eq 'project_file_added' }).Count -eq 1) 'Rename incorrectly created a new file-added history event.'

  Remove-Item -LiteralPath $renamedPath -Force
  Wait-ForScannerInterval
  [void](Invoke-Api "$base/api/sync-state")
  $deleteIndex = Get-JsonFile (Join-Path $dataPath 'project_file_index.json')
  Assert-True (@((Get-IndexEntry $deleteIndex 'file-alpha').files | Where-Object { $_.relativePath -eq '01_Planning/brief-renamed.docx' }).Count -eq 0) 'Deletion was not reconciled in the shared file index.'
  $deleteProjects = (Invoke-Api "$base/data/projects.json").Json
  Assert-True (@((Get-ProjectCard $deleteProjects 'file-alpha').projectHistory | Where-Object { $_.type -eq 'project_file_added' }).Count -eq 1) 'Deletion incorrectly created a file-added history event.'

  'PROJECT_FILE_DETECTION_TESTS_OK'
} finally {
  if ($ServerProcess -and -not $ServerProcess.HasExited) { Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue }
  if ($KeepTemp) { "KEPT_TEMP_ROOT=$TempRoot" }
  elseif (Test-Path -LiteralPath $TempRoot -PathType Container) { [IO.Directory]::Delete($TempRoot, $true) }
}
