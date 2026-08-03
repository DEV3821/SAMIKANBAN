param(
  [string]$TempRoot = '',
  [switch]$NoBrowser,
  [switch]$AutoUnlock
)
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$powerShellExe = (Get-Command powershell.exe).Source
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SAMI-browser-fixture-' + [Guid]::NewGuid().ToString('N'))
}
$canonicalRoot = Join-Path $TempRoot 'canonical'
$runtimeRoot = Join-Path $TempRoot 'runtime-a'
$runtimeRootB = Join-Path $TempRoot 'runtime-b'
$profileRootA = Join-Path $TempRoot 'edge-profile-a'
$profileRootB = Join-Path $TempRoot 'edge-profile-b'
$logPath = Join-Path $TempRoot 'server-a.log'
$logPathB = Join-Path $TempRoot 'server-b.log'
$dataRoot = Join-Path $canonicalRoot 'data'

New-Item -ItemType Directory -Path $dataRoot, (Join-Path $canonicalRoot 'project_files'), (Join-Path $runtimeRoot 'data'), (Join-Path $runtimeRoot 'project_files'), (Join-Path $runtimeRootB 'data'), (Join-Path $runtimeRootB 'project_files'), $profileRootA, $profileRootB -Force | Out-Null
foreach ($relative in @('index.html','serve_kanban.ps1','meeting_pack.ps1','manifest.webmanifest','data\app_version.json')) {
  $canonicalDestination = Join-Path $canonicalRoot $relative
  New-Item -ItemType Directory -Path (Split-Path -Parent $canonicalDestination) -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $canonicalDestination -Force
}
foreach ($runtime in @($runtimeRoot, $runtimeRootB)) {
  foreach ($relative in @('index.html','manifest.webmanifest','data\app_version.json')) {
    $destination = Join-Path $runtime $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $destination -Force
  }
  Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination (Join-Path $runtime 'assets') -Recurse -Force
}

$projects = [ordered]@{
  meta = @{ name = 'Synthetic two-client browser fixture'; source = 'isolated-fixture' }
  projects = @(
    @{ id='browser-alpha'; title='Browser Alpha'; status='running'; lead='Synthetic A'; context='Synthetic browser fixture'; nextAction='Reorder and edit this card'; notes='Initial synthetic notes'; lastUpdated='2026-08-03T10:00:00+09:30' },
    @{ id='browser-beta'; title='Browser Beta'; status='running'; lead='Synthetic B'; context='Synthetic browser fixture'; nextAction='Remain second'; notes='Initial synthetic notes'; lastUpdated='2026-08-03T10:00:00+09:30' },
    @{ id='browser-gamma'; title='Browser Gamma'; status='backlog'; lead='Synthetic C'; context='Synthetic browser fixture'; nextAction='Remain in backlog'; notes='Initial synthetic notes'; lastUpdated='2026-08-03T10:00:00+09:30' }
  )
}
$jsonEncoding = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path $dataRoot 'projects.json'), (($projects | ConvertTo-Json -Depth 30) + [Environment]::NewLine), $jsonEncoding)
[System.IO.File]::WriteAllText((Join-Path $dataRoot 'card_updates.jsonl'), '', $jsonEncoding)
foreach ($projectId in @('browser-alpha','browser-beta','browser-gamma')) {
  New-Item -ItemType Directory -Path (Join-Path $canonicalRoot ('project_files\' + $projectId)) -Force | Out-Null
}

function Get-FreePort {
  $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $portProbe.Start()
  $port = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
  $portProbe.Stop()
  return $port
}

function Start-FixtureServer {
  param([string]$Runtime, [string]$Log)
  $port = Get-FreePort
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -SourceRoot "{2}" -TeamRoot "{3}" -CanonicalRoot "{3}" -LocalMirrorRoot "{1}" -RuntimeMode team-canonical -Port {4} -LogPath "{5}"' -f (Join-Path $repoRoot 'serve_kanban.ps1'), $Runtime, $repoRoot, $canonicalRoot, $port, $Log
  $process = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $url = "http://127.0.0.1:$port"
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    Start-Sleep -Milliseconds 200
    try {
      $health = Invoke-WebRequest -UseBasicParsing -Uri "$url/api/health" -TimeoutSec 2
      if ($health.StatusCode -eq 200) { return [pscustomobject]@{ Process = $process; Port = $port; Url = $url; Log = $Log } }
    } catch { }
    if ($process.HasExited) { throw "SAMI server exited before becoming healthy. Log: $Log" }
  }
  throw "SAMI server did not become healthy. Log: $Log"
}

function Resolve-EdgeExecutable {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
  )
  foreach ($candidate in $candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate } }
  $command = Get-Command msedge.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  throw 'Microsoft Edge executable was not found for the two-client browser fixture.'
}

