[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$IndexPath = Join-Path $RepoRoot 'index.html'
$Html = [System.IO.File]::ReadAllText($IndexPath)

function Assert-SourceContains {
  param([string]$Pattern, [string]$Message)
  if ($Html -notmatch $Pattern) { throw $Message }
}

$requiredPatterns = [ordered]@{
  PointerDown = 'pointerdown'
  PointerMove = 'pointermove'
  PointerUp = 'pointerup'
  HoldThreshold = 'DRAG_HOLD_MS\s*=\s*190'
  MovementThreshold = 'DRAG_MOVE_THRESHOLD_PX\s*=\s*6'
  EdgeAutoScroll = 'AUTO_SCROLL_EDGE_PX\s*=\s*90'
  AnimationLoop = 'requestAnimationFrame\(runDragAutoScroll\)'
  CrossLaneEndpoint = 'api/card-move'
  KeyboardPreviousLane = 'previous-lane'
  KeyboardNextLane = 'next-lane'
  KeyboardLeft = 'ArrowLeft'
  KeyboardRight = 'ArrowRight'
  ExactSearchFilterMessage = 'Clear search and filters to move or reorder cards\.'
  RemoteVerification = 'verifyRenderedBoardOrder\('
  RemoteStateAfterRender = 'rememberSyncState\(finalState,\s*true\)'
  DeferredRevisionAcknowledgement = 'recordSyncCheck\(status,\s*null,\s*message\)'
  TestHook = '__samiTestHooks'
}
foreach ($entry in $requiredPatterns.GetEnumerator()) {
  Assert-SourceContains -Pattern $entry.Value -Message "Drag-state source check failed: $($entry.Key)."
}

$scriptMatches = [regex]::Matches($Html, '<script>(?<script>[\s\S]*?)</script>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($scriptMatches.Count -lt 2) { throw 'Could not extract the inline application script for syntax validation.' }
$scriptMatch = $scriptMatches[$scriptMatches.Count - 1]
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { throw 'node.exe is required for drag-state syntax validation.' }
$scriptMatch.Groups['script'].Value | & $node.Source --check -
if ($LASTEXITCODE -ne 0) { throw 'Inline application script failed node --check.' }

Write-Output 'DRAG_STATE_SOURCE_TESTS_OK'
Write-Output "DRAG_STATE_SOURCE=$IndexPath"
