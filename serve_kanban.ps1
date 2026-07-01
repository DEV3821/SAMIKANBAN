param(
  [string]$RootPath,
  [string]$Root,
  [string]$SourceRoot,
  [string]$TeamRoot = $env:SAMI_KANBAN_TEAM_ROOT,
  [int]$Port = 8011,
  [string]$LogPath = "logs\kanban_server.log"
)

$ErrorActionPreference = "Stop"

function Initialize-LogPath {
  param([string]$RequestedLogPath)

  try {
    $resolved = [System.IO.Path]::GetFullPath($RequestedLogPath)
    $dir = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -LiteralPath $resolved -Value ""
    return $resolved
  } catch {
    $fallbackDir = Join-Path $env:LOCALAPPDATA "SAMI-Kanban-WorkServer\logs"
    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    $fallback = Join-Path $fallbackDir "kanban_server.log"
    Add-Content -LiteralPath $fallback -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: requested server log failed: $RequestedLogPath"
    Add-Content -LiteralPath $fallback -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    return $fallback
  }
}

$script:LogPath = Initialize-LogPath $LogPath
$script:BackedUpPaths = @{}
$script:EditSessions = @{}

function Write-ServerLog {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -LiteralPath $script:LogPath -Value "[$stamp] $Message"
}

function Write-ExceptionLog {
  param([System.Exception]$Exception, [string]$Prefix = "ERROR")
  Write-ServerLog "$Prefix type: $($Exception.GetType().FullName)"
  Write-ServerLog "$Prefix message: $($Exception.Message)"
  if ($Exception.StackTrace) {
    Write-ServerLog "$Prefix stack: $($Exception.StackTrace)"
  }
  if ($Exception.InnerException) {
    Write-ServerLog "$Prefix inner type: $($Exception.InnerException.GetType().FullName)"
    Write-ServerLog "$Prefix inner message: $($Exception.InnerException.Message)"
    if ($Exception.InnerException.StackTrace) {
      Write-ServerLog "$Prefix inner stack: $($Exception.InnerException.StackTrace)"
    }
  }
}

function Get-MimeType {
  param([string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { "text/html; charset=utf-8"; break }
    ".htm"  { "text/html; charset=utf-8"; break }
    ".json" { "application/json; charset=utf-8"; break }
    ".js"   { "text/javascript; charset=utf-8"; break }
    ".css"  { "text/css; charset=utf-8"; break }
    ".jpg"  { "image/jpeg"; break }
    ".jpeg" { "image/jpeg"; break }
    ".png"  { "image/png"; break }
    ".svg"  { "image/svg+xml"; break }
    ".ico"  { "image/x-icon"; break }
    default { "application/octet-stream" }
  }
}

function Send-Json {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [int]$StatusCode,
    [string]$StatusText,
    [hashtable]$Payload
  )

  $json = ConvertTo-Json $Payload -Depth 20
  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
  Send-Response -Stream $Stream -StatusCode $StatusCode -StatusText $StatusText -Body $body -ContentType "application/json; charset=utf-8"
}

function Read-RequestBody {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [string]$Request,
    [byte[]]$InitialBuffer,
    [int]$InitialRead
  )

  $headerEnd = $Request.IndexOf("`r`n`r`n")
  if ($headerEnd -lt 0) {
    return ""
  }

  $headers = $Request.Substring(0, $headerEnd)
  $contentLength = 0
  foreach ($line in ($headers -split "`r?`n")) {
    if ($line -match "^Content-Length:\s*(\d+)\s*$") {
      $contentLength = [int]$matches[1]
      break
    }
  }

  if ($contentLength -le 0) {
    return ""
  }

  $headerBytesLength = [System.Text.Encoding]::ASCII.GetByteCount($Request.Substring(0, $headerEnd + 4))
  $bodyBytes = New-Object byte[] $contentLength
  $alreadyRead = [Math]::Max(0, $InitialRead - $headerBytesLength)
  if ($alreadyRead -gt 0) {
    [Array]::Copy($InitialBuffer, $headerBytesLength, $bodyBytes, 0, [Math]::Min($alreadyRead, $contentLength))
  }

  $offset = [Math]::Min($alreadyRead, $contentLength)
  while ($offset -lt $contentLength) {
    $count = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
    if ($count -le 0) {
      break
    }
    $offset += $count
  }

  return [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $offset)
}

function Backup-Once {
  param([string]$Path)

  $resolved = [System.IO.Path]::GetFullPath($Path)
  if ($script:BackedUpPaths.ContainsKey($resolved)) {
    return
  }

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$Path.bak-$stamp"
    [System.IO.File]::Copy($Path, $backup, $false)
    $script:BackedUpPaths[$resolved] = $backup
    Write-ServerLog "Backup created before write: $backup"
  }
}

function Redact-SensitiveText {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }
  return [regex]::Replace($Text, "(?i)(password|passwd|pwd|secret|token|apikey|api_key)\s*[:=]\s*[^,\r\n}]+", '$1=[redacted]')
}

function Redact-AuditObject {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }
  if ($Value -is [string]) {
    return (Redact-SensitiveText $Value)
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $Value.Keys) {
      if ([string]$key -match "(?i)password|passwd|pwd|secret|token|apikey|api_key") {
        $copy[$key] = "[redacted]"
      } else {
        $copy[$key] = Redact-AuditObject $Value[$key]
      }
    }
    return $copy
  }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) {
      $items += Redact-AuditObject $item
    }
    return $items
  }
  return $Value
}

