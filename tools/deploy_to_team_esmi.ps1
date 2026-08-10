[CmdletBinding()]
param(
  [string]$SourcePath = 'C:\Tools\SAMI-Kanban-WorkServer',
  [string]$TeamRoot,
  [string]$Version,
  [string]$Message = 'SAMI Project Portfolio update'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($TeamRoot)) { $TeamRoot = $env:SAMI_KANBAN_TEAM_ROOT }
if ([string]::IsNullOrWhiteSpace($TeamRoot)) { throw 'Team ESMI path is required. Set SAMI_KANBAN_TEAM_ROOT or run with -TeamRoot.' }
$SourcePath = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\')
$TeamRoot = [System.IO.Path]::GetFullPath($TeamRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "Source path not found: $SourcePath" }
if (-not (Test-Path -LiteralPath $TeamRoot -PathType Container)) { throw "Team ESMI path not found: $TeamRoot" }
if ($SourcePath.Equals($TeamRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'SourcePath and TeamRoot must be different folders.' }
if ([System.IO.Path]::GetFileName($TeamRoot) -ne 'SAMI-Kanban-WorkServer') { throw "TeamRoot must be the SAMI-Kanban-WorkServer application folder: $TeamRoot" }

$sourceVersion = Join-Path $SourcePath 'data\app_version.json'
$sourceVersionPayload = Get-Content -LiteralPath $sourceVersion -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$sourceVersionPayload.version }
if ([string]$sourceVersionPayload.version -ne $Version) { throw "Requested version '$Version' does not match source app_version.json '$($sourceVersionPayload.version)'." }
$installerPayloadVersion = Join-Path $SourcePath 'dist\SAMI_Project_Portfolio_User_Installer\payload\data\app_version.json'
if (Test-Path -LiteralPath $installerPayloadVersion -PathType Leaf) {
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourceVersion).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $installerPayloadVersion).Hash) {
    throw 'Packaged app_version.json does not match the validated source release.'
  }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $TeamRoot "backups\app-deploy-$stamp"
$files = @(
  'index.html','manifest.webmanifest','serve_kanban.ps1','meeting_pack.ps1','run_kanban.bat','run_kanban_debug.bat','run_kanban_silent.vbs',
  'install_sami_project_portfolio.ps1','tools\bootstrap_kanban.ps1','tools\setup_meeting_pack_pin.ps1','tools\launch_sami_portfolio.vbs','tools\install_sami_kanban_hosted_shortcut.ps1',
  'tools\deploy_to_team_esmi.ps1','Repair_SAMI_Project_Portfolio_Icon.ps1','Repair_SAMI_Project_Portfolio_Icon.bat',
  'data\app_version.json','README.md','assets\README.md','docs\SAMI_Kanban_Client_Launcher_Runbook.md'
)
$protected = '^(?i)(data\\(?:projects(?:\.example)?\.json|card_updates\.jsonl|kanban_config\.json|project_file_index\.json|card_activity_index\.json)|project_files(?:\\|$)|backups(?:\\|$)|logs(?:\\|$))'

function Deploy-File {
  param([string]$RelativePath, [string]$SourceFile)
  if ($RelativePath -match $protected) { throw "Protected runtime path rejected: $RelativePath" }
  $source = if ($SourceFile) { [System.IO.Path]::GetFullPath($SourceFile) } else { [System.IO.Path]::GetFullPath((Join-Path $SourcePath $RelativePath)) }
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return }
  $destination = [System.IO.Path]::GetFullPath((Join-Path $TeamRoot $RelativePath))
  $teamPrefix = $TeamRoot + '\'
  if (-not $destination.StartsWith($teamPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Destination escaped TeamRoot: $destination" }
  if (Test-Path -LiteralPath $destination -PathType Leaf) {
    $backup = Join-Path $backupRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
    Copy-Item -LiteralPath $destination -Destination $backup
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
  Write-Host "DEPLOYED $RelativePath"
}

foreach ($relative in $files) { Deploy-File $relative }
$assetRoot = Join-Path $SourcePath 'assets'
if (Test-Path -LiteralPath $assetRoot -PathType Container) {
  Get-ChildItem -LiteralPath $assetRoot -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring($SourcePath.Length).TrimStart('\')
    Deploy-File $relative
  }
}

$installerSource = Join-Path $SourcePath 'dist\SAMI_Project_Portfolio_User_Installer'
if (Test-Path -LiteralPath $installerSource -PathType Container) {
  Get-ChildItem -LiteralPath $installerSource -File -Recurse | ForEach-Object {
    $installerRelative = $_.FullName.Substring($installerSource.Length).TrimStart('\')
    Deploy-File -RelativePath (Join-Path 'installers\SAMI_Project_Portfolio_User_Installer' $installerRelative) -SourceFile $_.FullName
  }
}

Write-Host "Deployment complete. Backup: $backupRoot"
