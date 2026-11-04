import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/platform/linux_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.t66666t.FluentPlayer/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  setUp(
    () async =>
        temporary = await Directory.systemTemp.createTemp('linux_picker_'),
  );
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test(
    'multiple Unicode file paths retain bytes and streams without portal calls',
    () async {
      final first = await File(
        '${temporary.path}/字幕 视频.mkv',
      ).writeAsBytes([1, 2, 3]);
      final second = await File(
        '${temporary.path}/another.mkv',
      ).writeAsBytes([4, 5]);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'choose');
        expect(call.arguments['action'], 'open');
        expect(call.arguments['multiple'], isTrue);
        expect(call.arguments['extensions'], ['mkv']);
        return [first.path, second.path];
      });
      final result = await LinuxFilePicker().pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mkv'],
        allowMultiple: true,
        withData: true,
        withReadStream: true,
      );
      expect(result!.paths, [first.path, second.path]);
      expect(result.files.first.bytes, [1, 2, 3]);
      expect(
        await result.files.first.readStream!.expand((chunk) => chunk).toList(),
        [1, 2, 3],
      );
    },
  );

  test(
    'cancel and native errors release the chooser for a later request',
    () async {
      var failed = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (failed) throw PlatformException(code: 'dialog_failed');
        return <String>[];
      });
      final picker = LinuxFilePicker();
      await expectLater(
        picker.getDirectoryPath(),
        throwsA(isA<PlatformException>()),
      );
      failed = false;
      expect(await picker.getDirectoryPath(), isNull);
      expect(await picker.pickFiles(), isNull);
    },
  );

  test('a second request cannot hide an existing chooser', () async {
    final response = Completer<List<String>>();
    messenger.setMockMethodCallHandler(channel, (call) => response.future);
    final picker = LinuxFilePicker();
    final first = picker.getDirectoryPath();
    await expectLater(picker.getDirectoryPath(), throwsStateError);
    response.complete([]);
    expect(await first, isNull);
  });

  test('save writes bytes only after a successful selection', () async {
    final destination = File('${temporary.path}/导出.srt');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['action'], 'save');
      return [destination.path];
    });
    expect(
      await LinuxFilePicker().saveFile(bytes: Uint8List.fromList([10, 20])),
      destination.path,
    );
    expect(await destination.readAsBytes(), [10, 20]);
  });
}
