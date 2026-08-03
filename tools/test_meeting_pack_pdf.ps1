$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'meeting_pack.ps1')
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sami-pdf-route-test-' + [Guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'data'
$fixtureRoot = Join-Path $testRoot 'browser-fixture'
$serverPids = @()
$assertions = 0

function Assert-PdfBytes {
  param([byte[]]$Bytes, [string]$Label)
  $script:assertions++
  if ($null -eq $Bytes -or $Bytes.Length -le 5) { throw "$Label returned an empty PDF." }
  $header = [Text.Encoding]::ASCII.GetString($Bytes, 0, 5)
  if ($header -ne '%PDF-') { throw "$Label did not return a valid PDF signature: $header" }
}

function Get-MeetingPackTempPaths {
  return @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'sami-mp-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Stop-FixtureServer {
  param([string]$ServerProcessId)
  if ([string]::IsNullOrWhiteSpace($ServerProcessId)) { return }
  Stop-Process -Id ([int]$ServerProcessId) -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
try {
  $projectsPayload = [ordered]@{
    meta = [ordered]@{ name = 'Synthetic PDF acceptance fixture'; source = 'isolated-test' }
    projects = @(
      [ordered]@{
        id = 'pdf-alpha'
        title = ('Synthetic PDF Alpha ' + [char]0x2014 + ' O' + [char]39 + 'Brien')
        status = 'running'
        riskColour = 'green'
        owner = 'Synthetic Owner'
        lead = 'Synthetic Lead'
        context = ('Unicode ' + [char]0x2713 + " context`nwith a second line")
        nextAction = "Line one`nLine two with **literal Markdown** and a long synthetic next action"
        notes = ('Manual Additional Notes line 1`nline 2 ' + [char]0x2014 + ' Unicode ' + [char]0x2713 + ' ' + [char]0x2014 + ' O' + [char]39 + 'Brien')
        reviewDate = '2026-08-03'
        blockerReason = ''
        projectHistory = @(
          [ordered]@{ type = 'next_action_set'; occurredAt = '2026-08-03T08:00:00Z'; nextAction = 'First synthetic action' }
          [ordered]@{ type = 'project_file_added'; occurredAt = '2026-08-03T08:01:00Z'; fileCount = 2; files = @(@{ name = 'one.txt' }, @{ name = 'two.md' }) }
        )
      }
      [ordered]@{
        id = 'pdf-beta'
        title = 'Synthetic PDF Beta'
        status = 'backlog'
        riskColour = 'amber'
        owner = 'Synthetic Owner Two'
        lead = 'Synthetic Lead Two'
        context = 'Several-card fixture'
        nextAction = 'Second synthetic action'
        notes = ''
        reviewDate = ''
        blockerReason = 'Waiting on synthetic input'
        projectHistory = @()
      }
    )
  }
  $source = Join-Path $dataRoot 'projects.json'
  $json = ($projectsPayload | ConvertTo-Json -Depth 30) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($source, $json, [Text.UTF8Encoding]::new($false))
  $revision = Get-MeetingPackRevision $source
  $projects = Get-MeetingPackProjects $source @()
  $meeting = [pscustomobject]@{ classification = 'Preview'; time = '2026-08-03 18:00:00 +09:30'; scope = 'synthetic'; revision = $revision }

  $beforeDirect = Get-MeetingPackTempPaths
  Assert-PdfBytes -Bytes ([byte[]](New-MeetingPackPdf $meeting @())) -Label 'empty collection PDF'
  Assert-PdfBytes -Bytes ([byte[]](New-MeetingPackPdf $meeting @($projects[0]))) -Label 'single-card PDF'
  Assert-PdfBytes -Bytes ([byte[]](New-MeetingPackPdf $meeting @($projects))) -Label 'multi-card PDF'
  $optionalFieldCard = $projects[0].PSObject.Copy()
  [void]$optionalFieldCard.PSObject.Properties.Remove('blockerReason')
  Assert-PdfBytes -Bytes ([byte[]](New-MeetingPackPdf $meeting @($optionalFieldCard))) -Label 'optional blocker field PDF'
  $afterDirect = Get-MeetingPackTempPaths
  $newDirectTemps = @($afterDirect | Where-Object { $beforeDirect -notcontains $_ })
  $assertions++
  if ($newDirectTemps.Count -ne 0) { throw "PDF generator left temporary directories: $($newDirectTemps -join ', ')" }

  $body = @{ format = 'pdf'; mode = 'preview'; scope = 'synthetic'; projectIds = @(); revision = $revision } | ConvertTo-Json -Depth 10 -Compress
  $directExport = Invoke-MeetingPackExport $body $source $source $testRoot $false
  Assert-PdfBytes -Bytes ([byte[]]$directExport.Bytes) -Label 'direct PDF export'
  $assertions++
  if ($directExport.ContentType -ne 'application/pdf') { throw "Direct PDF content type was $($directExport.ContentType)." }
  $assertions++
  if ($directExport.FileName -notmatch '\.pdf$') { throw "Direct PDF filename was $($directExport.FileName)." }

  $badBody = @{ format = 'pdf'; mode = 'preview'; scope = 'synthetic'; projectIds = @(); revision = ('0' * 64) } | ConvertTo-Json -Depth 10 -Compress
  $truthfulError = $false
  try { [void](Invoke-MeetingPackExport $badBody $source $source $testRoot $false) } catch { $truthfulError = $_.Exception.Message -match 'Board source changed' }
  $assertions++
  if (-not $truthfulError) { throw 'Failed PDF generation path did not return a truthful source-revision error.' }

  $fixtureOutput = (& (Join-Path $PSScriptRoot 'start_browser_fixture.ps1') -TempRoot $fixtureRoot -NoBrowser 2>&1 | Out-String)
  $serverA = [regex]::Match($fixtureOutput, 'BROWSER_FIXTURE_CLIENT_A_SERVER_PID=(\d+)').Groups[1].Value
  $serverB = [regex]::Match($fixtureOutput, 'BROWSER_FIXTURE_CLIENT_B_SERVER_PID=(\d+)').Groups[1].Value
  $url = [regex]::Match($fixtureOutput, 'BROWSER_FIXTURE_CLIENT_A_URL=(http://[^\r\n]+)').Groups[1].Value
  $url = ($url -split '/\?')[0]
  $serverPids = @($serverA, $serverB)
  if ([string]::IsNullOrWhiteSpace($url)) { throw "PDF route fixture did not start. Output: $fixtureOutput" }

  $runtimeSource = Join-Path $fixtureRoot 'runtime-a\data\projects.json'
  $canonicalSource = Join-Path $fixtureRoot 'canonical\data\projects.json'
  [System.IO.File]::WriteAllText($runtimeSource, $json, [Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($canonicalSource, $json, [Text.UTF8Encoding]::new($false))
  $routeRevision = Get-MeetingPackRevision $runtimeSource
  $routeBody = @{ format = 'pdf'; mode = 'preview'; scope = 'synthetic route'; projectIds = @(); revision = $routeRevision } | ConvertTo-Json -Depth 10 -Compress
  Add-Type -AssemblyName System.Net.Http
  $client = [Net.Http.HttpClient]::new()
  try {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, ($url + '/api/meeting-pack/export'))
    $request.Content = [Net.Http.StringContent]::new($routeBody, [Text.Encoding]::UTF8, 'application/json')
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $routeBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $contentType = [string]$response.Content.Headers.ContentType
    $disposition = [string]$response.Content.Headers.ContentDisposition
    $assertions++
    if ([int]$response.StatusCode -ne 200) { throw "PDF HTTP route returned $([int]$response.StatusCode)." }
    $assertions++
    if ($contentType -notmatch '^application/pdf') { throw "PDF HTTP content type was $contentType." }
    $assertions++
    if ($disposition -notmatch 'filename=.*\.pdf') { throw "PDF HTTP filename header was $disposition." }
    Assert-PdfBytes -Bytes ([byte[]]$routeBytes) -Label 'HTTP PDF export'
    $routePdf = Join-Path $testRoot 'route-output.pdf'
    [System.IO.File]::WriteAllBytes($routePdf, [byte[]]$routeBytes)
    $assertions++
    if (-not (Test-Path -LiteralPath $routePdf -PathType Leaf) -or (Get-Item -LiteralPath $routePdf).Length -le 5) { throw 'Saved HTTP PDF was missing or empty.' }
    $assertions++
    if ((Get-Content -LiteralPath $routePdf -Encoding Byte -TotalCount 5) -join ',' -ne (([Text.Encoding]::ASCII.GetBytes('%PDF-')) -join ',')) { throw 'Saved HTTP PDF signature was invalid.' }
  } finally {
    if ($request) { $request.Dispose() }
    $client.Dispose()
  }

  'MEETING_PACK_PDF_TESTS_OK'
  "MEETING_PACK_PDF_ASSERTIONS=$assertions"
} finally {
  foreach ($serverPidValue in $serverPids) { Stop-FixtureServer $serverPidValue }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
