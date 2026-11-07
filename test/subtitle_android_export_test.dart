import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_stream_source.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

class _SavePicker extends FilePicker {
  final names = <String?>[];
  final contents = <List<int>>[];
  Future<String?> Function(int call)? respond;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    names.add(fileName);
    contents.add(List<int>.of(bytes!));
    return respond!(names.length);
  }
}

class _StreamSource implements SubtitleStreamSource {
  _StreamSource(this.current);
  final SubtitleStreamUpdate current;

  @override
  final ValueNotifier<int> subtitleFilesRevision = ValueNotifier<int>(0);

  // Keep the fixture's associated row as the only visible export action.
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => const [];

  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      current.paths.contains(path) ? current : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source;
  late _SavePicker picker;
  FilePicker? previousPicker;
  final originalBytes = <int>[
    0xef,
    0xbb,
    0xbf,
    ...utf8.encode('1\r\n00:00:00,000 --> 00:00:01,000\r\n字幕\r\n'),
  ];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('subtitle_android_export_');
    source = File(p.join(root.path, '测试字幕.srt'))
      ..writeAsBytesSync(originalBytes);
    SharedPreferences.setMockInitialValues({
      'subtitle_download_path': p.join(root.path, 'old-unwritable-directory'),
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.largeDataRootPath = root.path;
    try {
      previousPicker = FilePicker.platform;
    } on Error catch (error) {
      if (!error.toString().startsWith('LateInitializationError:')) rethrow;
      previousPicker = null;
    }
    picker = _SavePicker();
    FilePicker.platform = picker;
  });

  tearDown(() async {
    if (previousPicker != null) FilePicker.platform = previousPicker!;
    SettingsService().resetForTest();
    await AppToast.dismiss(immediate: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    SubtitleManagementAppearance appearance =
        SubtitleManagementAppearance.standard,
    _StreamSource? stream,
    required Future<bool> Function(String) reveal,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1500);
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      stream?.subtitleFilesRevision.dispose();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<EmbeddedSubtitleService>(
              create: (_) => EmbeddedSubtitleService(),
            ),
            if (stream != null)
              Provider<SubtitleStreamSource>.value(value: stream),
          ],
          child: MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            theme: ThemeData(platform: TargetPlatform.android),
            home: Scaffold(
              body: SubtitleManagementSheet(
                videoPath: p.join(root.path, 'video.mp4'),
                localSubtitles: {'字幕': source.path},
                showEmbeddedSubtitles: false,
                appearance: appearance,
                useAndroidDocumentPicker: true,
                revealSavedSubtitle: reveal,
                onSubtitleChanged: () {},
                onOpenAi: () {},
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(find.byTooltip('导出字幕'), findsOneWidget);
  }

  Future<void> waitUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(condition(), isTrue);
  }

  Future<void> tapExport(WidgetTester tester) async {
    final button = find.byTooltip('导出字幕');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.runAsync(() => tester.tap(button));
  }

  for (final appearance in SubtitleManagementAppearance.values) {
    testWidgets('Android picker receives exact subtitle bytes in $appearance', (
      tester,
    ) async {
      picker.respond = (_) async => '/document/primary:Download/测试字幕.srt';
      var revealCount = 0;
      await pumpSheet(
        tester,
        appearance: appearance,
        reveal: (_) async {
          revealCount++;
          return true;
        },
      );

      await tapExport(tester);
      await waitUntil(tester, () => find.text('字幕已保存').evaluate().isNotEmpty);
      expect(picker.names, ['测试字幕.srt']);
      expect(picker.contents.single, originalBytes);
      expect(source.readAsBytesSync(), originalBytes);
      expect(find.text('已保存到所选位置。'), findsOneWidget);
      expect(revealCount, 0);
      expect(
        Directory(p.join(root.path, 'old-unwritable-directory')).existsSync(),
        isFalse,
      );
    });
  }

  testWidgets(
    'cancellation leaves the source intact and allows another export',
    (tester) async {
      picker.respond = (call) async => call == 1 ? null : '/document/saved';
      await pumpSheet(
        tester,
        reveal: (_) async => throw StateError('unexpected'),
      );
      await tapExport(tester);
      await waitUntil(tester, () => find.text('已取消导出').evaluate().isNotEmpty);
      expect(source.readAsBytesSync(), originalBytes);
      await tapExport(tester);
      await waitUntil(tester, () => find.text('字幕已保存').evaluate().isNotEmpty);
      expect(picker.names.length, 2);
    },
  );

  testWidgets('picker failure is visible and can be retried', (tester) async {
    picker.respond = (call) async {
      if (call == 1) throw PlatformException(code: 'write_failed');
      return '/document/saved';
    };
    await pumpSheet(
      tester,
      reveal: (_) async => throw StateError('unexpected'),
    );
    await tapExport(tester);
    await waitUntil(tester, () => find.text('导出字幕失败').evaluate().isNotEmpty);
    expect(find.text('重试'), findsOneWidget);
    expect(source.readAsBytesSync(), originalBytes);
    await tester.runAsync(() => tester.tap(find.text('重试')));
    await waitUntil(tester, () => find.text('字幕已保存').evaluate().isNotEmpty);
    expect(picker.contents.length, 2);
    expect(picker.contents.last, originalBytes);
  });

  testWidgets('a pending picker cannot be opened twice', (tester) async {
    final result = Completer<String?>();
    picker.respond = (_) => result.future;
    await pumpSheet(
      tester,
      reveal: (_) async => throw StateError('unexpected'),
    );
    await tapExport(tester);
    await waitUntil(tester, () => picker.names.isNotEmpty);
    await tapExport(tester);
    expect(picker.names.length, 1);
    result.complete(null);
    await waitUntil(tester, () => find.text('已取消导出').evaluate().isNotEmpty);
  });

  for (final isPrimary in [true, false]) {
    testWidgets(
      'unfinished ${isPrimary ? 'primary' : 'secondary'} stream exports its current cues',
      (tester) async {
        final primary = SubtitleCueBuffer()
          ..addAll([
            SubtitleItem(
              index: 1,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
              text: '原文',
            ),
          ]);
        final secondary = SubtitleCueBuffer()
          ..addAll([
            SubtitleItem(
              index: 1,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 1),
              text: '译文',
            ),
          ]);
        final stream = _StreamSource(
          SubtitleStreamUpdate(
            generationId: 'generation',
            mediaKey: 'video',
            videoPath: p.join(root.path, 'video.mp4'),
            videoId: null,
            revision: 1,
            primaryPath: isPrimary
                ? source.path
                : p.join(root.path, 'other.srt'),
            secondaryPath: isPrimary ? null : source.path,
            primary: primary.snapshot,
            secondary: secondary.snapshot,
            addedPrimary: const [],
            addedSecondary: const [],
            primaryBytes: 1,
            secondaryBytes: 1,
            processedThrough: const Duration(seconds: 1),
            phase: SubtitleStreamPhase.generating,
          ),
        );
        picker.respond = (_) async => '/document/saved';
        await pumpSheet(tester, stream: stream, reveal: (_) async => false);
        await tapExport(tester);
        await waitUntil(tester, () => find.text('字幕已保存').evaluate().isNotEmpty);
        expect(
          utf8.decode(picker.contents.single),
          '1\n00:00:00,000 --> 00:00:01,000\n${isPrimary ? '原文' : '译文'}\n\n',
        );
        expect(source.readAsBytesSync(), originalBytes);
      },
    );
  }
}
