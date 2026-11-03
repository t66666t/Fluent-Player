"""Check the community source boundary without downloading models or native tools."""
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def verify():
    errors = []
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
            check(not any(p.is_file() for p in (ROOT/folder).rglob('*')), 'Unexpected prepared payload: '+folder)
    for path in ROOT.rglob('*'):
        if any(p in {'.git','.dart_tool','build','.artifacts','Pods','.gradle','ephemeral'} for p in path.relative_to(ROOT).parts):
            continue
        if path.is_file() and (path.suffix.lower() in {'.jks','.keystore','.p12','.pfx'} or path.name=='key.properties'):
            errors.append('Signing credential found: '+str(path.relative_to(ROOT)))
    return errors

if __name__=='__main__':
    if hasattr(sys.stdout, 'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    errors=verify()
    if errors:
        print('\n'.join(errors));sys.exit(1)
    print('Community boundary, native entry points, identities and preserved model contracts: passed')
