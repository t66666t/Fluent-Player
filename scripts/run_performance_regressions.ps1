param(
  [string]$OutputDirectory = '',
  [int]$Concurrency = 2
)
$ErrorActionPreference = 'Stop'
$perfWorkspace = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $perfWorkspace 'build/performance-audit' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$perfTests = @(
  'artwork_memory_reuse', 'artwork_scheduler', 'artwork_storage_audit',
  'podcast_queue_artwork', 'system_media_session_artwork',
  'library_snapshot_reader', 'library_snapshot_writer',
  'library_projection_single_pass', 'library_activity_projection',
  'library_activity_scale', 'library_activity_pin_reorder',
  'library_activity_storage', 'library_persistence_recovery',
  'app_storage_upgrade', 'app_data_paths',
  'ui_idle_gate', 'first_open_ui_warmup', 'app_startup_gate',
  'app_page_transitions', 'page_route_first_frame',
  'android_navigation_visibility', 'podcast_channel_entry_transition',
  'collection_entry_work', 'podcast_catalog_projection',
  'playback_page_route', 'route_transition_work',
  'feature_page_transitions', 'feature_entry_work',
  'media_library_root_surface_host', 'media_library_root_click_latency',
  'media_library_entry_switcher', 'media_library_root_swipe_policy',
  'media_library_shell', 'media_library_shell_routes',
  'media_library_folder_route', 'media_library_folder_transition',
  'media_library_folder_walk', 'collection_screen_navigation',
  'playback_source_viewport',
  'media_library_continue_view', 'media_library_recent_view',
  'media_library_navigation_shell', 'portrait_player_panel_switcher',
  'legacy_bilibili_cache_import', 'media_cache_service',
  'media_cache_migration', 'media_cache_storage', 'media_cache_playback',
  'media_cache_parallel_cloud', 'media_cache_screen', 'media_cache_selection',
  'video_playback_performance_settings', 'playback_transport_sync',
  'danmaku_presentation_position', 'danmaku_render_pipeline',
  'danmaku_active_set_stress', 'danmaku_overlay_paint',
  'danmaku_refresh_rate', 'danmaku_frame_cache',
  'danmaku_region_settings', 'danmaku_ass',
  'playback_timeline_clock', 'playback_rate_clock_transition',
  'playback_page_controller_ownership', 'playback_page_released_controller',
  'media_playback_session_state', 'background_playback_handoff',
  'web_media_browser_session', 'network_proxy_lifecycle',
  'subtitle_sidebar_motion', 'music_lyric_continuity',
  'player_sidebar_motion', 'landscape_sidebar_preparation_work',
  'desktop_player_sidebar', 'landscape_sidebar_transition',
  'subtitle_chat_sidebar', 'landscape_sidebar_safe_insets',
  'landscape_sidebar_layout', 'landscape_subtitle_viewport_restore',
  'subtitle_sidebar_offstage_clock', 'subtitle_sidebar_repaint_isolation',
  'video_compose_sidebar_preparation', 'bilibili_player_panel',
  'transcription_resume_restart', 'cloud_drive_startup_latency',
  'bilibili_account_screen', 'cloud_drive_accounts',
  'bilibili_native_download_recovery', 'podcast_download_network_recovery',
  'resumable_media_download', 'folder_smart_sync_integration',
  'progress_sync_entry', 'progress_sync_merge', 'progress_sync_store',
  'progress_sync_service', 'progress_sync_webdav', 'sync_media_origin'
) | ForEach-Object { "test/${_}_test.dart" }
$perfPassed = 0
$perfFailed = 0
$perfSkipped = 0
$perfNames = @{}
$perfFailures = [System.Collections.Generic.List[string]]::new()
$perfWriter = [System.IO.StreamWriter]::new((Join-Path $OutputDirectory 'regressions.jsonl'), $false)
$perfClock = [System.Diagnostics.Stopwatch]::StartNew()
Push-Location $perfWorkspace
try {
  & flutter test --no-pub @perfTests --reporter json --concurrency $Concurrency | ForEach-Object {
    $perfWriter.WriteLine($_)
    try { $perfEvent = $_ | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if ($perfEvent.type -eq 'testStart') { $perfNames[$perfEvent.test.id] = $perfEvent.test.name }
    if ($perfEvent.type -eq 'testDone' -and -not $perfEvent.hidden) {
      if ($perfEvent.skipped) { $perfSkipped++ }
      elseif ($perfEvent.result -eq 'success') { $perfPassed++ }
      else {
        $perfFailed++
        $perfFailures.Add([string]$perfNames[$perfEvent.testID])
      }
    }
    if ($perfEvent.type -eq 'error') {
      Write-Host ([string]$perfEvent.error).Substring(0, [Math]::Min(1500, ([string]$perfEvent.error).Length))
    }
  }
  $perfExit = $LASTEXITCODE
} finally {
  $perfWriter.Dispose()
  Pop-Location
}
$perfSummary = [ordered]@{
  passed = $perfPassed; failed = $perfFailed; skipped = $perfSkipped
  seconds = [Math]::Round($perfClock.Elapsed.TotalSeconds, 2)
  exitCode = $perfExit; failures = $perfFailures.ToArray()
}
$perfSummary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'regression-summary.json') -Encoding utf8
$perfSummary | ConvertTo-Json -Depth 5 | Write-Output
exit $perfExit
