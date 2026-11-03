param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [string]$Fixture = '',
  [string]$OutputDirectory = '',
  [string]$Label = 'current',
  [ValidateSet('callback', 'mouse', 'touch')][string]$InputMode = 'callback',
  [ValidateRange(0, 10000)][int]$StartupQuietMilliseconds = 0,
  [ValidateRange(1, 10)][int]$Repetitions = 3,
  [ValidateRange(1, 50)][int]$Cycles = 10
)
$ErrorActionPreference = 'Stop'
$rootWorkspace = Split-Path -Parent $PSScriptRoot
if (-not $Fixture) { $Fixture = Join-Path $rootWorkspace 'build/performance-audit/fixtures/1000/library.json' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $rootWorkspace 'build/performance-audit/root-switch-runs' }
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Missing probe executable: $Executable" }
if (-not (Test-Path -LiteralPath $Fixture -PathType Leaf)) { throw "Missing isolated library fixture: $Fixture" }
$rootRunDirectory = Join-Path $OutputDirectory ($Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$rootReports = [System.Collections.Generic.List[object]]::new()
foreach ($rootRepeat in 1..$Repetitions) {
  $rootPrivate = Join-Path $rootRunDirectory "$rootRepeat"
  New-Item -ItemType Directory -Force -Path (Join-Path $rootPrivate 'data') | Out-Null
  Copy-Item -LiteralPath $Fixture -Destination (Join-Path $rootPrivate 'data/library.json')
  $env:FLUENT_PERF_ROOT = $rootPrivate
  $env:FLUENT_PERF_REPORT = Join-Path $rootPrivate 'startup.json'
  $env:FLUENT_PERF_MEASUREMENT_ONLY = 'true'
  $env:FLUENT_ROOT_SWITCH_REPORT = Join-Path $rootPrivate 'root-switch.json'
  $env:FLUENT_ROOT_SWITCH_CYCLES = "$Cycles"
  $env:FLUENT_ROOT_SWITCH_INPUT = $InputMode
  $env:FLUENT_ROOT_SWITCH_STARTUP_QUIET_MS = "$StartupQuietMilliseconds"
  $rootProcess = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path -Parent $Executable) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $rootPrivate 'stdout.log') -RedirectStandardError (Join-Path $rootPrivate 'stderr.log') -PassThru
  $rootData = $null
  $rootClock = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    while (-not $rootProcess.HasExited -and $rootClock.Elapsed.TotalSeconds -lt 120) {
      if (Test-Path -LiteralPath $env:FLUENT_ROOT_SWITCH_REPORT) {
        try { $rootData = Get-Content -LiteralPath $env:FLUENT_ROOT_SWITCH_REPORT -Raw | ConvertFrom-Json } catch {}
        if ($null -ne $rootData) { break }
      }
      $null = $rootProcess.WaitForExit(50)
    }
  } finally {
    # This is the process created above, never an existing user app instance.
    if (-not $rootProcess.HasExited) { Stop-Process -Id $rootProcess.Id -Force }
  }
  if ($null -eq $rootData) { throw "Probe produced no report: $rootPrivate" }
  if ($rootData.status -ne 'timings_recorded' -or $rootData.errors.Count -ne 0 -or $rootData.frameCount -eq 0 -or -not $rootData.inputGatesExercised -or $rootData.inputMode -ne $InputMode) {
    throw "Probe failed; inspect $($env:FLUENT_ROOT_SWITCH_REPORT)"
  }
  $rootReports.Add([ordered]@{ repetition = $rootRepeat; report = $env:FLUENT_ROOT_SWITCH_REPORT; result = $rootData })
  Write-Output ("{0} run {1}: first-visible P50={2} ms, P95={3} ms; fully-visible P50={4} ms, P95={5} ms; {6} frames" -f $Label,$rootRepeat,$rootData.firstVisibleFramework.p50Ms,$rootData.firstVisibleFramework.p95Ms,$rootData.fullyVisibleFramework.p50Ms,$rootData.fullyVisibleFramework.p95Ms,$rootData.frameCount)
}
$rootSummary = Join-Path $rootRunDirectory 'summary.json'
[ordered]@{
  status = 'timings_recorded'; label = $Label; cycles = $Cycles
  inputMode = $InputMode; startupQuietMilliseconds = $StartupQuietMilliseconds
  reports = $rootReports.ToArray(); normalExitValidated = $false
  note = 'Private library fixture; input mode distinguishes real title hit tests from direct callbacks. Flutter pointer dispatch excludes OS/hardware delivery latency. Framework visibility is not physical display latency. Owned probe processes are terminated after reports.'
} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $rootSummary -Encoding utf8
Write-Output "Reports: $rootSummary"
