[CmdletBinding()]
param(
  [string]$TeamRoot,
  [switch]$NoDesktop,
  [switch]$NoStartMenu
)

$ErrorActionPreference = 'Stop'
$appRoot = $PSScriptRoot
$resolvedTeamRoot = if ([string]::IsNullOrWhiteSpace($TeamRoot)) { $appRoot } else { $TeamRoot }
$modernInstallerCandidates = @(
  (Join-Path $appRoot 'dist\SAMI_Project_Portfolio_User_Installer\Install_SAMI_Project_Portfolio_For_User.ps1'),
  (Join-Path $appRoot 'installers\SAMI_Project_Portfolio_User_Installer\Install_SAMI_Project_Portfolio_For_User.ps1')
)
$modernInstaller = @($modernInstallerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
if ($modernInstaller) {
  & $modernInstaller -TeamRoot $resolvedTeamRoot -NoDesktop:$NoDesktop -NoStartMenu:$NoStartMenu
  exit $LASTEXITCODE
}
$launcher = Join-Path $appRoot 'tools\launch_sami_portfolio.vbs'
$icon = Join-Path $appRoot 'assets\sami_project_portfolio.ico'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Launcher not found: $launcher" }

$localBase = Join-Path $env:LOCALAPPDATA 'SAMI-Kanban-WorkServer'
New-Item -ItemType Directory -Path (Join-Path $localBase 'site'), (Join-Path $localBase 'logs') -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$arguments = if ([string]::IsNullOrWhiteSpace($TeamRoot)) { '' } else { '-TeamRoot "' + $TeamRoot.Replace('"','""') + '"' }

function New-PortfolioShortcut {
  param([string]$Path)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  $shortcut = $shell.CreateShortcut($Path)
  $shortcut.TargetPath = $launcher
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $appRoot
  $shortcut.Description = 'Open SAMI Project Portfolio'
  if (Test-Path -LiteralPath $icon -PathType Leaf) { $shortcut.IconLocation = "$icon,0" }
  $shortcut.Save()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Shortcut could not be created: $Path" }
}

$desktopRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($desktopRoot)) { $desktopRoot = Join-Path $env:USERPROFILE 'Desktop' }
Write-Verbose "Desktop shortcut root: $desktopRoot"
if (-not $NoDesktop) { New-PortfolioShortcut (Join-Path $desktopRoot 'SAMI Project Portfolio.lnk') }
if (-not $NoStartMenu) { New-PortfolioShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'SAMI Project Portfolio.lnk') }

Write-Host 'SAMI Project Portfolio has been installed. Use the Desktop or Start Menu shortcut to open it.'
