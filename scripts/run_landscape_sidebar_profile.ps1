param(
  [Parameter(Mandatory = $true)][string]$VideoPath,
  [ValidateSet('windows', 'macos', 'linux')][string]$Platform = '',
  [ValidateRange(100, 10000)][int]$Rounds = 100,
  [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$sidebarWorkspace = Split-Path -Parent $PSScriptRoot
if (-not $Platform) {
  if ($env:OS -eq 'Windows_NT') { $Platform = 'windows' }
  elseif ($IsMacOS) { $Platform = 'macos' }
  else { $Platform = 'linux' }
}
if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
  throw "Missing local playback fixture: $VideoPath"
}
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $sidebarWorkspace ('build/sidebar-performance/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$sidebarVideoUri = ([Uri](Resolve-Path -LiteralPath $VideoPath).Path).AbsoluteUri
$sidebarOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $sidebarOutput | Out-Null
$sidebarOldOutput = $env:SIDEBAR_PROFILE_OUTPUT
$env:SIDEBAR_PROFILE_OUTPUT = Join-Path $sidebarOutput "$Platform.json"
Push-Location $sidebarWorkspace
try {
  # Explicit desktop target: this runner never discovers or installs on a
  # connected phone. The test entry initializes no user's media library.
  & flutter drive --no-pub --profile -d $Platform `
    --driver=test_driver/landscape_sidebar_performance_driver.dart `
    --target=integration_test/landscape_sidebar_performance_test.dart `
    "--dart-define=SIDEBAR_PROFILE_VIDEO=$sidebarVideoUri" `
    "--dart-define=SIDEBAR_PROFILE_LABEL=$Platform-profile" `
    "--dart-define=SIDEBAR_PROFILE_ROUNDS=$Rounds"
  $sidebarExit = $LASTEXITCODE
  if ($sidebarExit -ne 0) { throw "Sidebar profile failed (exit=$sidebarExit)." }
  if (-not (Test-Path -LiteralPath $env:SIDEBAR_PROFILE_OUTPUT)) {
    throw 'Sidebar profile finished without a frame report.'
  }
  Write-Output "Frame report: $env:SIDEBAR_PROFILE_OUTPUT"
} finally {
  Pop-Location
  $env:SIDEBAR_PROFILE_OUTPUT = $sidebarOldOutput
}
