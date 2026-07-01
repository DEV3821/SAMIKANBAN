param(
  [string]$RootPath,
  [string]$Root,
  [string]$SourceRoot,
  [string]$TeamRoot = "",
  [string]$CanonicalRoot = "",
  [string]$LocalMirrorRoot = "",
  [ValidateSet('team-canonical','local-fallback','offline','error')]
  [string]$RuntimeMode = "",
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
$script:StartedAt = (Get-Date).ToString("o")
$script:ServerScriptHash = try { (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() } catch { "unknown" }

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
    ".webmanifest" { "application/manifest+json; charset=utf-8"; break }
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

function Get-AppVersion {
  param([string]$WebRoot)
  try {
    $versionPath = Join-Path $WebRoot "data\app_version.json"
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { return "unknown" }
    $payload = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$payload.version)) { return "unknown" }
    return [string]$payload.version
  } catch {
    return "unknown"
  }
}

function Get-AppVersionMetadata {
  param([string]$AppRoot)
  $versionPath = Join-Path $AppRoot "data\app_version.json"
  $revision = Get-FileRevisionInfo -Path $versionPath
  $result = @{ exists = [bool]$revision.exists; version = "unknown"; updatedAt = $revision.lastWriteUtc; path = $versionPath; error = "" }
  if (-not $revision.exists) { return $result }
  try {
    $payload = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.version)) { $result.version = ([string]$payload.version).Trim() }
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.releasedAt)) { $result.updatedAt = [string]$payload.releasedAt }
  } catch {
    $result.error = $_.Exception.Message
  }
  return $result
}

function Get-AppVersionStatus {
  [void](Update-TeamReachability)
  $runtime = Get-AppVersionMetadata -AppRoot $Root
  $canonical = Get-AppVersionMetadata -AppRoot $script:CanonicalRoot
  $appFiles = @('index.html', 'manifest.webmanifest', 'serve_kanban.ps1', 'tools\bootstrap_kanban.ps1')
  $comparisons = @()
  $filesDiffer = $false
  $canonicalFileIsNewer = $false
  foreach ($relativePath in $appFiles) {
    $runtimeFile = Get-FileRevisionInfo -Path (Join-Path $Root $relativePath)
    $canonicalFile = Get-FileRevisionInfo -Path (Join-Path $script:CanonicalRoot $relativePath)
    $matches = $runtimeFile.exists -and $canonicalFile.exists -and $runtimeFile.hash -eq $canonicalFile.hash
    if ($script:TeamReachable -and $canonicalFile.exists -and -not $matches) { $filesDiffer = $true }
    if ($script:TeamReachable -and $canonicalFile.exists -and -not $matches -and $canonicalFile.lastWriteUtc -and
        (-not $runtimeFile.lastWriteUtc -or [DateTime]$canonicalFile.lastWriteUtc -gt [DateTime]$runtimeFile.lastWriteUtc)) {
      $canonicalFileIsNewer = $true
    }
    $comparisons += @{
      path = $relativePath
      runtimeExists = [bool]$runtimeFile.exists
      canonicalExists = [bool]$canonicalFile.exists
      matches = [bool]$matches
      runtimeHash = $runtimeFile.hash
      canonicalHash = $canonicalFile.hash
    }
  }
  $runtimeVersionKnown = $runtime.version -ne 'unknown'
  $canonicalVersionKnown = $canonical.version -ne 'unknown'
  $versionsEqual = $runtimeVersionKnown -and $canonicalVersionKnown -and $runtime.version -eq $canonical.version
  $canonicalVersionIsNewer = $canonicalVersionKnown -and (-not $runtimeVersionKnown -or
    [string]::Compare($canonical.version, $runtime.version, [System.StringComparison]::OrdinalIgnoreCase) -gt 0)
  $hashIndicatesUpdate = $filesDiffer -and ($versionsEqual -or (-not $runtimeVersionKnown -and -not $canonicalVersionKnown -and $canonicalFileIsNewer))
  $updateAvailable = [bool]($script:TeamReachable -and ($canonicalVersionIsNewer -or $hashIndicatesUpdate))
  $message = if (-not $script:TeamReachable) {
    'Team ESMI is unavailable; app update status could not be checked'
  } elseif ($updateAvailable) {
    'Update available from Team ESMI'
  } else {
    'SAMI Project Portfolio is current'
  }
  return @{
    ok = $true
    mode = $script:EffectiveMode
    teamReachable = [bool]$script:TeamReachable
    runtimeVersion = $runtime.version
    canonicalVersion = $canonical.version
    runtimeUpdatedAt = $runtime.updatedAt
    canonicalUpdatedAt = $canonical.updatedAt
    updateAvailable = $updateAvailable
    requiresRestart = $updateAvailable
    message = $message
    canonicalRoot = $script:CanonicalRoot
    runtimeRoot = $Root
    appFiles = $comparisons
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

function Test-FileWritableWithoutChange {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stream.Dispose()
    return $true
  } catch { return $false }
}

function Test-DirectoryWritableFromAcl {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$sids.Add($identity.User.Value)
    foreach ($group in $identity.Groups) { [void]$sids.Add($group.Value) }
    $acl = Get-Acl -LiteralPath $Path
    $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    $writeMask = [System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor [System.Security.AccessControl.FileSystemRights]::CreateDirectories
    $allowed = $false
    foreach ($rule in $rules) {
      if (-not $sids.Contains($rule.IdentityReference.Value) -or -not ($rule.FileSystemRights -band $writeMask)) { continue }
      if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) { return $false }
      if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) { $allowed = $true }
    }
    return $allowed
  } catch { return $false }
}

