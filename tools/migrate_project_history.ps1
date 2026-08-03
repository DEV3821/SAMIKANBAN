[CmdletBinding()]
param(
  [string]$CanonicalRoot = '',
  [switch]$Apply,
  [switch]$EstablishFileBaseline,
  [string]$ExpectedProjectsRevision = '',
  [string]$MigrationId = 'project-history-baseline-v1',
  [string]$TrustedTimestamp = '',
  [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = $env:SAMI_KANBAN_CANONICAL_ROOT }
if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = $env:SAMI_KANBAN_TEAM_ROOT }
if ([string]::IsNullOrWhiteSpace($CanonicalRoot)) { $CanonicalRoot = '\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer' }
$CanonicalRoot = [System.IO.Path]::GetFullPath($CanonicalRoot).TrimEnd('\', '/')
$ProjectsPath = Join-Path $CanonicalRoot 'data\projects.json'
$IndexPath = Join-Path $CanonicalRoot 'data\project_file_index.json'
$AuditPath = Join-Path $CanonicalRoot 'data\card_updates.jsonl'
$StatePath = Join-Path $CanonicalRoot 'data\project_history_migration.json'
$BoardOrderPath = Join-Path $CanonicalRoot 'data\board_order.json'

function Get-Property($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}
function Has-Property($Object, [string]$Name) { return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] }
function Set-Property($Object, [string]$Name, $Value) { if (Has-Property $Object $Name) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value } }
function Sha256([string]$Text) { $sha=[Security.Cryptography.SHA256]::Create();try{return([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()} }
function Get-Revision([string]$Path) { if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''};$i=Get-Item -LiteralPath $Path;return $i.LastWriteTimeUtc.ToString('o')+'|'+(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Normalise-NextAction($Value) { if($null -eq $Value){return ''};return ([string]$Value).Replace("`r`n","`n").Replace("`r","`n").Trim() }
function Get-NextAction($Card) { if(Has-Property $Card 'nextAction'){return [string](Get-Property $Card 'nextAction')};if(Has-Property $Card 'next'){return [string](Get-Property $Card 'next')};return '' }
function Write-AtomicText([string]$Path,[string]$Text) { $dir=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $dir -PathType Container)){New-Item -ItemType Directory -Path $dir -Force|Out-Null};$tmp=$Path+'.migration-'+[guid]::NewGuid().ToString('n');try{[IO.File]::WriteAllText($tmp,$Text,[Text.UTF8Encoding]::new($false));if(Test-Path -LiteralPath $Path -PathType Leaf){try{[IO.File]::Replace($tmp,$Path,$null,$true)}catch{Move-Item -LiteralPath $tmp -Destination $Path -Force}}else{[IO.File]::Move($tmp,$Path)}}finally{if(Test-Path -LiteralPath $tmp -PathType Leaf){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}} }
function Backup-File([string]$Path) { if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''};$backup=$Path+'.migration-backup-'+(Get-Date -Format yyyyMMdd-HHmmss);[IO.File]::Copy($Path,$backup,$false);return $backup }

