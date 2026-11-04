"""Check local-only media execution, retired online UI and community identity.

This source check does not certify native playback, inference or binary
Corresponding Source. See docs/community-verification.md.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def verify():
    errors = []
    # Validate source-distribution candidates, not explicitly prepared, ignored
    # runtime inputs or local signing material on a maintainer's build machine.
    if (ROOT / '.git').exists():
        source_files = set(subprocess.check_output(
            ['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
            cwd=ROOT, text=True, encoding='utf-8').splitlines())
    else:
        source_files = {p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if p.is_file()}
    def check(condition, message):
        if not condition: errors.append(message)
    def text(path):
        return (ROOT/path).read_text(encoding='utf-8')
    for relative in [
        'packages/ios_ytdlp', 'android/app/src/main/python',
        'android/app/src/main/kotlin/com/example/video_player_app/YtDlpWorkerService.kt',
        'lib/features/web_media/web_media_scripts.dart',
        'lib/features/web_media/web_media_capture.dart',
        'lib/features/douyin_download/douyin_capture_script.dart',
        'lib/features/douyin_download/douyin_resource_resolver.dart',
    ]:
        check(not (ROOT/relative).exists(), 'Removed implementation returned: '+relative)
    check('ios_ytdlp:' not in text('pubspec.yaml'), 'iOS downloader dependency returned')
    check('com.chaquo.python' not in text('android/app/build.gradle.kts'), 'Python runtime dependency returned')
    check('YtDlpWorkerService' not in text('android/app/src/main/AndroidManifest.xml'), 'Downloader service returned')
    for relative in ['windows/CMakeLists.txt', 'linux/CMakeLists.txt']:
        check(not any('yt-dlp' in line for line in text(relative).splitlines()
                      if not line.lstrip().startswith('#')), 'Downloader bundling returned: '+relative)
    api=text('lib/services/bilibili/bilibili_api_service.dart')
    for endpoint in ['/x/player/playurl','/pgc/player/web/playurl','/pugv/player/web/playurl']:
        check(endpoint not in api, 'Bilibili media URL endpoint returned: '+endpoint)
    for relative in [
        'lib/features/youtube_download/services/yt_dlp_download_service.dart',
        'lib/services/bilibili/download_manager.dart',
        'lib/features/douyin_download/douyin_transfer.dart',
        'lib/features/web_media/web_media_download_service.dart',
        'lib/features/media_cache/app_media_cache_backend.dart',
    ]:
        source=text(relative)
        check('UnsupportedError(' in source, 'Acquisition no longer fails closed: '+relative)
        check(not re.search(r'await\s+(?:Process\.(?:start|run)|_dio\.(?:get|download)|_nativeBridge\.startYoutubeDownload)',source),
              'Executable acquisition returned: '+relative)
    # Retired online UI and browser engines must stay outside the active build.
    for relative in [
        'lib/features/official_online',
        'lib/widgets/embedded_browser_view.dart',
        'lib/services/browser/linux_chromium_browser.dart',
        'lib/widgets/clipboard_link_dialog.dart',
    ]:
        check(not (ROOT/relative).exists(), 'Retired online implementation returned: '+relative)
    for relative in ['pubspec.yaml', 'pubspec.lock',
                     'windows/flutter/generated_plugins.cmake',
                     'windows/flutter/generated_plugin_registrant.cc',
                     'linux/flutter/generated_plugins.cmake',
                     'macos/Flutter/GeneratedPluginRegistrant.swift']:
        check(not re.search(r'inappwebview|webview_flutter|wpe_webkit', text(relative), re.I),
              'Embedded browser dependency returned: '+relative)
    diagnostics=text('android/app/src/main/kotlin/com/example/video_player_app/EmbeddedBrowserDiagnostics.kt')
    check('android.webkit.WebView' not in diagnostics,
          'Android compatibility channel creates an embedded browser')
    listener=text('lib/widgets/app_clipboard_listener.dart')
    check(not any(token in listener for token in [
        'Clipboard.getData', 'ClipboardLinkDetector.detect', 'OfficialLinkStore',
        'YtDlpDownloadService', 'BilibiliApiService', 'downloadAndTranscribe',
    ]), 'Website clipboard recognition or media acquisition returned')
    home=text('lib/screens/home_screen.dart')
    check(not any(token in home for token in [
        'BilibiliHomePage(', 'PodcastOverviewPage(', 'CloudDriveScreen(',
        'bilibiliBuilder:', 'podcastsBuilder:', 'cloudDriveBuilder:',
    ]), 'Local home mounts a retired online surface')
    check('PodcastChannelPage(' not in text('lib/screens/collection_screen.dart'),
          'Historical local folders route into online podcast pages')
    order=text('lib/models/media_library_root_entry_order.dart')
    defaults=order.split('defaults = [',1)[1].split('];',1)[0]
    check(not any(token in defaults for token in ['.bilibili', '.podcasts', '.cloudDrive'])
          and '!entry.isLocal' in order, 'Root order must normalize to local entries only')
    startup=text('lib/main.dart')
    check(not any(token in startup for token in [
        'installPodcastNavigation(', 'PodcastRuntime.instance.init(',
        'PodcastRuntime.instance.prepareCardArtwork(', 'CloudDriveRuntime.beginInstall(',
        'bilibiliService.init(', 'ytDlpService.init(',
    ]), 'Startup installs a retired online runtime')
    source_guard=text('lib/services/community_media_input.dart')
    processing=source_guard.split('void requireCommunityProcessingSource(',1)[1].split('\n}',1)[0]
    check('requireCommunityLocalMedia(path);' in processing
          and 'requirePodcastRssMedia' not in processing,
          'Remote RSS must not bypass local processing restrictions')
    for relative, guard, minimum in [
        ('lib/services/transcription_manager.dart', 'requireCommunityProcessingSource(', 3),
        ('lib/services/media_materialization_service.dart', 'requireCommunityLocalMedia(', 6),
        ('lib/services/media_playback_service.dart', 'communityMediaIsLocal(', 2),
        ('lib/services/playback_navigation_service.dart', 'requireCommunityLocalMedia(item.path)', 3),
        ('lib/services/playback_restore_preview.dart', 'communityMediaIsLocal(item.path)', 1),
        ('lib/features/podcasts/podcast_client.dart', 'requireCommunityPodcastOnline();', 3),
        ('lib/features/podcasts/podcast_media_store.dart', 'requireCommunityPodcastOnline();', 4),
        ('lib/features/podcasts/podcast_runtime.dart', 'requireCommunityPodcastOnline();', 5),
        ('lib/services/gongyi_asr_service.dart', 'requireCommunityLocalMedia(audioPath);', 1),
        ('lib/features/cloud_drive/providers/cloud_drive_http.dart', 'requireCommunityAuthorizedCloudDrive();', 2),
        ('lib/services/bilibili/bilibili_streaming_service.dart', 'requireCommunityOfficialBilibili();', 6),
        ('lib/features/portable_transfer/portable_transfer_service.dart', 'requireCommunityProcessingSource(', 1),
    ]:
        check(text(relative).count(guard) >= minimum,
              'Local execution/recovery guard missing: '+relative)
    background=text('lib/features/podcasts/podcast_background.dart')
    check('registerPeriodicTask(' not in background and 'registerOneOffTask(' not in background,
          'Retired RSS background refresh is scheduled again')
    controls=text('lib/widgets/video_action_buttons.dart')
    menu=text('lib/widgets/media_library_actions_menu.dart')
    check('BatchImportScreen(folderId: collectionId)' in controls
          and "name: '/batch_import'" in controls
          and '批量字幕导入' in controls and '批量字幕导入' in menu,
          'Local batch media/subtitle import is no longer reachable')
    navigation=text('lib/services/app_web_navigation.dart')
    route=navigation.split('static Route<void> route(',1)[1].split('static Future',1)[0]
    check('throw UnsupportedError(' in route,
          'Legacy media/browser route no longer fails closed')
    windows=text('windows/runner/flutter_window.cpp')
    a=windows.index('void FlutterWindow::RegisterYtDlpChannel()')
    b=windows.index('void FlutterWindow::OnDestroy()',a)
    channel=windows[a:b]
    for method in ['resolveYoutubeMeta','startYoutubeDownload','getYtDlpBinaryStatus']:
        check(method not in channel, 'Windows downloader handler returned: '+method)
    android=text('android/app/src/main/kotlin/com/example/video_player_app/MainActivity.kt')
    check('com.chaquo' not in android and 'Python.getInstance' not in android,
          'Embedded Python execution returned')
    check('com.example.video_player_app.community' in text('android/app/build.gradle.kts'),
          'Android identity is not isolated')
    installer = text('packaging/windows/fluent-player.iss')
    check('DefaultDirName={localappdata}\\Programs\\FluentPlayerCommunity' in installer
          and '627EC819-F9DA-4D7C-84F3-B9BC408AD30C' in installer,
          'Windows installer identity is not isolated')
    check('io.github.t66666t.FluentPlayerCommunity' in installer
          and 'fluent_player_community.exe' in installer,
          'Windows installer shortcuts do not match the community runner')
    storage=text('lib/services/app_storage_service.dart')
    check("'FluentPlayerCommunity', 'CommunityPlayerData'" in storage,
          'Windows data directory is not isolated')
    check('      locations.documents,' not in storage,
          'Community edition must not adopt the full edition documents directory')
    linux=text('lib/platform/linux_application_identity.dart')
    check('const linuxLegacyApplicationIds = <String>[];' in linux,
          'Community edition must not adopt old Linux data')
    manifest=json.loads(text('community-contracts.json'))
    for relative, expected in manifest['preservedModelContracts'].items():
        check(hashlib.sha256((ROOT/relative).read_bytes()).hexdigest()==expected,
              'Preserved model contract changed: '+relative)
    for path in (ROOT/'lib').rglob('*.dart'):
        source=path.read_text(encoding='utf-8')
        for directive in re.findall(r'(?m)^\s*(?:import|export|part)\s+[^;]+;',source):
            for uri in re.findall(r"['\"]([^'\"]+)['\"]",directive):
                if not uri.endswith('.dart'):continue
                if uri.startswith('package:video_player_app/'):
                    target=ROOT/'lib'/uri.split('/',1)[1]
                elif ':' not in uri:
                    target=path.parent/uri
                else:continue
                check(target.is_file(), 'Missing source import: '+str(path.relative_to(ROOT))+' -> '+uri)
    for asset in re.findall(r'- asset:\s*([^\s#]+)', text('pubspec.yaml')):
        check((ROOT/asset).is_file(), 'Declared font missing: '+asset)
    # Only source inputs are checked; ignored caches belong to the developer.
    for folder in ['assets/binaries','packages/ios_ytdlp','android/app/third_party']:
        if (ROOT/folder).is_dir():
            check(not any(p.is_file() and p.relative_to(ROOT).as_posix() in source_files
                          for p in (ROOT/folder).rglob('*')), 'Unexpected prepared payload: '+folder)
    # Inspect the same source candidates without descending into generated
    # native/Gradle trees (which can exceed Windows path limits after a build).
    for relative in source_files:
        if any(p in {'.git','.dart_tool','build','.artifacts','Pods','.gradle','ephemeral'} for p in Path(relative).parts):
            continue
        path = ROOT / relative
        if path.is_file() and (path.suffix.lower() in {'.jks','.keystore','.p12','.pfx'} or path.name=='key.properties'):
            errors.append('Signing credential found: '+relative)
    return errors

if __name__=='__main__':
    if hasattr(sys.stdout, 'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    errors=verify()
    if errors:
        print('\n'.join(errors));sys.exit(1)
    print('Community local-media boundaries, retired online UI, native entry points, identities and preserved model contracts: passed')
