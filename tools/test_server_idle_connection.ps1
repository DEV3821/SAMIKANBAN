[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$serverPath = Join-Path $repoRoot 'serve_kanban.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sami-idle-fixture-' + [Guid]::NewGuid().ToString('N'))
$logPath = Join-Path ([IO.Path]::GetTempPath()) ('sami-idle-read-timeout-' + [Guid]::NewGuid().ToString('N') + '.log')
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
$probe.Stop()
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $serverPath,
  '-RootPath', $fixtureRoot, '-Root', $fixtureRoot, '-SourceRoot', $repoRoot,
  '-CanonicalRoot', $fixtureRoot, '-LocalMirrorRoot', $fixtureRoot, '-RuntimeMode', 'offline',
  '-Port', [string]$port, '-BindAddress', '127.0.0.1',
  '-ProjectFileScanIntervalSeconds', '86400', '-ProjectFileScanInitialDelaySeconds', '86400',
  '-LogPath', $logPath
)

$server = $null
$idle = $null
try {
  New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'data'), (Join-Path $fixtureRoot 'project_files') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'index.html'), '<!doctype html><title>SAMI test</title>', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'data\projects.json'), '{"meta":{},"projects":[]}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'data\card_updates.jsonl'), '', [Text.UTF8Encoding]::new($false))
  $server = Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
  $ready = $false
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    Start-Sleep -Milliseconds 100
    $tcp = $null
    try {
      $tcp = [Net.Sockets.TcpClient]::new()
      $connect = $tcp.ConnectAsync('127.0.0.1', $port)
      if ($connect.Wait(500) -and $tcp.Connected) { $ready = $true; break }
    } catch {} finally {
      if ($tcp) { $tcp.Dispose() }
    }
  }
  if (-not $ready) { throw 'Local fixture server did not bind.' }

  $idle = [Net.Sockets.TcpClient]::new()
  $idle.Connect('127.0.0.1', $port)
  $measure = Measure-Command { $health = curl.exe --noproxy '*' --max-time 8 -sS "http://127.0.0.1:$port/api/health" 2>$null }
  [pscustomobject]@{
    Port = $port
    IdleConnectionOpened = $idle.Connected
    HealthElapsedMs = [int]$measure.TotalMilliseconds
    HealthReturned = [bool]$health
    Health = $health -join ''
    ServerLog = @(Get-Content -LiteralPath $logPath -Tail 20 -ErrorAction SilentlyContinue)
  } | Format-List
} finally {
  if ($idle) { $idle.Dispose() }
  if ($server) {
    if (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) {
      Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $server.Id -Timeout 5 -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
}