function Get-CanonicalFileStatus {
  param([string]$Path)
  $revision = Get-FileRevisionInfo -Path $Path
  return @{
    path = $Path
    readable = [bool]$revision.exists
    writable = Test-FileWritableWithoutChange -Path $Path
    timestamp = $revision.lastWriteUtc
    lastWriteUtc = $revision.lastWriteUtc
    hash = $revision.hash
    length = $revision.length
  }
}

function Update-TeamReachability {
  if ($script:LastTeamCheck -and ((Get-Date) - $script:LastTeamCheck).TotalSeconds -lt 15) { return $script:TeamReachable }
  $script:TeamReachable = (Test-ReachableDirectory -Path $script:CanonicalRoot) -and
    (Test-Path -LiteralPath $script:CanonicalProjectsPath -PathType Leaf) -and
    (Test-Path -LiteralPath $script:CanonicalAuditPath -PathType Leaf) -and
    (Test-Path -LiteralPath $script:CanonicalProjectFilesRoot -PathType Container)
  if ($script:TeamReachable) { $script:EffectiveMode = 'team-canonical' }
  elseif ($script:ConfiguredMode -eq 'local-fallback') { $script:EffectiveMode = 'local-fallback' }
  else { $script:EffectiveMode = 'offline' }
  $script:LastTeamCheck = Get-Date
  return $script:TeamReachable
}

function Copy-CanonicalFileToRuntime {
  param([string]$CanonicalPath, [string]$RuntimePath, [string]$Label)
  if (-not (Test-Path -LiteralPath $CanonicalPath -PathType Leaf)) { throw "Canonical $Label is missing: $CanonicalPath" }
  $parent = Split-Path -Parent $RuntimePath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $copyNeeded = -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)
  if (-not $copyNeeded) { $copyNeeded = (Get-FileRevisionInfo $CanonicalPath).hash -ne (Get-FileRevisionInfo $RuntimePath).hash }
  if ($copyNeeded) {
    Backup-Once -Path $RuntimePath
    [System.IO.File]::Copy($CanonicalPath, $RuntimePath, $true)
    Write-ServerLog "Canonical-to-runtime sync copied ${Label}: $CanonicalPath -> $RuntimePath"
    return $true
  }
  return $false
}

function Sync-CanonicalToRuntime {
  $result = @{ projectsCopied=$false; auditCopied=$false; skipped='' }
  if (-not (Update-TeamReachability)) { $result.skipped = 'team_unreachable'; return $result }
  $result.projectsCopied = Copy-CanonicalFileToRuntime -CanonicalPath $script:CanonicalProjectsPath -RuntimePath $script:RuntimeProjectsPath -Label 'projects.json'
  $result.auditCopied = Copy-CanonicalFileToRuntime -CanonicalPath $script:CanonicalAuditPath -RuntimePath $script:RuntimeAuditPath -Label 'card_updates.jsonl'
  return $result
}

