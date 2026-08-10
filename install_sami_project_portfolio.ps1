[CmdletBinding()]
param(
  [string]$HostedUrl = 'http://SAH0235190:8788/',
  [string]$IconPath,
  [switch]$NoDesktop,
  [switch]$NoStartMenu,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'tools\install_sami_kanban_hosted_shortcut.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Hosted shortcut installer not found: $installer" }
& $installer -HostedUrl $HostedUrl -IconPath $IconPath -NoDesktop:$NoDesktop -NoStartMenu:$NoStartMenu -NoLaunch:$NoLaunch
exit $LASTEXITCODE
