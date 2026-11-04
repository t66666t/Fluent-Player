param(
  [ValidateSet('android', 'windows')][string]$Platform,
  [Parameter(Mandatory = $true)][string]$Output,
  [string]$Label = 'after',
  [string]$Adb = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe",
  [string]$Package = 'com.example.video_player_app.power_audit',
  [int]$ProbeProcessId = 0,
  [int]$SampleSeconds = 8,
  [switch]$AllowKnownForegroundPause,
  [string]$BaseUrl = 'http://127.0.0.1:8768'
)
$ErrorActionPreference = 'Stop'
# Run only against scripts/playback_power_probe.dart. Its localhost API and
# isolated package keep user sessions and application data out of this test.
function Request-Probe([string]$Path) {
  Invoke-RestMethod -Uri "$BaseUrl$Path" -TimeoutSec 45
}
if ($Platform -eq 'android') {
  & $Adb forward tcp:8768 tcp:8768 | Out-Null
}
$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
  try { $status = Request-Probe '/status' } catch { $status = $null }
  if ($status -and $status.error) { throw $status.error }
  if ($status -and $status.ready) { break }
  Start-Sleep -Milliseconds 500
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $status.ready) { throw 'Native playback did not become ready' }
$results = [System.Collections.Generic.List[object]]::new()
function Measure-Probe([string]$Name) {
  # Exclude rebuild/catch-up and frame-timing batching from the sample.
  Start-Sleep -Seconds 2
  $before = Request-Probe '/status'
  if (-not $before.ready -or $before.error) { throw "Unhealthy probe: $Name" }
  $cpuBefore = if ($ProbeProcessId) { (Get-Process -Id $ProbeProcessId).TotalProcessorTime.TotalMilliseconds } else { 0 }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Seconds $SampleSeconds
  $after = Request-Probe '/status'
  $cpuAfter = if ($ProbeProcessId) { (Get-Process -Id $ProbeProcessId).TotalProcessorTime.TotalMilliseconds } else { 0 }
  $row = [ordered]@{
    name = $Name
    wallMs = $clock.Elapsed.TotalMilliseconds
    frames = $after.frames - $before.frames
    captures = $after.captures - $before.captures
    positionNotifications = $after.positionNotifications - $before.positionNotifications
    buildMicros = $after.buildMicros - $before.buildMicros
    rasterMicros = $after.rasterMicros - $before.rasterMicros
    mediaAdvanceMs = $after.nativeMs - $before.nativeMs
    processCpuMs = if ($ProbeProcessId) { $cpuAfter - $cpuBefore } else { $null }
    before = $before
    after = $after
  }
  $results.Add($row)
  @{ label = $Label; platform = $Platform; status = 'sampling'; scenarios = $results } |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Output -Encoding utf8
  Write-Output "$Name frames=$($row.frames) captures=$($row.captures) notifications=$($row.positionNotifications)"
  if ($Name -eq 'actual-android-background' -and $after.lifecycle -notin @('hidden','paused')) {
    throw 'Android activity did not remain in the background'
  }
  if ($Name -eq 'paused-ambient') {
    if ($after.playing -or [Math]::Abs($row.mediaAdvanceMs) -gt 200) { throw 'Paused playback advanced' }
  } elseif (-not $after.playing -or $row.mediaAdvanceMs -lt ($SampleSeconds * 750)) {
    throw "Native playback stalled during $Name"
  }
  if ($Name -eq 'double-speed' -and [Math]::Abs($row.mediaAdvanceMs - $SampleSeconds * 2000) -gt 1200) {
    throw 'Double-speed native playback did not advance at the requested rate'
  }
  if ($Label -eq 'after') {
    if ($Name -eq 'off-page-unsubscribed') {
      # Android's platform video texture can drive native compositor frames
      # without a scheduled Dart frame. Keep those FrameTiming samples in the
      # report; do not label them as presentation-ticker requests or claim zero.
      if ($Platform -eq 'windows' -and $row.frames -gt 2) { throw 'Off-page playback still requested frames' }
      if ($Platform -eq 'android' -and ($before.scheduled -or $after.scheduled)) { throw 'Off-page playback still scheduled Dart frames' }
    }
    if ($Name -in @('covered-ambient','paused-ambient','actual-android-background') -and $row.captures -ne 0) { throw "Unnecessary captures during $Name" }
  }
}
Request-Probe '/control?subscribed=1&visible=1&ambient=0' | Out-Null
Measure-Probe 'visible-subscribed'
Request-Probe '/control?subscribed=0&visible=0&ambient=0' | Out-Null
Measure-Probe 'off-page-unsubscribed'
Request-Probe '/control?subscribed=0&visible=0&ambient=1' | Out-Null
Measure-Probe 'covered-ambient'
Request-Probe '/control?subscribed=1&visible=1&ambient=1' | Out-Null
Request-Probe '/pause' | Out-Null
Request-Probe '/seek?ms=20000' | Out-Null
Measure-Probe 'paused-ambient'
Request-Probe '/play' | Out-Null
if ($Platform -eq 'android') {
  & $Adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
  $backgroundDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    Start-Sleep -Milliseconds 100
    $background = Request-Probe '/status'
  } while ($background.lifecycle -notin @('hidden','paused') -and [DateTime]::UtcNow -lt $backgroundDeadline)
  if ($background.lifecycle -notin @('hidden','paused')) { throw 'Android activity did not enter the background' }
  $pauseDeadline = [DateTime]::UtcNow.AddSeconds(3)
  while ($background.playing -and [DateTime]::UtcNow -lt $pauseDeadline) {
    Start-Sleep -Milliseconds 100
    $background = Request-Probe '/status'
  }
  if ($background.playing) { throw 'Mobile auto-pause did not settle' }
  Start-Sleep -Milliseconds 500
  $backgroundPaused = Request-Probe '/status'
  if ($backgroundPaused.playing -or [Math]::Abs($backgroundPaused.nativeMs - $background.nativeMs) -gt 200) {
    throw 'Native playback did not pause after the HOME transition'
  }
  # The probe preserves the app's mobile auto-pause default. Resume only after
  # verifying that transition, as a user can do from background media controls.
  # Record both states; this is not a test of disabling auto-pause in settings.
  $backgroundResumed = Request-Probe '/play'
  if ($backgroundResumed.lifecycle -notin @('hidden','paused') -or -not $backgroundResumed.playing) {
    throw 'Background media controls did not resume playback'
  }
  Measure-Probe 'actual-android-background'
  & $Adb shell am start -n "$Package/com.example.video_player_app.MainActivity" | Out-Null
  Start-Sleep -Seconds 2
  $restored = Request-Probe '/status'
  if ($restored.lifecycle -ne 'resumed') { throw 'Android activity did not return to the foreground' }
  if (-not $restored.playing) {
    if (-not $AllowKnownForegroundPause -or $Label -ne 'before') { throw 'Foreground playback did not recover' }
    $knownForegroundPause = $true
    Write-Output 'KNOWN BASELINE FAILURE: foreground return paused background-resumed playback'
    $foregroundManuallyResumed = Request-Probe '/play'
  }
  Start-Sleep -Milliseconds 500
  $foregroundAdvancing = Request-Probe '/status'
  if ($foregroundAdvancing.nativeMs -le $restored.nativeMs) { throw 'Foreground native position stopped advancing' }
}
Request-Probe '/control?subscribed=1&visible=1&ambient=0' | Out-Null
Request-Probe '/rate?value=2' | Out-Null
Measure-Probe 'double-speed'
Request-Probe '/rate?value=1' | Out-Null
Request-Probe '/pause' | Out-Null
$audio = Request-Probe '/audio-check'
$audioPlayed = $audio.audioInitialized -and $audio.audioPositionMs -ge 500
# Both saved baselines already contain the audio-only classification fix.
# This checks native playback/output behavior, rather than an allocation A/B.
Write-Output "Opaque audio played; video output allocated=$($audio.audioHasVideoOutput)"
Request-Probe '/stop' | Out-Null
$result = [ordered]@{
  label = $Label; platform = $Platform; sampleSeconds = $SampleSeconds
  status = if (-not $audioPlayed) { 'audio-validation-failed' } elseif ($knownForegroundPause) { 'known-foreground-pause' } else { 'passed' }
  collectedUtc = [DateTime]::UtcNow.ToString('o')
  scenarios = $results; opaqueAudio = $audio
  androidBackgroundState = $background; androidBackgroundPaused = $backgroundPaused
  androidBackgroundResumed = $backgroundResumed
  androidForegroundRestore = $restored; androidForegroundAdvancing = $foregroundAdvancing
  knownForegroundPause = [bool]$knownForegroundPause
  androidForegroundManualRecovery = $foregroundManuallyResumed
  note = 'Isolated release playback workload. Counts and process CPU are not battery energy measurements. Android remains USB powered. No claim of other-platform device validation.'
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Output -Encoding utf8
if (-not $audioPlayed) { throw 'Opaque audio relay did not play' }
if ($Label -eq 'after' -and $audio.audioHasVideoOutput) { throw 'Audio-only playback allocated a video output' }