function Get-SyncStatus {
  param([hashtable]$SyncResult = $null)
  if ($null -eq $SyncResult) { $SyncResult = @{ projectsCopied=$false; auditCopied=$false; skipped='' } }
  [void](Update-TeamReachability)
  $projects = Get-CanonicalFileStatus -Path $script:CanonicalProjectsPath
  $audit = Get-CanonicalFileStatus -Path $script:CanonicalAuditPath
  $runtimeProjects = Get-FileRevisionInfo -Path $script:RuntimeProjectsPath
  $runtimeAudit = Get-FileRevisionInfo -Path $script:RuntimeAuditPath
  $projectFilesExists = Test-Path -LiteralPath $script:CanonicalProjectFilesRoot -PathType Container
  return @{
    ok = $true
    mode = $script:EffectiveMode
    canonicalRoot = $script:CanonicalRoot
    runtimeRoot = $Root
    localMirrorRoot = $script:LocalMirrorRoot
    teamReachable = [bool]$script:TeamReachable
    projectsJson = $projects
    cardUpdatesJsonl = $audit
    projectFiles = @{
      path = $script:CanonicalProjectFilesRoot
      exists = [bool]$projectFilesExists
      readable = [bool]$projectFilesExists
      writable = Test-DirectoryWritableFromAcl -Path $script:CanonicalProjectFilesRoot
    }
    lastChecked = (Get-Date).ToString('o')
    source = @{ projects=@{ exists=$projects.readable; path=$projects.path; lastWriteUtc=$projects.lastWriteUtc; hash=$projects.hash; length=$projects.length }; audit=@{ exists=$audit.readable; path=$audit.path; lastWriteUtc=$audit.lastWriteUtc; hash=$audit.hash; length=$audit.length } }
    local = @{ projects=$runtimeProjects; audit=$runtimeAudit }
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
  $teamAvailable = Update-TeamReachability
  $canonicalPath = [System.IO.Path]::GetFullPath((Join-Path $script:CanonicalRoot $relativeWindows))
  $localPath = [System.IO.Path]::GetFullPath((Join-Path $script:LocalMirrorRoot $relativeWindows))
  $warnings = @()
  $usingLocalFallback = -not $teamAvailable -and $script:EffectiveMode -eq 'local-fallback'
  $selectedPath = if ($teamAvailable) { $canonicalPath } elseif ($usingLocalFallback) { $localPath } else { "" }
  if (-not $teamAvailable) {
    $warnings += "Team ESMI is not confirmed. Any local folder is local-only fallback and is not synced."
  }
  return @{ teamAvailable = $teamAvailable; canonicalPath = $canonicalPath; localPath = $localPath; selectedPath = $selectedPath; usingLocalFallback = $usingLocalFallback; warnings = $warnings }
}

function Get-ProjectCardById {
  param([string]$ProjectId)
  $safeId = Assert-ProjectId -ProjectId $ProjectId
  $projectsPath = if ($script:TeamReachable) { $script:CanonicalProjectsPath } else { $script:RuntimeProjectsPath }
  if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) { throw "Projects data is unavailable: $projectsPath" }
  $payload = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json
  $card = @($payload.projects | Where-Object { [string]$_.id -eq $safeId }) | Select-Object -First 1
  if ($null -eq $card) { throw "Project card was not found: $safeId" }
  return $card
}

