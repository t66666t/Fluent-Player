param(
  [string]$Executable = '',
  [string]$OutputDirectory = '',
  [string]$RestoreMedia = '',
  [int]$Repetitions = 10,
  [switch]$MeasurementOnly
)
$ErrorActionPreference = 'Stop'
$perfWorkspace = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $perfWorkspace 'build/windows/x64/runner/Profile/fluent-player.exe' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $perfWorkspace 'build/performance-audit' }
$perfFixtures = Join-Path $OutputDirectory 'fixtures'
$perfRuns = Join-Path $OutputDirectory ('startup-runs/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$perfResults = [System.Collections.Generic.List[object]]::new()
function Get-Distribution($values) {
  $sorted = @($values | Sort-Object)
  if ($sorted.Count -eq 0) { return @{ count = 0 } }
  return @{
    count = $sorted.Count
    p50 = $sorted[[Math]::Round(($sorted.Count - 1) * .5)]
    p95 = $sorted[[Math]::Round(($sorted.Count - 1) * .95)]
    max = $sorted[-1]
  }
}
foreach ($perfCount in @(0, 1000, 10000)) {
  $perfFixture = Join-Path $perfFixtures "$perfCount/library.json"
  if (-not (Test-Path -LiteralPath $perfFixture)) { throw "Missing fixture: $perfFixture. Run app_performance_benchmark first." }
  foreach ($perfRepeat in 1..$Repetitions) {
    $perfRoot = Join-Path $perfRuns "$perfCount-$perfRepeat"
    New-Item -ItemType Directory -Force -Path (Join-Path $perfRoot 'data') | Out-Null
    Copy-Item -LiteralPath $perfFixture -Destination (Join-Path $perfRoot 'data/library.json')
    if ($RestoreMedia -and $perfCount -gt 0) {
      if (-not (Test-Path -LiteralPath $RestoreMedia)) { throw "Missing restore fixture: $RestoreMedia" }
      $perfLibraryFile = Join-Path $perfRoot 'data/library.json'
      $perfLibrary = Get-Content -LiteralPath $perfLibraryFile -Raw | ConvertFrom-Json
      $perfLibrary.videos[0].path = [System.IO.Path]::GetFullPath($RestoreMedia)
      $perfLibrary.videos[0].lastPositionMs = 0
      if ($perfLibrary.videos[0]._storagePaths) {
        $perfLibrary.videos[0]._storagePaths.PSObject.Properties.Remove('path')
      }
      $perfLibrary | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $perfLibraryFile -Encoding utf8
      New-Item -ItemType Directory -Force -Path (Join-Path $perfRoot 'support') | Out-Null
      @{ currentItemId = 'v0'; positionMs = 0; wasPlaying = $false; playlistFolderId = 'f0'; timestamp = 1792598400000 } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $perfRoot 'support/playback_state_snapshot.json') -Encoding utf8
    }
    $env:FLUENT_PERF_ROOT = $perfRoot
    $env:FLUENT_PERF_REPORT = Join-Path $perfRoot 'startup.json'
    $env:FLUENT_PERF_MEASUREMENT_ONLY = $MeasurementOnly.IsPresent.ToString().ToLowerInvariant()
    $perfWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $perfProcess = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path -Parent $Executable) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $perfRoot 'stdout.log') -RedirectStandardError (Join-Path $perfRoot 'stderr.log') -PassThru
    if ($MeasurementOnly) {
      $perfData = $null
      while (-not $perfProcess.HasExited -and $perfWatch.ElapsedMilliseconds -lt 55000) {
        if (Test-Path -LiteralPath $env:FLUENT_PERF_REPORT) {
          try { $perfData = Get-Content -LiteralPath $env:FLUENT_PERF_REPORT -Raw | ConvertFrom-Json } catch {}
          if ($null -ne $perfData) { break }
        }
        $null = $perfProcess.WaitForExit(50)
      }
      if (-not $perfProcess.HasExited) { Stop-Process -Id $perfProcess.Id -Force }
      if ($null -eq $perfData) { throw "Startup did not complete its report: $perfRoot" }
    } elseif (-not $perfProcess.WaitForExit(55000)) {
      Stop-Process -Id $perfProcess.Id -Force
      throw "Isolated startup timed out: $perfRoot"
    }
    if (-not (Test-Path -LiteralPath $env:FLUENT_PERF_REPORT)) { throw "Startup process produced no report: $perfRoot" }
    $perfData = Get-Content -LiteralPath $env:FLUENT_PERF_REPORT -Raw | ConvertFrom-Json
    if ((-not $MeasurementOnly -and $perfProcess.ExitCode -ne 0) -or $perfData.status -ne 'passed' -or $null -eq $perfData.homeFrameworkFrameMs -or $perfData.mediaCount -ne $perfCount) {
      throw "Startup fixture failed (exit=$($perfProcess.ExitCode), status=$($perfData.status), count=$($perfData.mediaCount)); inspect $perfRoot. Confirm isolated_app_startup_profile.dart is the built entry point."
    }
    if ($RestoreMedia -and $perfCount -gt 0 -and $null -eq $perfData.restoredMiniFrameMs) {
      throw "Paused playback was not restored; inspect $perfRoot"
    }
    $perfResults.Add([ordered]@{
      mediaCount = $perfCount; repetition = $perfRepeat
      firstFlutterFrameMs = $perfData.firstFlutterFrameMs
      homeFrameworkFrameMs = $perfData.homeFrameworkFrameMs
      homeEventLoopReadyMs = $perfData.homeEventLoopReadyMs
      restoredMiniFrameMs = $perfData.restoredMiniFrameMs
      rssBytes = $perfData.rssBytes
      product = $perfData.product
      normalExitValidated = (-not $MeasurementOnly -and $perfProcess.ExitCode -eq 0)
      totalProcessMs = $perfWatch.Elapsed.TotalMilliseconds
      report = $env:FLUENT_PERF_REPORT
    })
    Write-Output ("{0} items, run {1}: home frame {2} ms, event loop ready {3} ms" -f $perfCount,$perfRepeat,$perfData.homeFrameworkFrameMs,$perfData.homeEventLoopReadyMs)
  }
}
$perfGroups = [ordered]@{}
foreach ($perfCount in @(0, 1000, 10000)) {
  $perfGroup = @($perfResults | Where-Object { $_.mediaCount -eq $perfCount })
  $perfGroups["$perfCount"] = @{
    firstFlutterFrameMs = Get-Distribution ($perfGroup | ForEach-Object { $_.firstFlutterFrameMs })
    homeFrameworkFrameMs = Get-Distribution ($perfGroup | ForEach-Object { $_.homeFrameworkFrameMs })
    homeEventLoopReadyMs = Get-Distribution ($perfGroup | ForEach-Object { $_.homeEventLoopReadyMs })
    restoredMiniFrameMs = Get-Distribution ($perfGroup | Where-Object { $null -ne $_.restoredMiniFrameMs } | ForEach-Object { $_.restoredMiniFrameMs })
    rssBytes = Get-Distribution ($perfGroup | ForEach-Object { $_.rssBytes })
  }
}
[ordered]@{
  status = $(if ($MeasurementOnly) { 'timings_recorded' } else { 'passed' })
  groups = $perfGroups; samples = $perfResults.ToArray()
  terminationPolicy = $(if ($MeasurementOnly) { 'Owned processes terminated after reports; normal exit not validated' } else { 'Normal exit checked' })
  restoreMedia = $RestoreMedia
  note = 'Independent process launches with fresh isolated app data. OS filesystem cache was not flushed. Times start at the Dart entry point, not OS process launch.'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'startup-summary.json') -Encoding utf8
