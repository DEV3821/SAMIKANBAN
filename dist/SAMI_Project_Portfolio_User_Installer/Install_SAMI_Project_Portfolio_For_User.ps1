[CmdletBinding()]
param(
  [string]$TeamRoot,
  [switch]$NoDesktop,
  [switch]$NoStartMenu,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$productName = 'SAMI Project Portfolio'
$defaultTeamRoot = '\\fusafmcf01\Medical Imaging\Team_ESMI\Program Delivery\SAMI-Kanban-WorkServer'
$packageRoot = $PSScriptRoot
$payloadRoot = Join-Path $packageRoot 'payload'
$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
$cacheRoot = Join-Path $localBase 'launcher-cache'
$logsRoot = Join-Path $localBase 'logs'
$proxyPath = Join-Path $localBase 'Launch SAMI Project Portfolio.vbs'
$installLog = Join-Path $logsRoot 'user_install.log'

function Write-InstallLog {
  param([string]$Message)
  Add-Content -LiteralPath $installLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function New-UserShortcut {
  param([string]$Path, [string]$IconPath)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $shortcut.Arguments = '"' + $proxyPath + '"'
  $shortcut.WorkingDirectory = $localBase
  $shortcut.Description = 'Open SAMI Project Portfolio'
  $shortcut.IconLocation = "$IconPath,0"
  $shortcut.Save()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Shortcut could not be created: $Path" }
  Write-InstallLog "Shortcut created: $Path; icon: $IconPath"
}

try {
  New-Item -ItemType Directory -Path $localBase, $cacheRoot, $logsRoot -Force | Out-Null
  Write-InstallLog '=================================================='
  Write-InstallLog "Installer started from: $packageRoot"

  if ([string]::IsNullOrWhiteSpace($TeamRoot)) {
    $TeamRoot = $defaultTeamRoot
  }
  $TeamRoot = [System.IO.Path]::GetFullPath($TeamRoot).TrimEnd('\')
  Write-InstallLog "Configured Team ESMI root: $TeamRoot"

  foreach ($required in @('index.html','manifest.webmanifest','serve_kanban.ps1','tools\bootstrap_kanban.ps1','assets\sami_project_portfolio.ico')) {
    $requiredPath = Join-Path $payloadRoot $required
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Installer payload is incomplete: $required" }
  }

  foreach ($item in Get-ChildItem -LiteralPath $payloadRoot -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $cacheRoot -Recurse -Force
  }
  $localBootstrap = Join-Path $cacheRoot 'tools\bootstrap_kanban.ps1'
  $iconPath = Join-Path $cacheRoot 'assets\sami_project_portfolio.ico'
  $teamRootVbs = $TeamRoot.Replace('"','""')
  $localBootstrapVbs = $localBootstrap.Replace('"','""')

  $proxyContent = @"
Option Explicit
Dim shell, fso, teamRoot, localBootstrap, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
teamRoot = "$teamRootVbs"
localBootstrap = "$localBootstrapVbs"
If Not fso.FolderExists(teamRoot) Then
  shell.Popup "Team ESMI is unavailable. SAMI Project Portfolio will use the local runtime view. Changes may not be synced until Team ESMI is available again.", 0, "$productName", 48
End If
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & localBootstrap & """ -TeamRoot """ & teamRoot & """ -AllowLocalFallback"
shell.Run command, 0, False
"@
  [System.IO.File]::WriteAllText($proxyPath, $proxyContent, [System.Text.UTF8Encoding]::new($false))
  Write-InstallLog "Per-user launcher created: $proxyPath"

  $desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  if ([string]::IsNullOrWhiteSpace($desktopRoot)) { $desktopRoot = Join-Path $env:USERPROFILE 'Desktop' }
  $programsRoot = [Environment]::GetFolderPath('Programs')
  if (-not $NoDesktop) { New-UserShortcut -Path (Join-Path $desktopRoot "$productName.lnk") -IconPath $iconPath }
  if (-not $NoStartMenu) { New-UserShortcut -Path (Join-Path $programsRoot "$productName.lnk") -IconPath $iconPath }

  $instructions = "Installation complete. No administrator rights were required.`n`nSAMI Project Portfolio will open in an Edge app window. For the best SAMI taskbar icon, use Edge's three-dot menu, choose Apps > Install this site as an app, then pin SAMI Project Portfolio to the taskbar."
  Write-Host $instructions
  Write-InstallLog 'Installation completed successfully.'
  if (-not $NoLaunch) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($instructions, 0, $productName, 64) } catch {}
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $proxyPath + '"')
  }
  exit 0
} catch {
  $message = "$productName installation failed: $($_.Exception.Message)"
  try { Write-InstallLog $message } catch {}
  [Console]::Error.WriteLine($message)
  try { [void](New-Object -ComObject WScript.Shell).Popup($message, 0, $productName, 16) } catch {}
  exit 1
}