function Get-ProjectCardByFolderPath {
  param([string]$RelativePath)
  $projectsPath = if ($script:TeamReachable) { $script:CanonicalProjectsPath } else { $script:RuntimeProjectsPath }
  if (-not (Test-Path -LiteralPath $projectsPath -PathType Leaf)) { throw "Projects data is unavailable: $projectsPath" }
  $payload = Get-Content -LiteralPath $projectsPath -Raw | ConvertFrom-Json
  $card = @($payload.projects | Where-Object { $_.folder -and ([string]$_.folder.relativePath).Equals($RelativePath, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
  if ($null -eq $card) { throw "Project card was not found for folder: $RelativePath" }
  return $card
}

function Write-FolderOperationLog {
  param([string]$Operation, [string]$ProjectId, [string]$CardTitle, [string]$RelativePath, [string]$ResolvedPath, [string]$Status)
  Write-ServerLog "$Operation cardId='$ProjectId' cardTitle='$CardTitle' relativePath='$RelativePath' canonicalProjectFilesRoot='$($script:CanonicalProjectFilesRoot)' localProjectFilesRoot='$($script:LocalProjectFilesRoot)' resolvedPath='$ResolvedPath' teamReachable=$($script:TeamReachable) status='$Status'"
}

function Ensure-ProjectFolder {
  param([string]$Body)
  $payload = $Body | ConvertFrom-Json
  $projectId = Assert-ProjectId -ProjectId ([string]$payload.projectId)
  $projectName = ([string]$payload.projectName).Trim()
  if ([string]::IsNullOrWhiteSpace($projectName) -or $projectName.Length -gt 200) { throw "projectName is required and must be 200 characters or fewer." }
  $relativePath = Resolve-ProjectRelativePath -ProjectId $projectId
  $location = Get-ProjectFolderLocation -RelativePath $relativePath
  if ([string]::IsNullOrWhiteSpace($location.selectedPath)) {
    Write-FolderOperationLog -Operation 'folder ensure blocked' -ProjectId $projectId -CardTitle $projectName -RelativePath $relativePath -ResolvedPath '' -Status 'orange'
    throw "Team ESMI is unreachable and explicit local fallback is not active; no project folder was created."
  }
  $folderRoot = [System.IO.Path]::GetFullPath($location.selectedPath)
  $approvedRoot = if ($location.teamAvailable) { $script:CanonicalProjectFilesRoot } else { $script:LocalProjectFilesRoot }
  $approvedRoot = [System.IO.Path]::GetFullPath($approvedRoot)
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
  $colour = if ($location.teamAvailable) { 'green' } else { 'orange' }
  $source = if ($location.teamAvailable) { 'team-esmi' } else { 'local-fallback' }
  Write-FolderOperationLog -Operation 'folder ensure' -ProjectId $projectId -CardTitle $projectName -RelativePath $relativePath -ResolvedPath $folderRoot -Status $colour
  return @{ ok = $true; created = $created; relativePath = $relativePath; canonicalPath = $location.canonicalPath; localPath = $location.localPath; resolvedPath = $folderRoot; source = $source; statusColor = $colour; teamReachable = [bool]$location.teamAvailable; warnings = $location.warnings }
}

function Get-ProjectFolderStatus {
  param([string]$ProjectId, [string]$RelativePath)
  [void](Update-TeamReachability)
  $safeRelativePath = Resolve-ProjectRelativePath -ProjectId '' -RelativePath $RelativePath
  $card = if ([string]::IsNullOrWhiteSpace($ProjectId)) { Get-ProjectCardByFolderPath -RelativePath $safeRelativePath } else { Get-ProjectCardById -ProjectId $ProjectId }
  $ProjectId = [string]$card.id
  if ($card.folder -and [string]$card.folder.relativePath -and -not ([string]$card.folder.relativePath).Equals($safeRelativePath, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Requested folder path does not match the project card metadata." }
  $location = Get-ProjectFolderLocation -RelativePath $safeRelativePath
  $existsCanonical = $location.teamAvailable -and (Test-Path -LiteralPath $location.canonicalPath -PathType Container)
  $existsLocal = Test-Path -LiteralPath $location.localPath -PathType Container
  $colour = if ($existsCanonical) { 'green' } else { 'orange' }
  $message = if ($existsCanonical) { 'Files folder is on Team ESMI' } else { 'Files folder is local-only or Team ESMI could not be confirmed' }
  Write-FolderOperationLog -Operation 'folder status' -ProjectId $ProjectId -CardTitle ([string]$card.title) -RelativePath $safeRelativePath -ResolvedPath $(if ($existsCanonical) { $location.canonicalPath } else { $location.localPath }) -Status $colour
  return @{ ok = $true; linked = $true; statusColor = $colour; message = $message; source = $(if ($existsCanonical) { 'team-esmi' } else { $script:EffectiveMode }); teamReachable = [bool]$location.teamAvailable; existsCanonical = [bool]$existsCanonical; existsLocal = [bool]$existsLocal; relativePath = $safeRelativePath; canonicalPath = $location.canonicalPath; localPath = $location.localPath; warnings = $location.warnings }
}

function Open-ProjectFolder {
  param([string]$Body)
  $payload = $Body | ConvertFrom-Json
  [void](Update-TeamReachability)
  $relativePath = Resolve-ProjectRelativePath -ProjectId '' -RelativePath ([string]$payload.relativePath)
  $card = if ([string]::IsNullOrWhiteSpace([string]$payload.projectId)) { Get-ProjectCardByFolderPath -RelativePath $relativePath } else { Get-ProjectCardById -ProjectId ([string]$payload.projectId) }
  $projectId = Assert-ProjectId -ProjectId ([string]$card.id)
  if ($card.folder -and [string]$card.folder.relativePath -and -not ([string]$card.folder.relativePath).Equals($relativePath, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Requested folder path does not match the project card metadata." }
  $location = Get-ProjectFolderLocation -RelativePath $relativePath
  if (-not $location.teamAvailable) {
    Write-FolderOperationLog -Operation 'folder open blocked' -ProjectId $projectId -CardTitle ([string]$card.title) -RelativePath $relativePath -ResolvedPath $location.localPath -Status 'orange'
    return @{ ok=$true; opened=$false; statusColor='orange'; source=$script:EffectiveMode; teamReachable=$false; relativePath=$relativePath; canonicalPath=$location.canonicalPath; localPath=$location.localPath; warnings=$location.warnings }
  }
  $target = if (Test-Path -LiteralPath $location.canonicalPath -PathType Container) { $location.canonicalPath } else { throw "The Team ESMI project folder does not exist: $($location.canonicalPath)" }
  $quotedTarget = '"' + $target + '"'
  Start-Process -FilePath "explorer.exe" -ArgumentList $quotedTarget
  Write-FolderOperationLog -Operation 'folder open' -ProjectId $projectId -CardTitle ([string]$card.title) -RelativePath $relativePath -ResolvedPath $target -Status 'green'
  return @{ ok = $true; opened = $true; openedPath = $target; source = 'team-esmi'; statusColor = 'green'; teamReachable=$true; relativePath = $relativePath; canonicalPath = $location.canonicalPath; localPath = $location.localPath; warnings = $location.warnings }
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
  Write-ServerLog "CanonicalRoot parameter: $CanonicalRoot"
  Write-ServerLog "LocalMirrorRoot parameter: $LocalMirrorRoot"
  Write-ServerLog "RuntimeMode parameter: $RuntimeMode"
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
    $SourceRoot = $PSScriptRoot
  }
  $SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  Write-ServerLog "Resolved script/app root: $SourceRoot"

  if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = $env:SAMI_KANBAN_CANONICAL_ROOT }
  if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = $TeamRoot }
  if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = $env:SAMI_KANBAN_TEAM_ROOT }
  if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = '\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer' }
  $CanonicalRoot = [System.IO.Path]::GetFullPath($CanonicalRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $TeamRoot = $CanonicalRoot
  if ([string]::IsNullOrWhiteSpace($LocalMirrorRoot)) { $LocalMirrorRoot = $Root }
  $LocalMirrorRoot = [System.IO.Path]::GetFullPath($LocalMirrorRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  if ([string]::IsNullOrWhiteSpace($RuntimeMode)) { $RuntimeMode = $env:SAMI_KANBAN_RUNTIME_MODE }
  if ([string]::IsNullOrWhiteSpace($RuntimeMode)) { $RuntimeMode = 'offline' }

  $script:CanonicalRoot = $CanonicalRoot
  $script:LocalMirrorRoot = $LocalMirrorRoot
  $script:ConfiguredMode = $RuntimeMode
  $script:EffectiveMode = $RuntimeMode
  $script:TeamReachable = $RuntimeMode -eq 'team-canonical'
  $script:LastTeamCheck = Get-Date
  $script:CanonicalProjectsPath = Join-Path $CanonicalRoot 'data\projects.json'
  $script:CanonicalAuditPath = Join-Path $CanonicalRoot 'data\card_updates.jsonl'
  $script:CanonicalConfigPath = Join-Path $CanonicalRoot 'data\kanban_config.json'
  $script:CanonicalProjectFilesRoot = Join-Path $CanonicalRoot 'project_files'
  $script:RuntimeProjectsPath = Join-Path $Root 'data\projects.json'
  $script:RuntimeAuditPath = Join-Path $Root 'data\card_updates.jsonl'
  $script:RuntimeConfigPath = Join-Path $Root 'data\kanban_config.json'
  $script:LocalProjectFilesRoot = Join-Path $LocalMirrorRoot 'project_files'
  [void](Update-TeamReachability)
  Write-ServerLog "Canonical Team ESMI root: $CanonicalRoot"
  Write-ServerLog "Runtime root: $Root"
  Write-ServerLog "Local mirror root: $LocalMirrorRoot"
  Write-ServerLog "Team ESMI reachable: $($script:TeamReachable)"
  Write-ServerLog "Selected mode: $($script:EffectiveMode)"

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "RootPath does not exist or is not a folder: $Root"
  }

  $indexPath = Join-Path $Root "index.html"
  $jsonPath = $script:RuntimeProjectsPath
  $auditPath = $script:RuntimeAuditPath
  $configPath = $script:RuntimeConfigPath
  $teamJsonPath = $script:CanonicalProjectsPath
  $teamAuditPath = $script:CanonicalAuditPath
  $teamConfigPath = $script:CanonicalConfigPath
  $authorityJsonPath = if ($script:TeamReachable) { $teamJsonPath } else { $jsonPath }
  $authorityAuditPath = if ($script:TeamReachable) { $teamAuditPath } else { $auditPath }
  $authorityConfigPath = if ($script:TeamReachable -and (Test-Path -LiteralPath $teamConfigPath -PathType Leaf)) { $teamConfigPath } else { $configPath }
  if ($script:TeamReachable) { [void](Sync-CanonicalToRuntime) }
  Assert-ReadableFile -Path $indexPath -Label "index.html"
  Assert-ReadableFile -Path $jsonPath -Label "data\projects.json"
  if ($script:TeamReachable) { Assert-ReadableFile -Path $teamJsonPath -Label "Team ESMI data\projects.json" }
  Write-ServerLog "Root access check passed."
  Write-ServerLog "index.html readable: $indexPath"
  Write-ServerLog "runtime data/projects.json readable: $jsonPath"
  Write-ServerLog "canonical data/projects.json readable=$([bool](Test-Path -LiteralPath $teamJsonPath -PathType Leaf)) writable=$(Test-FileWritableWithoutChange $teamJsonPath): $teamJsonPath"
  Write-ServerLog "canonical data/card_updates.jsonl readable=$([bool](Test-Path -LiteralPath $teamAuditPath -PathType Leaf)) writable=$(Test-FileWritableWithoutChange $teamAuditPath): $teamAuditPath"
  Write-ServerLog "canonical project_files readable=$([bool](Test-Path -LiteralPath $script:CanonicalProjectFilesRoot -PathType Container)) writable=$(Test-DirectoryWritableFromAcl $script:CanonicalProjectFilesRoot): $($script:CanonicalProjectFilesRoot)"

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
            [void](Update-TeamReachability)
            if (-not $script:TeamReachable -and $script:EffectiveMode -ne 'local-fallback') { throw "Team ESMI is unreachable and local fallback writes are not enabled." }
            $authorityConfigPath = if ($script:TeamReachable -and (Test-Path -LiteralPath $teamConfigPath -PathType Leaf)) { $teamConfigPath } else { $configPath }
            Require-EditToken -Request $request -ConfigPath $authorityConfigPath
            $authorityJsonPath = if ($script:TeamReachable) { $teamJsonPath } else { $jsonPath }
            Require-FreshProjectsSource -Request $request -SourceJsonPath $authorityJsonPath
            $savePaths = if ($script:TeamReachable) { @($teamJsonPath, $jsonPath) } else { @($jsonPath) }
            Save-ProjectsJson -Body $requestBody -JsonPaths $savePaths
            $syncStatus = Get-SyncStatus
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{ ok = $true; syncStatus = $syncStatus }
            Write-ServerLog "200 POST $rawPath mode=$($script:EffectiveMode) -> $($savePaths -join ', ')"
            continue
          }
          if ($pathOnly -eq "/api/card-updates") {
            [void](Update-TeamReachability)
            if (-not $script:TeamReachable -and $script:EffectiveMode -ne 'local-fallback') { throw "Team ESMI is unreachable and local fallback writes are not enabled." }
            $authorityConfigPath = if ($script:TeamReachable -and (Test-Path -LiteralPath $teamConfigPath -PathType Leaf)) { $teamConfigPath } else { $configPath }
            Require-EditToken -Request $request -ConfigPath $authorityConfigPath
            $authorityJsonPath = if ($script:TeamReachable) { $teamJsonPath } else { $jsonPath }
            Require-FreshProjectsSource -Request $request -SourceJsonPath $authorityJsonPath
            $auditPaths = if ($script:TeamReachable) { @($teamAuditPath, $auditPath) } else { @($auditPath) }
            Append-AuditEvent -Body $requestBody -AuditPaths $auditPaths
            $syncStatus = Get-SyncStatus
            Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{ ok = $true; syncStatus = $syncStatus }
            Write-ServerLog "200 POST $rawPath mode=$($script:EffectiveMode) -> $($auditPaths -join ', ')"
            continue
          }
          if ($pathOnly -eq "/api/project-folder/ensure") {
            [void](Update-TeamReachability)
            $authorityConfigPath = if ($script:TeamReachable -and (Test-Path -LiteralPath $teamConfigPath -PathType Leaf)) { $teamConfigPath } else { $configPath }
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
            [void](Update-TeamReachability)
            $authorityConfigPath = if ($script:TeamReachable -and (Test-Path -LiteralPath $teamConfigPath -PathType Leaf)) { $teamConfigPath } else { $configPath }
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
          $status = if ($_.Exception.Message -match "locked|PIN") { 401 } elseif ($_.Exception.Message -match "source changed|Refresh the board") { 409 } elseif ($_.Exception.Message -match "does not exist|was not found") { 404 } elseif ($_.Exception.Message -match "unreachable|unavailable") { 503 } elseif ($_.Exception.Message -match "Invalid|must be|required|outside the approved|does not match") { 400 } else { 500 }
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
      if ($pathOnly -eq "/api/health") {
        [void](Update-TeamReachability)
        Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload @{
          ok = $true
          app = "SAMI Project Portfolio"
          port = $Port
          pid = $PID
          root = $Root
          startedAt = $script:StartedAt
          appVersion = Get-AppVersion -WebRoot $Root
          serverScriptHash = $script:ServerScriptHash
          mode = $script:EffectiveMode
          canonicalRoot = $script:CanonicalRoot
          runtimeRoot = $Root
          localMirrorRoot = $script:LocalMirrorRoot
          teamReachable = [bool]$script:TeamReachable
        }
        Write-ServerLog "200 $method $rawPath"
        continue
      }
      if ($pathOnly -eq "/api/project-folder/status") {
        try {
          $query = Get-QueryValues -RawPath $rawPath
          $folderStatus = Get-ProjectFolderStatus -ProjectId ([string]$query["projectId"]) -RelativePath ([string]$query["relativePath"])
          Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $folderStatus
          Write-ServerLog "200 $method $rawPath"
        } catch {
          Write-ExceptionLog -Exception $_.Exception -Prefix "FOLDER STATUS ERROR"
          Send-Json -Stream $stream -StatusCode 400 -StatusText "Bad Request" -Payload @{ ok = $false; statusColor = 'red'; message = 'Folder check failed'; error = $_.Exception.Message }
        }
        continue
      }
      if ($pathOnly -eq "/api/sync-status") {
        $syncResult = Sync-CanonicalToRuntime
        $syncStatus = Get-SyncStatus -SyncResult $syncResult
        Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $syncStatus
        Write-ServerLog "200 $method $rawPath"
        continue
      }
      if ($pathOnly -eq "/api/app-version/status") {
        $appVersionStatus = Get-AppVersionStatus
        Send-Json -Stream $stream -StatusCode 200 -StatusText "OK" -Payload $appVersionStatus
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
          [void](Sync-CanonicalToRuntime)
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