function Save-ProjectsJson {
  param([string]$Body, [string[]]$JsonPaths)

  $payload = $Body | ConvertFrom-Json
  if ($null -eq $payload.projects) {
    throw "Payload must include a projects array."
  }

  if ($null -eq $payload.meta) {
    $payload | Add-Member -NotePropertyName meta -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $savedStamp = (Get-Date).ToString("o")
  if ($payload.meta.PSObject.Properties.Name -contains "saved") {
    $payload.meta.saved = $savedStamp
  } else {
    $payload.meta | Add-Member -NotePropertyName saved -NotePropertyValue $savedStamp -Force
  }
  $json = $payload | ConvertTo-Json -Depth 30
  foreach ($JsonPath in ($JsonPaths | Select-Object -Unique)) {
    Backup-Once -Path $JsonPath
    [System.IO.File]::WriteAllText($JsonPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  }
}

function Get-FileRevisionInfo {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @{
      exists = $false
      path = $Path
      lastWriteUtc = ""
      length = 0
      hash = ""
    }
  }

  $item = Get-Item -LiteralPath $Path
  return @{
    exists = $true
    path = $Path
    lastWriteUtc = $item.LastWriteTimeUtc.ToString("o")
    length = $item.Length
    hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  }
}

function Get-CardConflictKey {
  param($Card, [int]$Index)

  if ($null -ne $Card.id -and -not [string]::IsNullOrWhiteSpace([string]$Card.id)) {
    return "id:" + [string]$Card.id
  }
  if ($null -ne $Card.title -and -not [string]::IsNullOrWhiteSpace([string]$Card.title)) {
    return "title:" + ([string]$Card.title).Trim().ToLowerInvariant()
  }
  return "index:$Index"
}

function Get-CardLastUpdated {
  param($Card)

  if ($null -eq $Card -or [string]::IsNullOrWhiteSpace([string]$Card.lastUpdated)) {
    return [DateTime]::MinValue
  }
  $parsed = [DateTime]::MinValue
  if ([DateTime]::TryParse([string]$Card.lastUpdated, [ref]$parsed)) {
    return $parsed
  }
  return [DateTime]::MinValue
}

function ConvertTo-CompactJson {
  param($Value)

  return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Append-SyncConflictAudit {
  param([object[]]$Conflicts, [string[]]$AuditPaths)

  foreach ($conflict in $Conflicts) {
    $event = [ordered]@{
      timestamp = (Get-Date).ToString("o")
      cardId = [string]$conflict.cardId
      cardTitle = [string]$conflict.cardTitle
      action = "sync_conflict_resolved"
      updatedBy = "server-sync"
      before = @{
        teamLastUpdated = [string]$conflict.teamLastUpdated
        localLastUpdated = [string]$conflict.localLastUpdated
      }
      after = @{
        winner = [string]$conflict.winner
        reason = "newest lastUpdated"
      }
      note = "Live sync kept the newest card version while reconciling Team ESMI and local runtime mirror."
    }
    $line = ($event | ConvertTo-Json -Depth 20 -Compress)
    foreach ($AuditPath in ($AuditPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
      $dir = Split-Path -Parent $AuditPath
      if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
      Backup-Once -Path $AuditPath
      Add-Content -LiteralPath $AuditPath -Value $line -Encoding utf8
    }
  }
}

function Resolve-ProjectsConflictByCardDate {
  param(
    [string]$AuthorityJsonPath,
    [string]$LocalJsonPath,
    [string[]]$AuditPaths
  )

  if (-not (Test-Path -LiteralPath $AuthorityJsonPath -PathType Leaf) -or -not (Test-Path -LiteralPath $LocalJsonPath -PathType Leaf)) {
    return @{ resolved = $false; skipped = "missing_projects_file"; conflicts = 0 }
  }

  $authorityPayload = Get-Content -LiteralPath $AuthorityJsonPath -Raw | ConvertFrom-Json
  $localPayload = Get-Content -LiteralPath $LocalJsonPath -Raw | ConvertFrom-Json
  if ($null -eq $authorityPayload.projects -or $null -eq $localPayload.projects) {
    return @{ resolved = $false; skipped = "missing_projects_array"; conflicts = 0 }
  }

  $authorityByKey = @{}
  $localByKey = @{}
  $orderedKeys = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $authorityPayload.projects.Count; $i++) {
    $key = Get-CardConflictKey -Card $authorityPayload.projects[$i] -Index $i
    if (-not $authorityByKey.ContainsKey($key)) {
      $authorityByKey[$key] = $authorityPayload.projects[$i]
      [void]$orderedKeys.Add($key)
    }
  }
  for ($i = 0; $i -lt $localPayload.projects.Count; $i++) {
    $key = Get-CardConflictKey -Card $localPayload.projects[$i] -Index $i
    if (-not $localByKey.ContainsKey($key)) {
      $localByKey[$key] = $localPayload.projects[$i]
    }
    if (-not $authorityByKey.ContainsKey($key) -and -not $orderedKeys.Contains($key)) {
      [void]$orderedKeys.Add($key)
    }
  }

  $mergedProjects = @()
  $conflicts = @()
  $changed = $false
  foreach ($key in $orderedKeys) {
    $hasAuthority = $authorityByKey.ContainsKey($key)
    $hasLocal = $localByKey.ContainsKey($key)
    if ($hasAuthority -and -not $hasLocal) {
      $mergedProjects += $authorityByKey[$key]
      continue
    }
    if ($hasLocal -and -not $hasAuthority) {
      $localCard = $localByKey[$key]
      $mergedProjects += $localCard
      $changed = $true
      $conflicts += [pscustomobject]@{
        cardId = [string]$localCard.id
        cardTitle = [string]$localCard.title
        teamLastUpdated = ""
        localLastUpdated = [string]$localCard.lastUpdated
        winner = "local_runtime"
      }
      continue
    }

    $authorityCard = $authorityByKey[$key]
    $localCard = $localByKey[$key]
    if ((ConvertTo-CompactJson $authorityCard) -eq (ConvertTo-CompactJson $localCard)) {
      $mergedProjects += $authorityCard
      continue
    }

    $authorityUpdated = Get-CardLastUpdated -Card $authorityCard
    $localUpdated = Get-CardLastUpdated -Card $localCard
    if ($localUpdated -gt $authorityUpdated) {
      $mergedProjects += $localCard
      $changed = $true
      $conflicts += [pscustomobject]@{
        cardId = [string]$localCard.id
        cardTitle = [string]$localCard.title
        teamLastUpdated = [string]$authorityCard.lastUpdated
        localLastUpdated = [string]$localCard.lastUpdated
        winner = "local_runtime"
      }
    } else {
      $mergedProjects += $authorityCard
    }
  }

  if (-not $changed) {
    Backup-Once -Path $LocalJsonPath
    [System.IO.File]::Copy($AuthorityJsonPath, $LocalJsonPath, $true)
    Write-ServerLog "Replaced local mirror from Team source after card lastUpdated comparison found no newer local cards."
    return @{ resolved = $true; skipped = "team_newer_by_card"; conflicts = 0 }
  }

  $authorityPayload.projects = $mergedProjects
  if ($null -eq $authorityPayload.meta) {
    $authorityPayload | Add-Member -NotePropertyName meta -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $savedStamp = (Get-Date).ToString("o")
  if ($authorityPayload.meta.PSObject.Properties.Name -contains "saved") {
    $authorityPayload.meta.saved = $savedStamp
  } else {
    $authorityPayload.meta | Add-Member -NotePropertyName saved -NotePropertyValue $savedStamp -Force
  }
  $json = $authorityPayload | ConvertTo-Json -Depth 30
  foreach ($JsonPath in @($AuthorityJsonPath, $LocalJsonPath)) {
    Backup-Once -Path $JsonPath
    [System.IO.File]::WriteAllText($JsonPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  }
  Append-SyncConflictAudit -Conflicts $conflicts -AuditPaths $AuditPaths
  Write-ServerLog "Resolved projects sync conflict by card lastUpdated: $($conflicts.Count) card(s)"
  return @{ resolved = $true; skipped = ""; conflicts = $conflicts.Count }
}

function Copy-IfAuthorityNewer {
  param([string]$AuthorityPath, [string]$LocalPath)

  if (-not (Test-Path -LiteralPath $AuthorityPath -PathType Leaf)) {
    return @{
      copied = $false
      skipped = "authority_missing"
    }
  }

  $sourceInfo = Get-FileRevisionInfo -Path $AuthorityPath
  $shouldCopy = $true
  $skipped = ""
  if (Test-Path -LiteralPath $LocalPath -PathType Leaf) {
    $localInfo = Get-FileRevisionInfo -Path $LocalPath
    if ($sourceInfo.hash -eq $localInfo.hash) {
      $shouldCopy = $false
      $skipped = "same_hash"
    } elseif ([DateTime]$sourceInfo.lastWriteUtc -lt [DateTime]$localInfo.lastWriteUtc) {
      $shouldCopy = $false
      $skipped = "local_newer"
    } else {
      $shouldCopy = $true
    }
  }

  if (-not $shouldCopy) {
    return @{
      copied = $false
      skipped = $skipped
    }
  }

  $dir = Split-Path -Parent $LocalPath
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  Backup-Once -Path $LocalPath
  [System.IO.File]::Copy($AuthorityPath, $LocalPath, $true)
  Write-ServerLog "Synced newer Team source data to local mirror: $AuthorityPath -> $LocalPath"
  return @{
    copied = $true
    skipped = ""
  }
}

function Sync-SourceDataToRuntime {
  param(
    [string]$AuthorityJsonPath,
    [string]$LocalJsonPath,
    [string]$AuthorityAuditPath,
    [string]$LocalAuditPath
  )

  $projectsResult = Copy-IfAuthorityNewer -AuthorityPath $AuthorityJsonPath -LocalPath $LocalJsonPath
  $conflictsResolved = 0
  if ($projectsResult.skipped -eq "local_newer") {
    $resolveResult = Resolve-ProjectsConflictByCardDate -AuthorityJsonPath $AuthorityJsonPath -LocalJsonPath $LocalJsonPath -AuditPaths @($AuthorityAuditPath, $LocalAuditPath)
    if ($resolveResult.resolved) {
      $projectsResult = @{
        copied = $true
        skipped = "merged_by_lastUpdated"
      }
      $conflictsResolved = $resolveResult.conflicts
    }
  }
  $auditResult = Copy-IfAuthorityNewer -AuthorityPath $AuthorityAuditPath -LocalPath $LocalAuditPath
  return @{
    projectsCopied = $projectsResult.copied
    projectsSkipped = $projectsResult.skipped
    auditCopied = $auditResult.copied
    auditSkipped = $auditResult.skipped
    conflictsResolved = $conflictsResolved
  }
}

function Sync-TeamDataToLocalCopies {
  param(
    [string]$TeamJsonPath,
    [string]$RuntimeJsonPath,
    [string]$SourceJsonPath,
    [string]$TeamAuditPath,
    [string]$RuntimeAuditPath,
    [string]$SourceAuditPath
  )

  $sourceResult = @{ projectsCopied = $false; projectsSkipped = "same_path"; auditCopied = $false; auditSkipped = "same_path"; conflictsResolved = 0 }
  if (-not ([System.IO.Path]::GetFullPath($SourceJsonPath).Equals([System.IO.Path]::GetFullPath($TeamJsonPath), [System.StringComparison]::OrdinalIgnoreCase))) {
    $sourceResult = Sync-SourceDataToRuntime -AuthorityJsonPath $TeamJsonPath -LocalJsonPath $SourceJsonPath -AuthorityAuditPath $TeamAuditPath -LocalAuditPath $SourceAuditPath
  }

  $runtimeResult = Sync-SourceDataToRuntime -AuthorityJsonPath $TeamJsonPath -LocalJsonPath $RuntimeJsonPath -AuthorityAuditPath $TeamAuditPath -LocalAuditPath $RuntimeAuditPath
  $runtimeResult["sourceProjectsCopied"] = $sourceResult.projectsCopied
  $runtimeResult["sourceProjectsSkipped"] = $sourceResult.projectsSkipped
  $runtimeResult["sourceAuditCopied"] = $sourceResult.auditCopied
  $runtimeResult["sourceAuditSkipped"] = $sourceResult.auditSkipped
  $runtimeResult["sourceConflictsResolved"] = $sourceResult.conflictsResolved
  return $runtimeResult
}

function Get-SyncStatus {
  param(
    [string]$SourceJsonPath,
    [string]$LocalJsonPath,
    [string]$SourceAuditPath,
    [string]$LocalAuditPath,
    [hashtable]$SyncResult = $null
  )

  if ($null -eq $SyncResult) {
    $SyncResult = @{ projectsCopied = $false; auditCopied = $false }
  }

  return @{
    ok = $true
    source = @{
      projects = Get-FileRevisionInfo -Path $SourceJsonPath
      audit = Get-FileRevisionInfo -Path $SourceAuditPath
    }
    local = @{
      projects = Get-FileRevisionInfo -Path $LocalJsonPath
      audit = Get-FileRevisionInfo -Path $LocalAuditPath
    }
    synced = $SyncResult
  }
}

function Require-FreshProjectsSource {
  param([string]$Request, [string]$SourceJsonPath)

  $loadedRevision = Get-RequestHeader -Request $Request -Name "X-Kanban-Projects-Revision"
  if ([string]::IsNullOrWhiteSpace($loadedRevision)) {
    return
  }

  $currentRevision = (Get-FileRevisionInfo -Path $SourceJsonPath).lastWriteUtc
  if (-not [string]::IsNullOrWhiteSpace($currentRevision) -and -not $loadedRevision.Equals($currentRevision, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Team ESMI source changed since this board loaded. Refresh the board before saving."
  }
}

function Append-AuditEvent {
  param([string]$Body, [string[]]$AuditPaths)

  $event = $Body | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($event.timestamp) -or [string]::IsNullOrWhiteSpace($event.cardTitle)) {
    throw "Audit event must include timestamp and cardTitle."
  }

  $safe = Redact-AuditObject $event
  $json = ConvertTo-Json $safe -Depth 30 -Compress
  foreach ($AuditPath in ($AuditPaths | Select-Object -Unique)) {
    $dir = Split-Path -Parent $AuditPath
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $prefix = ""
    if ((Test-Path -LiteralPath $AuditPath -PathType Leaf) -and (Get-Item -LiteralPath $AuditPath).Length -gt 0) {
      $stream = [System.IO.File]::Open($AuditPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        [void]$stream.Seek(-1, [System.IO.SeekOrigin]::End)
        $lastByte = $stream.ReadByte()
        if ($lastByte -ne 10 -and $lastByte -ne 13) { $prefix = [Environment]::NewLine }
      } finally { $stream.Dispose() }
    }
    [System.IO.File]::AppendAllText($AuditPath, $prefix + $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  }
}

function Get-RequestHeader {
  param([string]$Request, [string]$Name)

  foreach ($line in ($Request -split "`r?`n")) {
    $idx = $line.IndexOf(":")
    if ($idx -gt 0) {
      $headerName = $line.Substring(0, $idx).Trim()
      if ($headerName.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $line.Substring($idx + 1).Trim()
      }
    }
  }
  return $null
}

function Get-Sha256Hex {
  param([string]$Text)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-EditToken {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
    return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
  } finally {
    $rng.Dispose()
  }
}

function Get-EditProtectionConfig {
  param([string]$ConfigPath)

  $default = @{
    enabled = $false
    pinHash = ""
    hashAlgorithm = "SHA256"
    sessionMinutes = 120
  }

  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return $default
  }

  $configText = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
  $config = $configText | ConvertFrom-Json
  if ($null -eq $config.editProtection) {
    return $default
  }

  $minutes = 120
  if ($config.editProtection.sessionMinutes) {
    $minutes = [int]$config.editProtection.sessionMinutes
  }

  return @{
    enabled = [bool]$config.editProtection.enabled
    pinHash = [string]$config.editProtection.pinHash
    hashAlgorithm = if ($config.editProtection.hashAlgorithm) { [string]$config.editProtection.hashAlgorithm } else { "SHA256" }
    sessionMinutes = $minutes
  }
}

function Test-EditToken {
  param([string]$Token)

  if ([string]::IsNullOrWhiteSpace($Token)) {
    return $false
  }
  if (-not $script:EditSessions.ContainsKey($Token)) {
    return $false
  }
  if ([DateTime]$script:EditSessions[$Token] -lt (Get-Date)) {
    $script:EditSessions.Remove($Token)
    return $false
  }
  return $true
}

function Require-EditToken {
  param([string]$Request, [string]$ConfigPath)

  $editConfig = Get-EditProtectionConfig -ConfigPath $ConfigPath
  if (-not $editConfig.enabled -or [string]::IsNullOrWhiteSpace($editConfig.pinHash)) {
    return
  }

  $token = Get-RequestHeader -Request $Request -Name "X-Kanban-Edit-Token"
  if (-not (Test-EditToken -Token $token)) {
    throw "Editing is locked. Unlock editing before saving changes."
  }
}

function Unlock-Editing {
  param([string]$Body, [string]$ConfigPath)

  $editConfig = Get-EditProtectionConfig -ConfigPath $ConfigPath
  if (-not $editConfig.enabled -or [string]::IsNullOrWhiteSpace($editConfig.pinHash)) {
    $token = New-EditToken
    $expires = (Get-Date).AddMinutes([int]$editConfig.sessionMinutes)
    $script:EditSessions[$token] = $expires
    return @{ ok = $true; token = $token; expires = $expires.ToString("o"); unlocked = $true; warning = "Edit protection is not configured." }
  }

  if ($editConfig.hashAlgorithm -ne "SHA256") {
    throw "Unsupported edit PIN hash algorithm."
  }

  $payload = $Body | ConvertFrom-Json
  $pin = [string]$payload.pin
  if ([string]::IsNullOrEmpty($pin)) {
    throw "PIN is required."
  }

  $candidateHash = Get-Sha256Hex -Text $pin
  if (-not $candidateHash.Equals($editConfig.pinHash, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Incorrect edit PIN."
  }

  $token = New-EditToken
  $expires = (Get-Date).AddMinutes([int]$editConfig.sessionMinutes)
  $script:EditSessions[$token] = $expires
  return @{ ok = $true; token = $token; expires = $expires.ToString("o"); unlocked = $true }
}

function Assert-ProjectId {
  param([string]$ProjectId)
  if ([string]::IsNullOrWhiteSpace($ProjectId) -or $ProjectId.Length -gt 80 -or $ProjectId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
    throw "Invalid projectId. Use 1-80 lowercase letters, numbers and single hyphens only."
  }
  return $ProjectId
}

function Resolve-ProjectRelativePath {
  param([string]$ProjectId, [string]$RelativePath)
  if (-not [string]::IsNullOrWhiteSpace($ProjectId)) {
    $safeId = Assert-ProjectId -ProjectId $ProjectId
    return "project_files/$safeId"
  }
  if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Length -gt 94) { throw "projectId or relativePath is required." }
  if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains("\") -or $RelativePath.Contains(":") -or $RelativePath.Contains("..")) { throw "Invalid project folder relativePath." }
  if ($RelativePath -notmatch '^project_files/([a-z0-9]+(?:-[a-z0-9]+)*)$') { throw "relativePath must be project_files/<project-id>." }
  [void](Assert-ProjectId -ProjectId $matches[1])
  return "project_files/$($matches[1])"
}

function Get-QueryValues {
  param([string]$RawPath)
  $values = @{}
  $question = $RawPath.IndexOf("?")
  if ($question -lt 0 -or $question -eq $RawPath.Length - 1) { return $values }
  foreach ($part in $RawPath.Substring($question + 1).Split("&")) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $pair = $part.Split("=", 2)
    $name = [System.Uri]::UnescapeDataString($pair[0].Replace("+", " "))
    $value = if ($pair.Length -gt 1) { [System.Uri]::UnescapeDataString($pair[1].Replace("+", " ")) } else { "" }
    $values[$name] = $value
  }
  return $values
}

function Test-ReachableDirectory {
  param([string]$Path)
  try { return -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Container) } catch { return $false }
}

function Get-ProjectFolderLocation {
  param([string]$RelativePath)
  $relativeWindows = $RelativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  $teamAvailable = Test-ReachableDirectory -Path $TeamRoot
  $canonicalPath = Join-Path $TeamRoot $relativeWindows
  $localPath = Join-Path $SourceRoot $relativeWindows
  $warnings = @()
  $selectedPath = if ($teamAvailable) { $canonicalPath } else { "" }
  $usingLocalFallback = $false
  if (-not $teamAvailable) {
    $warnings += "Team ESMI source is unavailable. The shared canonical project folder cannot be reached."
  }
  return @{ teamAvailable = $teamAvailable; canonicalPath = $canonicalPath; localPath = $localPath; selectedPath = $selectedPath; usingLocalFallback = $usingLocalFallback; warnings = $warnings }
}

function Ensure-ProjectFolder {
  param([string]$Body)
  $payload = $Body | ConvertFrom-Json
  $projectId = Assert-ProjectId -ProjectId ([string]$payload.projectId)
  $projectName = ([string]$payload.projectName).Trim()
  if ([string]::IsNullOrWhiteSpace($projectName) -or $projectName.Length -gt 200) { throw "projectName is required and must be 200 characters or fewer." }
  $relativePath = Resolve-ProjectRelativePath -ProjectId $projectId
  $location = Get-ProjectFolderLocation -RelativePath $relativePath
  if ([string]::IsNullOrWhiteSpace($location.selectedPath)) { throw "Team ESMI source is unavailable. The shared canonical project folder cannot be reached; no local project folder was created." }
  $folderRoot = [System.IO.Path]::GetFullPath($location.selectedPath)
  $approvedSourceRoot = $TeamRoot
  $approvedRoot = [System.IO.Path]::GetFullPath((Join-Path $approvedSourceRoot "project_files"))
  $approvedPrefix = $approvedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $folderRoot.StartsWith($approvedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Resolved project folder is outside the approved project_files root." }
  $created = -not (Test-Path -LiteralPath $folderRoot -PathType Container)
  [System.IO.Directory]::CreateDirectory($folderRoot) | Out-Null
  foreach ($name in @("00_Admin", "01_Planning", "02_Delivery", "03_Meetings", "04_Risks-Issues-Decisions", "05_Evidence", "06_Closeout")) {
    [System.IO.Directory]::CreateDirectory((Join-Path $folderRoot $name)) | Out-Null
  }
  $readmePath = Join-Path $folderRoot "README.md"
  if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
    $createdAt = (Get-Date).ToString("o")
    $readme = @"
# $projectName

- Kanban project ID: $projectId
- Created: $createdAt
- Linked from: SAMI Kanban

This folder is linked from the SAMI Kanban. Store project documents and administration in 00_Admin, plans in 01_Planning, delivery artefacts in 02_Delivery, meeting notes in 03_Meetings, risks/issues/decisions in 04_Risks-Issues-Decisions, evidence in 05_Evidence, and closeout artefacts in 06_Closeout.
"@
    [System.IO.File]::WriteAllText($readmePath, $readme.TrimStart() + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  }
  return @{ ok = $true; created = $created; relativePath = $relativePath; canonicalPath = $location.canonicalPath; localPath = $location.localPath; warnings = $location.warnings }
}

function Get-ProjectFolderStatus {
  param([string]$ProjectId, [string]$RelativePath)
  $safeRelativePath = Resolve-ProjectRelativePath -ProjectId $ProjectId -RelativePath $RelativePath
  $location = Get-ProjectFolderLocation -RelativePath $safeRelativePath
  $existsCanonical = $location.teamAvailable -and (Test-Path -LiteralPath $location.canonicalPath -PathType Container)
  $existsLocal = -not $SourceRoot.Equals($TeamRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-ReachableDirectory -Path $SourceRoot) -and (Test-Path -LiteralPath $location.localPath -PathType Container)
  return @{ ok = $true; linked = $true; existsCanonical = [bool]$existsCanonical; existsLocal = [bool]$existsLocal; relativePath = $safeRelativePath; canonicalPath = $location.canonicalPath; warnings = $location.warnings }
}

function Open-ProjectFolder {
  param([string]$Body)
  $payload = $Body | ConvertFrom-Json
  $relativePath = Resolve-ProjectRelativePath -ProjectId ([string]$payload.projectId) -RelativePath ([string]$payload.relativePath)
  $location = Get-ProjectFolderLocation -RelativePath $relativePath
  if (-not $location.teamAvailable) { throw "Team ESMI source is unavailable. The shared canonical project folder cannot be reached; no local project folder was opened." }
  $target = if (Test-Path -LiteralPath $location.canonicalPath -PathType Container) { $location.canonicalPath } else { throw "The Team ESMI project folder does not exist: $($location.canonicalPath)" }
  $quotedTarget = '"' + $target + '"'
  Start-Process -FilePath "explorer.exe" -ArgumentList $quotedTarget
  return @{ ok = $true; opened = $true; relativePath = $relativePath; canonicalPath = $location.canonicalPath; localPath = $location.localPath; warnings = $location.warnings }
}

function Send-Response {
  param(
    [System.Net.Sockets.NetworkStream]$Stream,
    [int]$StatusCode,
    [string]$StatusText,
    [byte[]]$Body,
    [string]$ContentType = "text/plain; charset=utf-8",
    [bool]$HeadOnly = $false
  )

  $headers = @(
    "HTTP/1.1 $StatusCode $StatusText",
    "Content-Length: $($Body.Length)",
    "Content-Type: $ContentType",
    "Cache-Control: no-store",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"

  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if (-not $HeadOnly -and $Body.Length -gt 0) {
    $Stream.Write($Body, 0, $Body.Length)
  }
}

function Assert-ReadableFile {
  param([string]$Path, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Label not found: $Path"
  }
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $buffer = New-Object byte[] 1
    [void]$stream.Read($buffer, 0, 1)
  } finally {
    $stream.Dispose()
  }
}

$listener = $null

try {
  Write-ServerLog "=================================================="
  Write-ServerLog "SAMI Kanban server bootstrap entered"
  Write-ServerLog "Script path: $PSCommandPath"
  Write-ServerLog "Script root: $PSScriptRoot"
  Write-ServerLog "RootPath parameter: $RootPath"
  Write-ServerLog "Root parameter: $Root"
  Write-ServerLog "SourceRoot parameter: $SourceRoot"
  Write-ServerLog "TeamRoot parameter: $TeamRoot"
  Write-ServerLog "Port: $Port"
  Write-ServerLog "Requested log path: $LogPath"
  Write-ServerLog "Resolved log path: $script:LogPath"
  Write-ServerLog "Current user: $env:USERNAME"
  Write-ServerLog "Computer: $env:COMPUTERNAME"
  Write-ServerLog "Current directory: $((Get-Location).Path)"
  Write-ServerLog "PowerShell version: $($PSVersionTable.PSVersion)"

  if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
    $Root = $RootPath
  }

  if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path $env:LOCALAPPDATA "SAMI-Kanban-WorkServer\site"
  }

  $Root = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $rootPrefix = $Root + [System.IO.Path]::DirectorySeparatorChar
  Write-ServerLog "Resolved root path: $Root"

  if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = $Root
  }
  $SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  Write-ServerLog "Resolved source root: $SourceRoot"

  if ([string]::IsNullOrWhiteSpace($TeamRoot)) {
    $TeamRoot = $SourceRoot
  }
  $TeamRoot = [System.IO.Path]::GetFullPath($TeamRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  Write-ServerLog "Resolved Team ESMI root: $TeamRoot"

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "RootPath does not exist or is not a folder: $Root"
  }

  $indexPath = Join-Path $Root "index.html"
  $jsonPath = Join-Path $Root "data\projects.json"
  $auditPath = Join-Path $Root "data\card_updates.jsonl"
  $configPath = Join-Path $Root "data\kanban_config.json"
  $sourceJsonPath = Join-Path $SourceRoot "data\projects.json"
  $sourceAuditPath = Join-Path $SourceRoot "data\card_updates.jsonl"
  $sourceConfigPath = Join-Path $SourceRoot "data\kanban_config.json"
  $teamJsonPath = Join-Path $TeamRoot "data\projects.json"
  $teamAuditPath = Join-Path $TeamRoot "data\card_updates.jsonl"
  $teamConfigPath = Join-Path $TeamRoot "data\kanban_config.json"
  $authorityConfigPath = if (Test-Path -LiteralPath $teamConfigPath -PathType Leaf) { $teamConfigPath } else { $sourceConfigPath }
  Assert-ReadableFile -Path $indexPath -Label "index.html"
  Assert-ReadableFile -Path $jsonPath -Label "data\projects.json"
  Assert-ReadableFile -Path $sourceJsonPath -Label "source data\projects.json"
  Assert-ReadableFile -Path $teamJsonPath -Label "Team ESMI data\projects.json"
  Write-ServerLog "Root access check passed."
  Write-ServerLog "index.html readable: $indexPath"
  Write-ServerLog "data/projects.json readable: $jsonPath"
  Write-ServerLog "source data/projects.json readable: $sourceJsonPath"
  Write-ServerLog "Team ESMI data/projects.json readable: $teamJsonPath"

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
  Write-ServerLog "Attempting to bind TcpListener to 127.0.0.1:$Port"
  $listener.Start()
  Write-ServerLog "Listening on http://127.0.0.1:$Port"

  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 8192
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) {
        continue
      }

      $request = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
      $firstLine = ($request -split "`r?`n")[0]
      $parts = $firstLine -split " "
      $method = if ($parts.Length -gt 0) { $parts[0] } else { "GET" }
      $rawPath = if ($parts.Length -gt 1) { $parts[1] } else { "/" }
      $headOnly = $method -eq "HEAD"

      if ($method -eq "POST") {
        $pathOnly = ($rawPath -split "\?")[0]
        $requestBody = Read-RequestBody -Stream $stream -Request $request -InitialBuffer $buffer -InitialRead $read
        try {
          if ($pathOnly -eq "/api/projects") {
            Require-EditToken -Request $request -ConfigPath $authorityConfigPath
            Require-FreshProjectsSource -Request $request -SourceJsonPath $teamJsonPath
            Save-ProjectsJson -Body $requestBody -JsonPaths @($teamJsonPath, $sourceJsonPath, $jsonPath)
            $syncStatus = Get-SyncStatus -SourceJsonPath $teamJsonPath -LocalJsonPath $jsonPath -SourceAuditPath $teamAuditPath -LocalAuditPath $auditPath
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{ ok = $true; syncStatus = $syncStatus }
            Write-ServerLog "200 POST $rawPath -> $teamJsonPath, $sourceJsonPath and $jsonPath"
            continue
          }
          if ($pathOnly -eq "/api/card-updates") {
            Require-EditToken -Request $request -ConfigPath $authorityConfigPath
            Require-FreshProjectsSource -Request $request -SourceJsonPath $teamJsonPath
            Append-AuditEvent -Body $requestBody -AuditPaths @($teamAuditPath, $sourceAuditPath, $auditPath)
            $syncStatus = Get-SyncStatus -SourceJsonPath $teamJsonPath -LocalJsonPath $jsonPath -SourceAuditPath $teamAuditPath -LocalAuditPath $auditPath
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{ ok = $true; syncStatus = $syncStatus }
            Write-ServerLog "200 POST $rawPath -> $teamAuditPath, $sourceAuditPath and $auditPath"
            continue
          }
          if ($pathOnly -eq "/api/project-folder/ensure") {
            Require-EditToken -Request $request -ConfigPath $authorityConfigPath
            $folderPayload = Ensure-ProjectFolder -Body $requestBody
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $folderPayload
            Write-ServerLog "200 POST $rawPath -> $($folderPayload.relativePath)"
            continue
          }
          if ($pathOnly -eq "/api/project-folder/open") {
            $folderPayload = Open-ProjectFolder -Body $requestBody
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $folderPayload
            Write-ServerLog "200 POST $rawPath -> $($folderPayload.relativePath)"
            continue
          }
          if ($pathOnly -eq "/api/unlock") {
            $unlockPayload = Unlock-Editing -Body $requestBody -ConfigPath $authorityConfigPath
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $unlockPayload
            Write-ServerLog "200 POST $rawPath"
            continue
          }
          $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
          Send-Response -Stream $stream -StatusCode 404 -StatusText "Not Found" -Body $body
          Write-ServerLog "404 $method $rawPath"
          continue
        } catch {
          Write-ExceptionLog -Exception $_.Exception -Prefix "SAVE ERROR"
          $status = if ($_.Exception.Message -match "locked|PIN") { 401 } elseif ($_.Exception.Message -match "source changed|Refresh the board") { 409 } elseif ($_.Exception.Message -match "does not exist") { 404 } elseif ($_.Exception.Message -match "unavailable; no approved") { 503 } elseif ($_.Exception.Message -match "Invalid|must be|required|outside the approved") { 400 } else { 500 }
          $statusText = if ($status -eq 400) { "Bad Request" } elseif ($status -eq 401) { "Unauthorized" } elseif ($status -eq 404) { "Not Found" } elseif ($status -eq 409) { "Conflict" } elseif ($status -eq 503) { "Service Unavailable" } else { "Save Failed" }
          Send-Json -Stream $stream -StatusCode $status -StatusText $statusText -Payload @{ ok = $false; error = $_.Exception.Message }
          continue
        }
      }

      if ($method -ne "GET" -and $method -ne "HEAD") {
        $body = [System.Text.Encoding]::UTF8.GetBytes("Method not allowed")
        Send-Response -Stream $stream -StatusCode 405 -StatusText "Method Not Allowed" -Body $body -HeadOnly $headOnly
        Write-ServerLog "405 $method $rawPath"
        continue
      }

      $pathOnly = ($rawPath -split "\?")[0]
      if ($pathOnly -eq "/api/project-folder/status") {
        try {
          $query = Get-QueryValues -RawPath $rawPath
          $folderStatus = Get-ProjectFolderStatus -ProjectId ([string]$query["projectId"]) -RelativePath ([string]$query["relativePath"])
          Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $folderStatus
          Write-ServerLog "200 $method $rawPath"
        } catch {
          Write-ExceptionLog -Exception $_.Exception -Prefix "FOLDER STATUS ERROR"
          Send-Json -Stream $stream -StatusCode 400 -StatusText "Bad Request" -Payload @{ ok = $false; error = $_.Exception.Message }
        }
        continue
      }
      if ($pathOnly -eq "/api/sync-status") {
        $syncResult = Sync-TeamDataToLocalCopies -TeamJsonPath $teamJsonPath -RuntimeJsonPath $jsonPath -SourceJsonPath $sourceJsonPath -TeamAuditPath $teamAuditPath -RuntimeAuditPath $auditPath -SourceAuditPath $sourceAuditPath
        $syncStatus = Get-SyncStatus -SourceJsonPath $teamJsonPath -LocalJsonPath $jsonPath -SourceAuditPath $teamAuditPath -LocalAuditPath $auditPath -SyncResult $syncResult
        Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $syncStatus
        Write-ServerLog "200 $method $rawPath"
        continue
      }
      if ($pathOnly -eq "/api/user") {
        Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{ username = $(if ($env:USERNAME) { $env:USERNAME } else { "Unknown" }) }
        Write-ServerLog "200 $method $rawPath"
        continue
      }

      $decodedPath = [System.Uri]::UnescapeDataString($pathOnly).TrimStart("/")
      if ([string]::IsNullOrWhiteSpace($decodedPath)) {
        $decodedPath = "index.html"
      }

      $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $decodedPath))
      if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and -not $candidate.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $body = [System.Text.Encoding]::UTF8.GetBytes("Forbidden")
        Send-Response -Stream $stream -StatusCode 403 -StatusText "Forbidden" -Body $body -HeadOnly $headOnly
        Write-ServerLog "403 $method $rawPath"
        continue
      }

      if ((Test-Path -LiteralPath $candidate -PathType Container)) {
        $candidate = Join-Path $candidate "index.html"
      }

      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        if ($pathOnly -eq "/data/projects.json" -or $pathOnly -eq "/data/card_updates.jsonl") {
          [void](Sync-TeamDataToLocalCopies -TeamJsonPath $teamJsonPath -RuntimeJsonPath $jsonPath -SourceJsonPath $sourceJsonPath -TeamAuditPath $teamAuditPath -RuntimeAuditPath $auditPath -SourceAuditPath $sourceAuditPath)
        }
        $body = [System.IO.File]::ReadAllBytes($candidate)
        Send-Response -Stream $stream -StatusCode 200 -StatusText "OK" -Body $body -ContentType (Get-MimeType $candidate) -HeadOnly $headOnly
        Write-ServerLog "200 $method $rawPath -> $candidate"
      } else {
        $body = [System.Text.Encoding]::UTF8.GetBytes("Not found")
        Send-Response -Stream $stream -StatusCode 404 -StatusText "Not Found" -Body $body -HeadOnly $headOnly
        Write-ServerLog "404 $method $rawPath"
      }
    } catch {
      Write-ExceptionLog -Exception $_.Exception -Prefix "REQUEST ERROR"
    } finally {
      $client.Close()
    }
  }
} catch {
  Write-ExceptionLog -Exception $_.Exception -Prefix "STARTUP ERROR"
  exit 1
} finally {
  if ($listener -ne $null) {
    $listener.Stop()
    Write-ServerLog "Server stopped"
  }
}
