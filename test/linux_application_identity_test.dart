import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/platform/linux_application_identity.dart';
import 'package:video_player_app/platform/linux_media_runtime.dart';

void main() {
  late Directory temporary;
  setUp(
    () async =>
        temporary = await Directory.systemTemp.createTemp('linux_identity_'),
  );
  tearDown(() async => temporary.delete(recursive: true));

  Future<File> settings(String name, String json) async {
    final file = File(p.join(temporary.path, name, 'shared_preferences.json'));
    await file.parent.create(recursive: true);
    return file.writeAsString(json);
  }

  test(
    'formal ID copies the former authoritative settings and retains both originals',
    () async {
      final old = await settings(
        'com.example.video_player_app',
        '{"flutter.volume":0.6}',
      );
      final fallback = await settings(
        'video_player_app',
        '{"flutter.volume":0.2}',
      );
      await prepareLinuxApplicationIdentity(
        environment: {'XDG_DATA_HOME': temporary.path},
      );
      final current = File(
        p.join(temporary.path, linuxApplicationId, 'shared_preferences.json'),
      );
      expect(await current.readAsString(), await old.readAsString());
      expect(await fallback.readAsString(), '{"flutter.volume":0.2}');
      await current.writeAsString('{"flutter.volume":0.9}');
      await prepareLinuxApplicationIdentity(
        environment: {'XDG_DATA_HOME': temporary.path},
      );
      expect(await current.readAsString(), '{"flutter.volume":0.9}');
      expect(await old.readAsString(), '{"flutter.volume":0.6}');
    },
  );

  test(
    'malformed legacy preferences cannot replace settings with an empty file',
    () async {
      await settings('com.example.video_player_app', 'broken');
      await expectLater(
        prepareLinuxApplicationIdentity(
          environment: {'XDG_DATA_HOME': temporary.path},
        ),
        throwsFormatException,
      );
      expect(
        await File(
          p.join(temporary.path, linuxApplicationId, 'shared_preferences.json'),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'packaged mpv selection cannot fall through to another system ABI',
    () async {
      final lib = Directory(p.join(temporary.path, 'lib'));
      await lib.create();
      final mpv = await File(
        p.join(lib.path, 'libmpv.so.1'),
      ).writeAsString('fixture');
      await File(
        p.join(temporary.path, 'linux-runtime.json'),
      ).writeAsString('{"mpvSoname":"libmpv.so.1"}');
      expect(bundledLinuxMpv(temporary), mpv.path);
      await mpv.rename('${mpv.path}.missing');
      await File(
        p.join(lib.path, 'libmpv.so.2'),
      ).writeAsString('different ABI');
      expect(() => bundledLinuxMpv(temporary), throwsStateError);
    },
  );

  test(
    'two unpacked mpv ABIs require a clean installation directory',
    () async {
      final lib = await Directory(p.join(temporary.path, 'lib')).create();
      for (final name in ['libmpv.so.1', 'libmpv.so.2']) {
        await File(p.join(lib.path, name)).writeAsString('fixture');
      }
      expect(() => bundledLinuxMpv(temporary), throwsStateError);
    },
  );
}
