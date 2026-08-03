param([string]$TempRoot = '')
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$powerShellExe = (Get-Command powershell.exe).Source
if ([string]::IsNullOrWhiteSpace($TempRoot)) {
  $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SAMI-browser-fixture-' + [Guid]::NewGuid().ToString('N'))
}
$canonicalRoot = Join-Path $TempRoot 'canonical'
$runtimeRoot = Join-Path $TempRoot 'runtime-a'
$logPath = Join-Path $TempRoot 'server.log'
$dataRoot = Join-Path $canonicalRoot 'data'

New-Item -ItemType Directory -Path $dataRoot, (Join-Path $canonicalRoot 'project_files'), (Join-Path $runtimeRoot 'data'), (Join-Path $runtimeRoot 'project_files') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'index.html') -Destination (Join-Path $runtimeRoot 'index.html') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'index.html') -Destination (Join-Path $canonicalRoot 'index.html') -Force

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

$portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -SourceRoot "{2}" -TeamRoot "{3}" -CanonicalRoot "{3}" -LocalMirrorRoot "{1}" -RuntimeMode team-canonical -Port {4} -LogPath "{5}"' -f (Join-Path $repoRoot 'serve_kanban.ps1'), $runtimeRoot, $repoRoot, $canonicalRoot, $port, $logPath
$server = Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
$url = "http://127.0.0.1:$port"
for ($attempt = 0; $attempt -lt 60; $attempt++) {
  Start-Sleep -Milliseconds 200
  try {
    $health = Invoke-WebRequest -UseBasicParsing -Uri "$url/api/health" -TimeoutSec 2
    if ($health.StatusCode -eq 200) {
      Write-Output "BROWSER_FIXTURE_ROOT=$TempRoot"
      Write-Output "BROWSER_FIXTURE_URL=$url"
      Write-Output "BROWSER_FIXTURE_PID=$($server.Id)"
      exit 0
    }
  } catch { }
  if ($server.HasExited) { throw "SAMI server exited before becoming healthy. Log: $logPath" }
}
throw "SAMI server did not become healthy. Log: $logPath"
