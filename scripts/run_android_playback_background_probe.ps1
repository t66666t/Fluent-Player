param(
  [string]$Adb = "$env:LOCALAPPDATA/Android/sdk/platform-tools/adb.exe",
  [string]$Serial = $env:ANDROID_SERIAL,
  [string]$Package = 'com.example.video_player_app.power_audit',
  [string]$BaseUrl = 'http://127.0.0.1:8768',
  [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
$steps = [System.Collections.Generic.List[object]]::new()
$wakeNeeded = $false
function Request-Probe([string]$Path) {
  Invoke-RestMethod -Uri "$BaseUrl$Path" -TimeoutSec 45
}
function Save-Probe([string]$Status, [string]$ErrorText = '') {
  @{ status = $Status; error = $ErrorText; steps = $steps; device = $Serial;
    note = 'Isolated release probe; capture requests and process clocks are not battery energy or listening-quality measurements.' } |
    ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $Output -Encoding utf8
}
function Record-Probe([string]$Name, $Data) {
  $steps.Add(@{ name = $Name; data = $Data })
  Save-Probe 'running'
  Write-Host $Name
}
function Wait-ProbeForeground {
  & $Adb -s $Serial shell am start -n "$Package/com.example.video_player_app.MainActivity" | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  do {
    Start-Sleep -Milliseconds 200
    $state = Request-Probe '/status'
  } while ($state.bindingLifecycle -ne 'resumed' -and [DateTime]::UtcNow -lt $deadline)
  if ($state.bindingLifecycle -ne 'resumed' -or -not $state.playing) { throw 'Foreground playback did not recover' }
  return $state
}
function Enter-ProbeBackground {
  & $Adb -s $Serial shell am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  do {
    Start-Sleep -Milliseconds 200
    $state = Request-Probe '/status'
  } while ($state.bindingLifecycle -notin @('hidden','paused') -and [DateTime]::UtcNow -lt $deadline)
  if ($state.bindingLifecycle -notin @('hidden','paused') -or -not $state.playing) { throw 'Opt-in background playback did not continue' }
  return $state
}
function Sample-Probe([string]$Name, [int]$Seconds, [bool]$Background, [bool]$ExpectCaptures, [int]$SeekTargetMs = -1) {
  Start-Sleep -Seconds 2
  $before = Request-Probe '/status'
  Start-Sleep -Seconds $Seconds
  $after = Request-Probe '/status'
  $data = @{ before = $before; after = $after;
    nativeAdvanceMs = $after.nativeMs - $before.nativeMs;
    frames = $after.frames - $before.frames;
    captures = $after.captures - $before.captures;
    capturedBytes = $after.captureBytes - $before.captureBytes;
    completedCaptures = $after.captureCompleted - $before.captureCompleted }
  Record-Probe $Name $data
  if ($after.controllerError -or -not $after.controllerInitialized -or -not $after.playing) { throw "Unhealthy controller: $Name" }
  if ($data.nativeAdvanceMs -lt $Seconds * 750) { throw "Native clock stalled: $Name" }
  if ($SeekTargetMs -ge 0 -and ($before.nativeMs -lt $SeekTargetMs - 300 -or $before.nativeMs -gt $SeekTargetMs + 6000)) { throw "Seek target was not reached: $Name" }
  if ($Background -and $after.bindingLifecycle -notin @('hidden','paused')) { throw "Not backgrounded: $Name" }
  if ($ExpectCaptures -and $data.captures -lt 1) { throw "Visible MediaKit matte was not sampled: $Name" }
  if ($ExpectCaptures -and ($data.capturedBytes -le 0 -or $after.lastCaptureBytes -le 0)) { throw "Visible matte did not return an image: $Name" }
  if (-not $ExpectCaptures -and $data.captures -ne 0) { throw "Hidden matte was still sampled: $Name" }
}
function Send-ProbeMediaKey([string]$Action) {
  # Android's monitor selects by tag only. Never dispatch a global media key,
  # and do not act if another application has the same audio_service tag.
  $sessions = & $Adb -s $Serial shell cmd media_session list-sessions
  $matching = @($sessions | Where-Object { $_ -match '^\s*tag=media-session, package=' })
  if ($matching.Count -ne 1 -or $matching[0].Trim() -ne "tag=media-session, package=$Package") {
    Record-Probe "media-key-$Action-skipped" @{ reason = 'Session tag is not unique to the probe' }
    return $false
  }
  @($Action, 'q') | & $Adb -s $Serial shell cmd media_session monitor media-session | Out-Null
  return $true
}
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  do {
    Start-Sleep -Milliseconds 200
    try { $initial = Request-Probe '/status' } catch { $initial = $null }
    if ($initial.error) { throw $initial.error }
  } while (-not $initial.ready -and [DateTime]::UtcNow -lt $deadline)
  if (-not $initial.ready) { throw 'Probe did not become ready' }
  Record-Probe 'initial-local-player' $initial
  Request-Probe '/background-policy?pause=0' | Out-Null
  Request-Probe '/control?subscribed=0&visible=1&ambient=0' | Out-Null
  $background = Enter-ProbeBackground
  Record-Probe 'local-opt-in-HOME' $background
  Request-Probe '/seek?ms=10000' | Out-Null
  Sample-Probe 'local-background-seek' 3 $true $false 10000
  $foreground = Wait-ProbeForeground
  Record-Probe 'local-opt-in-foreground' $foreground

  $network = Request-Probe '/network-video'
  if (-not $network.ready -or -not $network.managedByMediaKit -or $network.controllerError) { throw 'MediaKit network video did not initialize' }
  Record-Probe 'network-player' $network
  Request-Probe '/control?subscribed=1&visible=1&ambient=1' | Out-Null
  Sample-Probe 'network-visible-ambient' 4 $false $true
  Request-Probe '/control?subscribed=0&visible=0&ambient=1' | Out-Null
  Sample-Probe 'network-covered-ambient' 4 $false $false
  Request-Probe '/control?subscribed=0&visible=1&ambient=1' | Out-Null
  $background = Enter-ProbeBackground
  Record-Probe 'network-opt-in-HOME' $background
  Request-Probe '/seek?ms=20000' | Out-Null
  Sample-Probe 'network-background-seek' 3 $true $false 20000

  Start-Sleep -Seconds 2
  if (Send-ProbeMediaKey 'pause') {
    Start-Sleep -Seconds 1
    $paused = Request-Probe '/status'
    Start-Sleep -Milliseconds 750
    $stillPaused = Request-Probe '/status'
    Record-Probe 'targeted-media-key-pause' @{ before = $paused; after = $stillPaused }
    if ($stillPaused.playing -or [Math]::Abs($stillPaused.nativeMs - $paused.nativeMs) -gt 200) { throw 'Targeted media pause failed' }
    if (-not (Send-ProbeMediaKey 'play')) { throw 'Probe session became ambiguous after pausing' }
    Sample-Probe 'targeted-media-key-play' 3 $true $false
  }
  $foreground = Wait-ProbeForeground
  Record-Probe 'network-opt-in-foreground' $foreground
  Enter-ProbeBackground | Out-Null
  $powerBefore = & $Adb -s $Serial shell dumpsys power | Select-String 'mWakefulness=' | Select-Object -First 1
  if ($powerBefore -notmatch 'Awake') { throw 'Screen must be awake before the screen-off test' }
  $wakeNeeded = $true
  & $Adb -s $Serial shell input keyevent 223 | Out-Null
  Start-Sleep -Seconds 1
  $powerAsleep = & $Adb -s $Serial shell dumpsys power | Select-String 'mWakefulness=' | Select-Object -First 1
  Record-Probe 'screen-off-power-state' $powerAsleep.ToString().Trim()
  if ($powerAsleep -notmatch 'Asleep') { throw 'Device screen did not turn off' }
  Sample-Probe 'network-screen-off-playback' 60 $true $false
  & $Adb -s $Serial shell input keyevent 224 | Out-Null
  Start-Sleep -Seconds 1
  $powerAwake = & $Adb -s $Serial shell dumpsys power | Select-String 'mWakefulness=' | Select-Object -First 1
  Record-Probe 'screen-wake-power-state' $powerAwake.ToString().Trim()
  if ($powerAwake -notmatch 'Awake') { throw 'Device screen did not wake' }
  $wakeNeeded = $false
  Record-Probe 'after-wake' (Request-Probe '/status')
  Sample-Probe 'network-after-wake-playback' 3 $true $false
  Request-Probe '/stop' | Out-Null
  Record-Probe 'stopped' (Request-Probe '/status')
  Save-Probe 'passed'
} catch {
  Save-Probe 'failed' $_.Exception.Message
  throw
} finally {
  if ($wakeNeeded) { & $Adb -s $Serial shell input keyevent 224 | Out-Null }
}
