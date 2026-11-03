import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/open_with_other_apps.dart';
import 'package:video_player_app/utils/source_media_file_actions.dart';

VideoItem media(String path, {MediaType type = MediaType.video}) => VideoItem(
  id: 'source',
  path: path,
  playbackPath: '/cache/converted.mp4',
  title: '../different # title %20, https://example.com/other.mp4',
  durationMs: 0,
  lastUpdated: 1,
  type: type,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(openWithOtherAppsChannel, null);
  });

  test('plain absolute filenames are literal, including percent escapes', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      const source = '/media/中文 空格, #100% [a] & ; \$x/ https:%20\n片段.mp4 ';
      expect(sourceMediaFilePath(source, platform: platform), source);
    }
    for (final source in [
      r'C:\视频 资料\a, #100% %20 & [x] (1).mp4',
      r'\\server\share name\a, #100%.mkv',
      r'\\?\C:\video\a, #100%.mp4',
    ]) {
      expect(
        sourceMediaFilePath(source, platform: TargetPlatform.windows),
        source,
      );
    }
  });

  test('only real file URIs are decoded, exactly once', () {
    const source = '/media/片段, #100% %20.mp4';
    expect(
      sourceMediaFilePath(
        Uri.file(source, windows: false).toString(),
        platform: TargetPlatform.iOS,
      ),
      source,
    );
    const windowsSource = r'C:\视频 资料\a, #100% %20.mp4';
    expect(
      sourceMediaFilePath(
        Uri.file(windowsSource, windows: true).toString(),
        platform: TargetPlatform.windows,
      ),
      windowsSource,
    );
    for (final uri in [
      'file:///tmp/a.mp4?other=file',
      'file:///tmp/a.mp4#other',
      'file:///tmp/a%00.mp4',
    ]) {
      expect(
        sourceMediaFilePath(uri, platform: TargetPlatform.android),
        isNull,
      );
    }
  });

  test(
    'remote identities, relative paths and NUL cannot become local paths',
    () {
      for (final source in [
        '',
        ' ',
        'clip.mp4',
        '../clip.mp4',
        'https://example.com/a.mp4',
        'bilibili://stream/BV1',
        'cloud-drive://account/file',
        'podcast:episode',
        '/tmp/first.mp4\u0000/other.mp4',
      ]) {
        expect(
          sourceMediaFilePath(source, platform: TargetPlatform.linux),
          isNull,
          reason: source,
        );
      }
      expect(
        sourceMediaFilePath(r'C:clip.mp4', platform: TargetPlatform.windows),
        isNull,
      );
      expect(
        sourceMediaFilePath(r'\clip.mp4', platform: TargetPlatform.windows),
        isNull,
      );
    },
  );

  test('content URI is preserved for Android and rejected elsewhere', () {
    const uri = 'content://provider/document/primary%3AMovies%2Fa%2520%23.mp4';
    expect(sourceMediaFilePath(uri, platform: TargetPlatform.android), uri);
    expect(sourceMediaFilePath(uri, platform: TargetPlatform.iOS), isNull);
    expect(
      sourceMediaFilePath(
        'content:///document/1',
        platform: TargetPlatform.android,
      ),
      isNull,
    );
  });

  test(
    'only offline sources offer the action, including downloaded URL provenance',
    () {
      final actions = SourceMediaFileActions(platform: TargetPlatform.android);
      final item = media('/storage/Movies/source.mp4');
      expect(actions.pathFor(item), item.path);
      item.sourceRef = const MediaSourceRef(
        value: 'https://example.com/original',
        kind: MediaSourceKind.url,
      );
      expect(actions.pathFor(item), item.path);
      for (final kind in [
        MediaSourceKind.cloudDrive,
        MediaSourceKind.bilibiliStream,
      ]) {
        item.sourceRef = MediaSourceRef(value: 'online', kind: kind);
        expect(actions.pathFor(item), isNull);
      }
      item.sourceRef = null;
      item.isRecycled = true;
      expect(actions.pathFor(item), isNull);
      expect(
        SourceMediaFileActions(
          platform: TargetPlatform.fuchsia,
        ).pathFor(media('/tmp/source.mp4')),
        isNull,
      );
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '$platform shares the original external/private file and iPad anchor',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(openWithOtherAppsChannel, (
          call,
        ) async {
          calls.add(call);
          return true;
        });
        final actions = SourceMediaFileActions(platform: platform);
        expect(actions.label, '分享源媒体文件');
        for (final source in [
          '/storage/ABCD-1234/Movies/中文, #100% %20.mp4',
          '/data/user/0/app/app_flutter/Private/中文, #100% %20.mp4',
          '/var/mobile/Containers/Data/Application/id/Documents/中文, #100% %20.mp4',
        ]) {
          final item = media(source, type: MediaType.audio);
          expect(
            await actions.open(
              item,
              sharePositionOrigin: const Rect.fromLTWH(3, 4, 20, 30),
            ),
            SourceMediaFileResult.opened,
          );
          expect(calls.last.method, 'shareFile');
          expect(calls.last.arguments, {
            'path': source,
            'mimeType': 'audio/*',
            'originX': 3.0,
            'originY': 4.0,
            'originWidth': 20.0,
            'originHeight': 30.0,
          });
        }
        expect(calls, hasLength(3));
      },
    );
  }

  test(
    'native failures produce actionable results without a copy/retry',
    () async {
      var calls = 0;
      for (final entry in {
        'SOURCE_MISSING': SourceMediaFileResult.missing,
        'SOURCE_PERMISSION_DENIED': SourceMediaFileResult.permissionDenied,
        'SHARE_FAILED': SourceMediaFileResult.unavailable,
      }.entries) {
        messenger.setMockMethodCallHandler(openWithOtherAppsChannel, (_) async {
          calls++;
          throw PlatformException(code: entry.key);
        });
        expect(
          await SourceMediaFileActions(
            platform: TargetPlatform.android,
          ).open(media('/private/a.mp4')),
          entry.value,
        );
      }
      expect(calls, 3);
      messenger.setMockMethodCallHandler(openWithOtherAppsChannel, null);
      expect(
        await SourceMediaFileActions(
          platform: TargetPlatform.iOS,
        ).open(media('/private/a.mp4')),
        SourceMediaFileResult.unavailable,
      );
    },
  );

  test(
    'desktop passes the exact source and never reveals a missing file parent',
    () async {
      final root = await Directory.systemTemp.createTemp('source_media_');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        p.join(root.path, '中文, #100% %20 & [a].mp4'),
      ).writeAsString('source');
      final revealed = <String>[];
      final actions = SourceMediaFileActions(
        platform: Platform.isWindows
            ? TargetPlatform.windows
            : TargetPlatform.linux,
        reveal: (path) async {
          revealed.add(path);
          return true;
        },
      );
      expect(actions.label, '打开源文件位置');
      expect(
        await actions.open(media(file.path)),
        SourceMediaFileResult.opened,
      );
      expect(revealed, [file.path]);
      await file.delete();
      expect(
        await actions.open(media(file.path)),
        SourceMediaFileResult.missing,
      );
      expect(
        await actions.open(media(root.path)),
        SourceMediaFileResult.missing,
      );
      expect(revealed, [file.path]);
    },
  );
}