function Validate-Projects($Root) {
  if($null -eq $Root -or $null -eq $Root.projects){throw 'Canonical projects root must contain a projects array.'}
  $cards=@($Root.projects);$ids=@{};foreach($card in $cards){if($null -eq $card){throw 'Canonical projects contains a null card.'};$id=[string](Get-Property $card 'id');if([string]::IsNullOrWhiteSpace($id)){throw 'Canonical card IDs must be nonblank.'};if($ids.ContainsKey($id)){throw "Duplicate card ID: $id"};$ids[$id]=$true}
  return $cards
}
function Get-Snapshot($Card) {
  $s=[ordered]@{};foreach($pair in @(@('status','status'),@('health','riskColour'),@('owner','owner'),@('projectLead','projectLead'),@('reviewDate','reviewDate'),@('blocker','blockerReason'))){$v=Get-Property $Card $pair[1];if($null -ne $v-and-not[string]::IsNullOrWhiteSpace([string]$v)){$s[$pair[0]]=[string]$v}};return $s
}
function Get-BaselineEntry($Card,[string]$Timestamp,[string]$SourceRevision) {
  $id=[string](Get-Property $Card 'id');$action=Get-NextAction $Card;$changeId='migration:'+ $MigrationId + ':' + $id
  return [pscustomobject][ordered]@{id='history-migration-'+(Sha256 $changeId).Substring(0,24);type='next_action_baseline';occurredAt=$Timestamp;changeId=$changeId;nextAction=$action;resultingProjectsRevision=$SourceRevision;snapshot=Get-Snapshot $Card}
}
function Get-ExistingHistory($Card) { $raw=Get-Property $Card 'projectHistory';if($null -eq $raw){return @()};return @($raw) }
function Get-CardInvariantSignature($Card) {
  $copy=[ordered]@{}
  foreach($property in @($Card.PSObject.Properties)) {
    if([string]$property.Name -in @('projectHistory','projectHistorySchemaVersion')) { continue }
    $copy[[string]$property.Name]=$property.Value
  }
  return ($copy|ConvertTo-Json -Depth 50 -Compress)
}
function Get-IndexEntries($Index) {
  $cards=Get-Property $Index 'cards';if($cards -is [Array]){return @($cards|ForEach-Object{[pscustomobject]@{key=[string](Get-Property $_ 'cardId');entry=$_}})};if($null -eq $cards){return @()};return @($cards.PSObject.Properties|ForEach-Object{[pscustomobject]@{key=[string]$_.Name;entry=$_.Value}})
}
function Get-IndexEntry($Index,[string]$CardId){foreach($x in @(Get-IndexEntries $Index)){if($x.key -eq $CardId -or [string](Get-Property $x.entry 'cardId') -eq $CardId){return $x.entry}};return $null}
function Set-IndexEntry($Index,[string]$CardId,$Entry){$cards=Get-Property $Index 'cards';if($cards-is[Array]){$a=@($cards);$found=$false;for($i=0;$i-lt$a.Count;$i++){if([string](Get-Property $a[$i] 'cardId')-eq$CardId){$a[$i]=$Entry;$found=$true;break}};if(-not$found){$a+=$Entry};Set-Property $Index 'cards' $a}else{if(Has-Property $cards $CardId){$cards.$CardId=$Entry}else{$cards|Add-Member -NotePropertyName $CardId -NotePropertyValue $Entry}}}
function Is-IgnoredFile($Item,[string]$Rel){$n=[string]$Item.Name;$e=[string]$Item.Extension;if($Item.Attributes-band[IO.FileAttributes]::Hidden){return $true};if($n-like'~$*'){return $true};if($e.ToLowerInvariant()-in@('.tmp','.temp','.partial','.crdownload','.download','.lock','.bak','.swp')){return $true};if($Rel-match'(?i)(^|/)(deployment[_ -]?backup|backups?|logs?)(/|$)'){return $true};return $false}
function Inventory-Folder([string]$FolderPath,[string]$CardId,[ref]$IgnoredCount) {
  $result = New-Object Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) { return @() }
  foreach ($item in @(Get-ChildItem -LiteralPath $FolderPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
    $rel = $item.FullName.Substring($FolderPath.Length).TrimStart('\','/').Replace('\','/')
    if (Is-IgnoredFile $item $rel) { $IgnoredCount.Value++; continue }
    $last = $item.LastWriteTimeUtc.ToString('o')
    $ext = [string]$item.Extension
    $friendly = if ($ext) { $ext.TrimStart('.').ToUpperInvariant() + ' file' } else { 'File' }
    $fp = Sha256 "$CardId|$rel|$($item.Length)|$last"
    [void]$result.Add([pscustomobject][ordered]@{ name=[string]$item.Name; relativePath=$rel; extension=$ext; friendlyType=$friendly; size=[int64]$item.Length; lastWriteTime=$last; fingerprint=$fp })
  }
  return $result.ToArray()
}

if(-not(Test-Path -LiteralPath $ProjectsPath -PathType Leaf)){throw "Canonical projects file not found: $ProjectsPath"}
$initialRevision=Get-Revision $ProjectsPath
if ($Apply -and [string]::IsNullOrWhiteSpace($ExpectedProjectsRevision)) { throw 'Apply requires -ExpectedProjectsRevision from a read-only preview.' }
if ($Apply -and $ExpectedProjectsRevision -ne $initialRevision) { throw "Canonical projects revision changed between preview and apply. Expected $ExpectedProjectsRevision, found $initialRevision." }
$root=Get-Content -LiteralPath $ProjectsPath -Raw -Encoding UTF8|ConvertFrom-Json;$cards=Validate-Projects $root
$cardInvariantBefore=@{};foreach($card in $cards){$cardInvariantBefore[[string]$card.id]=Get-CardInvariantSignature $card}
$metaBefore=if($null -eq (Get-Property $root 'meta')){''}else{ConvertTo-Json (Get-Property $root 'meta') -Depth 50 -Compress}
$boardOrderBeforeExists=Test-Path -LiteralPath $BoardOrderPath -PathType Leaf;$boardOrderBefore=if($boardOrderBeforeExists){[IO.File]::ReadAllText($BoardOrderPath,[Text.Encoding]::UTF8)}else{''}
$noteBefore=@{}
foreach($card in $cards){
  $noteBefore[[string]$card.id] = if(Has-Property $card 'notes'){[string](Get-Property $card 'notes')}else{$null}
}
$withAction=@($cards | Where-Object { (Normalise-NextAction (Get-NextAction $_)).Length -gt 0 })
$withoutAction=$cards.Count-$withAction.Count
$withNotes=@($cards | Where-Object { (Has-Property $_ 'notes') -and $null -ne (Get-Property $_ 'notes') -and [string](Get-Property $_ 'notes') -ne '' }).Count
$withHistory=@($cards | Where-Object { Has-Property $_ 'projectHistory' }).Count
$baselineProposed=0
$baselineEntries=New-Object Collections.Generic.List[object]
$migrationTimestamp=if($TrustedTimestamp){$TrustedTimestamp}else{[DateTimeOffset]::Now.ToString('o')}
foreach($card in $withAction){
  $history=Get-ExistingHistory $card
  $hasBaseline=@($history | Where-Object { [string](Get-Property $_ 'type') -eq 'next_action_baseline' }).Count -gt 0
  if(-not $hasBaseline){
    $baselineProposed++
    [void]$baselineEntries.Add((Get-BaselineEntry $card $migrationTimestamp $initialRevision))
  }
}
$indexPresent=Test-Path -LiteralPath $IndexPath -PathType Leaf;$index=$null;$indexValid=$false;$indexEntryCount=0;$linkedFolders=0;$unmappedFolders=0;$existingFiles=0;$ignoredFiles=0;$fileBaselineProposed=0;$baselineFilesByCard=@{}
if($indexPresent){try{$index=Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8|ConvertFrom-Json;$indexValid=$null-ne$index.cards-and(($index.cards-is[Array])-or($index.cards-is[pscustomobject]));$indexEntryCount=@(Get-IndexEntries $index).Count}catch{$indexValid=$false}}
if($EstablishFileBaseline-and-not$indexValid){throw 'Cannot establish a file baseline because project_file_index.json is missing or structurally invalid.'}
$mapped=@{};foreach($card in $cards){$folder=Get-Property $card 'folder';$rel=[string](Get-Property $folder 'relativePath');if($rel-match'^project_files/[A-Za-z0-9][A-Za-z0-9_-]*$'){if($mapped.ContainsKey($rel.ToLowerInvariant())){$mapped[$rel.ToLowerInvariant()]=$null}else{$mapped[$rel.ToLowerInvariant()]=$card;$linkedFolders++}}}
$projectFilesRoot=Join-Path $CanonicalRoot 'project_files';if(Test-Path -LiteralPath $projectFilesRoot -PathType Container){foreach($dir in @(Get-ChildItem -LiteralPath $projectFilesRoot -Directory -Force -ErrorAction SilentlyContinue)){if(-not$mapped.ContainsKey(('project_files/'+$dir.Name).ToLowerInvariant())-or$null-eq$mapped[('project_files/'+$dir.Name).ToLowerInvariant()]){$unmappedFolders++}}}
$baselineAlreadyDone=$false;if($indexValid){$baselineAlreadyDone=Has-Property $index 'fileBaselineCompletedAt'-and-not[string]::IsNullOrWhiteSpace([string](Get-Property $index 'fileBaselineCompletedAt'))}
if($EstablishFileBaseline-and-not$baselineAlreadyDone){foreach($pair in @($mapped.GetEnumerator())){if($null-eq$pair.Value){continue};$folderPath=Join-Path $CanonicalRoot $pair.Key.Replace('/','\');$found=@(Inventory-Folder -FolderPath $folderPath -CardId ([string]$pair.Value.id) -IgnoredCount ([ref]$ignoredFiles));$existingFiles+=$found.Count;$entry=Get-IndexEntry $index ([string]$pair.Value.id);$known=@();if($entry-and(Has-Property $entry 'files')){$known=@(Get-Property $entry 'files')};$knownFp=@{};foreach($f in $known){$knownFp[[string](Get-Property $f 'fingerprint')]=$true};$new=@($found|Where-Object{-not$knownFp.ContainsKey([string]$_.fingerprint)});$baselineFilesByCard[[string]$pair.Value.id]=$new;$fileBaselineProposed+=$new.Count}}
else{foreach($pair in @($mapped.GetEnumerator())){if($null-eq$pair.Value){continue};$folderPath=Join-Path $CanonicalRoot $pair.Key.Replace('/','\');$found=@(Inventory-Folder -FolderPath $folderPath -CardId ([string]$pair.Value.id) -IgnoredCount ([ref]$ignoredFiles));$existingFiles+=$found.Count}}

$report=[ordered]@{mode=if($Apply){'apply'}else{'preview'};canonicalRoot=$CanonicalRoot;projectsPath=$ProjectsPath;sourceProjectsRevision=$initialRevision;totalCards=$cards.Count;cardsWithCurrentNextAction=$withAction.Count;cardsWithoutNextAction=$withoutAction;cardsWithManualNotes=$withNotes;cardsAlreadyContainingProjectHistory=$withHistory;duplicateIds=0;invalidCardStructures=0;baselineNextActionEventsProposed=$baselineProposed;projectFileIndexPresent=$indexPresent;projectFileIndexStructurallyValid=$indexValid;projectFileIndexEntries=$indexEntryCount;linkedFolders=$linkedFolders;unmappedFolders=$unmappedFolders;existingFilesDiscovered=$existingFiles;filesIgnoredAsTemporary=$ignoredFiles;fileBaselineEntriesProposed=$fileBaselineProposed;historicalFileAddedEventsGenerated=0;notesPreservedExactly=$true;idempotent=$false}
if(-not$Apply){$report.previewOnly=$true;$report.expectedProjectsRevisionForApply=$initialRevision;if($ReportPath){$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$report|ConvertTo-Json -Depth 20;exit 0}

$state=$null;if(Test-Path -LiteralPath $StatePath -PathType Leaf){try{$state=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json}catch{throw 'Migration state file is malformed.'}}
if($state-and[string](Get-Property $state 'migrationId')-eq$MigrationId-and[string](Get-Property $state 'schemaVersion')-eq'1'){$report.idempotent=$true;$report.baselineNextActionEventsProposed=0;$report.fileBaselineEntriesProposed=0;$report.migrationStatePath=$StatePath;$report|ConvertTo-Json -Depth 20;exit 0}
$beforeProjects=[IO.File]::ReadAllText($ProjectsPath,[Text.Encoding]::UTF8);$beforeAudit=if(Test-Path -LiteralPath $AuditPath -PathType Leaf){[IO.File]::ReadAllText($AuditPath,[Text.Encoding]::UTF8)}else{''};$beforeIndex=if($indexValid){[IO.File]::ReadAllText($IndexPath,[Text.Encoding]::UTF8)}else{$null};$beforeState=if(Test-Path -LiteralPath $StatePath -PathType Leaf){[IO.File]::ReadAllText($StatePath,[Text.Encoding]::UTF8)}else{$null};$backupProjects=Backup-File $ProjectsPath;$backupAudit=if(Test-Path -LiteralPath $AuditPath -PathType Leaf){Backup-File $AuditPath}else{''};$backupIndex=if($EstablishFileBaseline){Backup-File $IndexPath}else{''};$backupState=if($beforeState -ne $null){Backup-File $StatePath}else{''}
try{
  $timestamp=$migrationTimestamp;$auditLines=New-Object Collections.Generic.List[string]
  foreach($entry in $baselineEntries){$card=@($cards|Where-Object{[string]$_.id -eq ([string]$entry.changeId).Substring(([string]$entry.changeId).LastIndexOf(':')+1)}|Select-Object -First 1);if($card.Count){$target=$card[0];$history=Get-ExistingHistory $target;Set-Property $target 'projectHistorySchemaVersion' 1;Set-Property $target 'projectHistory' (@($history)+$entry);$audit=[ordered]@{timestamp=$timestamp;cardId=[string]$target.id;cardTitle=[string]$target.title;action='next_action_recorded';subtype='baseline';changeId=[string]$entry.changeId;source='migration'};$auditLines.Add((ConvertTo-Json $audit -Compress))|Out-Null}}
  $projectsText=($root|ConvertTo-Json -Depth 50)+[Environment]::NewLine;$auditText=$beforeAudit;foreach($line in $auditLines){if($auditText-and-not$auditText.EndsWith("`n")-and-not$auditText.EndsWith("`r")){$auditText+=[Environment]::NewLine};$auditText+=$line+[Environment]::NewLine}
  $indexText=$null;if($EstablishFileBaseline){foreach($pair in @($baselineFilesByCard.GetEnumerator())){$entry=Get-IndexEntry $index ([string]$pair.Key);if($null-eq$entry){$entry=[pscustomobject][ordered]@{cardId=[string]$pair.Key;files=@()};Set-IndexEntry $index ([string]$pair.Key) $entry};$known=@();if(Has-Property $entry 'files'){$known=@(Get-Property $entry 'files')};Set-Property $entry 'files' (@($known)+@($pair.Value));Set-Property $entry 'fileCount' (@($known)+@($pair.Value)).Count};Set-Property $index 'projectFileBaselineSchemaVersion' 1;Set-Property $index 'fileBaselineCompletedAt' $timestamp;$oldIndexRevision=0;[void][int]::TryParse([string](Get-Property $index 'indexRevision'),[ref]$oldIndexRevision);Set-Property $index 'indexRevision' ($oldIndexRevision+1);Set-Property $index 'generatedAt' $timestamp;$indexText=($index|ConvertTo-Json -Depth 50)+[Environment]::NewLine}
  Write-AtomicText $ProjectsPath $projectsText;if($AuditPath){Write-AtomicText $AuditPath $auditText};if($indexText){Write-AtomicText $IndexPath $indexText}
  $afterRevision=Get-Revision $ProjectsPath;$statePayload=[ordered]@{schemaVersion=1;migrationId=$MigrationId;completedAt=$timestamp;sourceProjectsRevision=$initialRevision;resultingProjectsRevision=$afterRevision;baselineCardCount=$baselineProposed;fileBaselineCount=$fileBaselineProposed};Write-AtomicText $StatePath (($statePayload|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
  $afterRoot=Get-Content -LiteralPath $ProjectsPath -Raw -Encoding UTF8|ConvertFrom-Json;$afterCards=Validate-Projects $afterRoot;$afterById=@{};foreach($afterCard in $afterCards){$id=[string]$afterCard.id;if($afterById.ContainsKey($id)){throw "Duplicate card ID after migration: $id"};$afterById[$id]=$afterCard;if(-not $cardInvariantBefore.ContainsKey($id)){throw "Migration introduced an unexpected card: $id"};if((Get-CardInvariantSignature $afterCard) -ne [string]$cardInvariantBefore[$id]){throw "Migration changed non-history fields for card $id."};$afterNote=if(Has-Property $afterCard 'notes'){[string](Get-Property $afterCard 'notes')}else{$null};$beforeNote=[string]$noteBefore[$id];if(-not [string]::Equals($afterNote,$beforeNote,[System.StringComparison]::Ordinal)){throw "Manual Notes changed during migration for card $id."}};if($afterById.Count -ne $cardInvariantBefore.Count){throw 'Migration changed the canonical card count.'};$metaAfter=if($null -eq (Get-Property $afterRoot 'meta')){''}else{ConvertTo-Json (Get-Property $afterRoot 'meta') -Depth 50 -Compress};if($metaAfter -ne $metaBefore){throw 'Migration changed the projects meta object.'};$boardOrderAfterExists=Test-Path -LiteralPath $BoardOrderPath -PathType Leaf;$boardOrderAfter=if($boardOrderAfterExists){[IO.File]::ReadAllText($BoardOrderPath,[Text.Encoding]::UTF8)}else{''};if($boardOrderAfterExists -ne $boardOrderBeforeExists -or $boardOrderAfter -ne $boardOrderBefore){throw 'Migration changed board_order.json.'}
  $backupList=@($backupProjects,$backupAudit,$backupIndex,$backupState)|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)};$report.migrationStatePath=$StatePath;$report.resultingProjectsRevision=$afterRevision;$report.migrationId=$MigrationId;$report.appliedBaselineCardCount=$baselineProposed;$report.appliedFileBaselineCount=$fileBaselineProposed;$report.backups=@($backupList);$report|ConvertTo-Json -Depth 20
}catch{try{Write-AtomicText $ProjectsPath $beforeProjects;if($AuditPath){Write-AtomicText $AuditPath $beforeAudit};if($EstablishFileBaseline-and$beforeIndex){Write-AtomicText $IndexPath $beforeIndex};if($null-ne$beforeState){Write-AtomicText $StatePath $beforeState}elseif(Test-Path -LiteralPath $StatePath -PathType Leaf){Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue}}catch{};throw}
