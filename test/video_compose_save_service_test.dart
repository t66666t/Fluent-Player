import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/video_compose/android_compose_storage_access.dart';
import 'package:video_player_app/services/video_compose/video_compose_save_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const android = MethodChannel('test/compose_android_save');
  const ios = MethodChannel('test/compose_ios_share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('compose_save_test_');
    source = File(p.join(root.path, '中文 合成视频.mp4'));
    await source.writeAsBytes(List<int>.generate(8192, (index) => index % 256));
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(android, null);
    messenger.setMockMethodCallHandler(ios, null);
    await root.delete(recursive: true);
  });

  test(
    'Android passes only the existing file path and distinguishes outcomes',
    () async {
      final calls = <MethodCall>[];
      final results = <bool?>[true, false, null];
      messenger.setMockMethodCallHandler(android, (call) async {
        calls.add(call);
        return results.removeAt(0);
      });
      const service = VideoComposeSaveService(
        platform: TargetPlatform.android,
        androidChannel: android,
      );
      final before = await source.readAsBytes();
      expect(await service.save(source.path), VideoComposeSaveResult.saved);
      expect(await service.save(source.path), VideoComposeSaveResult.cancelled);
      expect(
        await service.save(source.path),
        VideoComposeSaveResult.unavailable,
      );
      expect(calls.map((call) => call.method), ['save', 'save', 'save']);
      expect(calls.first.arguments, {'path': source.path});
      expect(await source.readAsBytes(), before);
    },
  );

  test('Android provider errors leave the composed file intact', () async {
    messenger.setMockMethodCallHandler(android, (_) async {
      throw PlatformException(
        code: 'SAVE_FAILED',
        message: 'storage unavailable',
      );
    });
    const service = VideoComposeSaveService(
      platform: TargetPlatform.android,
      androidChannel: android,
    );
    await expectLater(
      service.save(source.path),
      throwsA(isA<PlatformException>()),
    );
    expect(await source.length(), 8192);
  });

  test('iOS presents the original video with a valid iPad anchor', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(ios, (call) async {
      received = call;
      return true;
    });
    const service = VideoComposeSaveService(
      platform: TargetPlatform.iOS,
      shareChannel: ios,
    );
    expect(
      await service.save(
        source.path,
        origin: const Rect.fromLTWH(10, 20, 1, 1),
      ),
      VideoComposeSaveResult.sharePresented,
    );
    expect(received!.method, 'shareFile');
    expect(received!.arguments, {
      'path': source.path,
      'mimeType': 'video/mp4',
      'originX': 10.0,
      'originY': 20.0,
      'originWidth': 1.0,
      'originHeight': 1.0,
    });
    expect(await source.length(), 8192);
  });

  test(
    'missing and invalid source paths do not launch a system surface',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(android, (_) async {
        calls++;
        return true;
      });
      const service = VideoComposeSaveService(
        platform: TargetPlatform.android,
        androidChannel: android,
      );
      await expectLater(service.save('relative.mp4'), throwsArgumentError);
      await expectLater(
        service.save(p.join(root.path, 'missing.mp4')),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'Android default output is app-owned and needs no broad permission',
    () async {
      final path = await androidPrivateComposeOutputDirectory(
        documentsDirectory: () async =>
            Directory('/data/user/0/example/app_flutter'),
      );
      // This helper runs on Windows in CI, so normalize the generated separator
      // before checking the Android path policy.
      final androidPath = path.replaceAll('\\', '/');
      expect(androidPath, '/data/user/0/example/app_flutter/exports/composed');
      expect(composeOutputRequiresAllFilesPermission(androidPath), isFalse);
    },
  );

  test(
    'Android output selection preserves user directories and handles denial',
    () async {
      var prompts = 0;
      var requests = 0;
      var privateLookups = 0;
      Future<String?> resolve(
        String? selected, {
        bool granted = false,
        bool accept = false,
      }) => resolveAndroidComposeOutputDirectory(
        selectedDirectory: selected,
        requiresPermission: (path) async => path.startsWith('/storage/'),
        requestPermission: () async {
          requests++;
          return granted;
        },
        useAppDirectory: () async {
          prompts++;
          return accept;
        },
        appDirectory: () async {
          privateLookups++;
          return '/app/exports/composed';
        },
      );

      expect(await resolve(null), '/app/exports/composed');
      expect(requests, 0);
      expect(await resolve('/data/private/custom'), '/data/private/custom');
      expect(requests, 0);
      expect(
        await resolve('/storage/shared/custom', granted: true),
        '/storage/shared/custom',
      );
      expect(await resolve('/storage/shared/custom'), isNull);
      expect(
        await resolve('/storage/shared/custom', accept: true),
        '/app/exports/composed',
      );
      expect(requests, 3);
      expect(prompts, 2);
      expect(privateLookups, 2);
    },
  );

  test(
    'output directory preflight checks writability without leaving a file',
    () async {
      final output = Directory(p.join(root.path, 'new output'));
      await prepareComposeOutputDirectory(output.path);
      expect(await output.exists(), isTrue);
      expect(await output.list().toList(), isEmpty);
      final existing = File(p.join(root.path, 'existing'));
      await existing.writeAsString('keep');
      await expectLater(
        prepareComposeOutputDirectory(p.join(existing.path, 'output')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsString(), 'keep');
    },
  );
}
