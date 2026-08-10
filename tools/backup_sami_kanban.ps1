[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\SAMI_KANBAN',
    [int]$RetentionDays = 30
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ExtendedPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) {
        return ('\\?\UNC\' + $full.Substring(2))
    }
    return ('\\?\' + $full)
}

function Get-LongFileHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open(
        (ConvertTo-ExtendedPath $Path),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$backupRoot = [IO.Path]::GetFullPath((Join-Path $root 'backups')).TrimEnd('\')
$logRoot = Join-Path $root 'logs'
$logPath = Join-Path $logRoot 'kanban_backup.log'
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'

if (-not (Test-Path -LiteralPath (Join-Path $root 'data') -PathType Container)) {
    throw "Kanban data directory is missing: $root\data"
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'project_files') -PathType Container)) {
    throw "Kanban project-files directory is missing: $root\project_files"
}
New-Item -ItemType Directory -Force -Path $backupRoot, $logRoot | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destination = Join-Path $backupRoot "live-$stamp"
New-Item -ItemType Directory -Force -Path $destination | Out-Null

function Write-BackupLog {
    param([string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $logPath -Value $line
    Write-Output $line
}

$copySummaries = @()
foreach ($relativePath in @('data', 'project_files')) {
    $source = Join-Path $root $relativePath
    $target = Join-Path $destination $relativePath
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Write-BackupLog "Starting one-way backup: $source -> $target"
    & $robocopy $source $target /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /Z /XJ /MT:8 /TEE "/LOG+:$logPath"
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "Robocopy failed for $relativePath with exit code $exitCode"
    }
    $copySummaries += [pscustomobject]@{
        RelativePath = $relativePath
        ExitCode = $exitCode
    }
    Write-BackupLog "Completed one-way backup: $relativePath (Robocopy exit $exitCode)"
}

$manifest = @{
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    installRoot = $root
    destination = $destination
    retentionDays = $RetentionDays
    copySummaries = $copySummaries
    criticalHashes = @{}
}
foreach ($relativePath in @('data\projects.json', 'data\card_updates.jsonl', 'data\board_order.json', 'data\kanban_config.json')) {
    $path = Join-Path $destination $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $manifest.criticalHashes[$relativePath] = Get-LongFileHash $path
    }
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $destination 'backup-manifest.json') -Encoding UTF8

$cutoff = (Get-Date).AddDays(-1 * [Math]::Max(1, $RetentionDays))
foreach ($oldBackup in @(Get-ChildItem -LiteralPath $backupRoot -Directory -Filter 'live-*' -ErrorAction SilentlyContinue)) {
    if ($oldBackup.Name -notmatch '^live-\d{8}-\d{6}$' -or $oldBackup.LastWriteTime -ge $cutoff) {
        continue
    }
    $oldPath = [IO.Path]::GetFullPath($oldBackup.FullName).TrimEnd('\')
    if (-not $oldPath.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove backup outside the backup root: $oldPath"
    }
    Write-BackupLog "Removing expired local backup: $oldPath"
    [IO.Directory]::Delete((ConvertTo-ExtendedPath $oldPath), $true)
}

Write-BackupLog "Backup completed: $destination"
Write-Output ($manifest | ConvertTo-Json -Depth 6)