$serverA = Start-FixtureServer -Runtime $runtimeRoot -Log $logPath
$serverB = Start-FixtureServer -Runtime $runtimeRootB -Log $logPathB
$edgeA = $null
$edgeB = $null
if (-not $NoBrowser) {
  $edge = Resolve-EdgeExecutable
  $autoUnlockQuery = if ($AutoUnlock) { '&samiAutoUnlock=1' } else { '' }
  $urlA = $serverA.Url + '/?samiTest=1&samiClientLabel=Client%20A&samiSessionId=fixture-client-a' + $autoUnlockQuery
  $urlB = $serverB.Url + '/?samiTest=1&samiClientLabel=Client%20B&samiSessionId=fixture-client-b' + $autoUnlockQuery
  $edgeA = Start-Process -FilePath $edge -ArgumentList @('--user-data-dir=' + $profileRootA, '--app=' + $urlA) -PassThru
  $edgeB = Start-Process -FilePath $edge -ArgumentList @('--user-data-dir=' + $profileRootB, '--app=' + $urlB) -PassThru
}
$reportedUrlA = $serverA.Url + '/?samiTest=1&samiClientLabel=Client%20A&samiSessionId=fixture-client-a' + $(if ($AutoUnlock) { '&samiAutoUnlock=1' } else { '' })
$reportedUrlB = $serverB.Url + '/?samiTest=1&samiClientLabel=Client%20B&samiSessionId=fixture-client-b' + $(if ($AutoUnlock) { '&samiAutoUnlock=1' } else { '' })
Write-Output "BROWSER_FIXTURE_ROOT=$TempRoot"
Write-Output "BROWSER_FIXTURE_CLIENT_A_LABEL=Client A"
Write-Output "BROWSER_FIXTURE_CLIENT_A_URL=$reportedUrlA"
Write-Output "BROWSER_FIXTURE_CLIENT_A_SERVER_PID=$($serverA.Process.Id)"
Write-Output "BROWSER_FIXTURE_CLIENT_A_EDGE_PID=$(if ($edgeA) { $edgeA.Id } else { '' })"
Write-Output "BROWSER_FIXTURE_CLIENT_A_RUNTIME=$runtimeRoot"
Write-Output "BROWSER_FIXTURE_CLIENT_A_SESSION=fixture-client-a"
Write-Output "BROWSER_FIXTURE_CLIENT_B_LABEL=Client B"
Write-Output "BROWSER_FIXTURE_CLIENT_B_URL=$reportedUrlB"
Write-Output "BROWSER_FIXTURE_CLIENT_B_SERVER_PID=$($serverB.Process.Id)"
Write-Output "BROWSER_FIXTURE_CLIENT_B_EDGE_PID=$(if ($edgeB) { $edgeB.Id } else { '' })"
Write-Output "BROWSER_FIXTURE_CLIENT_B_RUNTIME=$runtimeRootB"
Write-Output "BROWSER_FIXTURE_CLIENT_B_SESSION=fixture-client-b"
