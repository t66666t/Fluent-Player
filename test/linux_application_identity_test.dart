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

  test('community identity never adopts full-edition preferences', () async {
    expect(linuxApplicationId, 'cn.teezy.fluentplayer.standard');
    expect(linuxLegacyApplicationIds, ['cn.teezy.fluentplayer.community']);
    final originals = <File>[
      for (final id in [
        'cn.teezy.fluentplayer',
        'cn.teezy.fluentplayer.pro',
        'io.github.t66666t.FluentPlayer',
        'com.example.video_player_app',
        'video_player_app',
      ])
        await settings(id, '{"flutter.volume":0.6}'),
    ];
    await prepareLinuxApplicationIdentity(
      environment: {'XDG_DATA_HOME': temporary.path},
    );
    final current = File(
      p.join(temporary.path, linuxApplicationId, 'shared_preferences.json'),
    );
    expect(await current.exists(), isFalse);
    for (final original in originals) {
      expect(await original.readAsString(), '{"flutter.volume":0.6}');
    }
  });

  test('existing community preferences remain authoritative', () async {
    await settings('cn.teezy.fluentplayer', 'broken');
    final current = await settings(
      linuxApplicationId,
      '{"flutter.volume":0.9}',
    );
    await prepareLinuxApplicationIdentity(
      environment: {'XDG_DATA_HOME': temporary.path},
    );
    expect(await current.readAsString(), '{"flutter.volume":0.9}');
  });

  test(
    'standard identity reuses only its former community preferences',
    () async {
      final oldCommunity = await settings(
        'cn.teezy.fluentplayer.community',
        '{"flutter.volume":0.7}',
      );
      final full = await settings(
        'cn.teezy.fluentplayer',
        '{"flutter.volume":0.1}',
      );
      final pro = await settings(
        'cn.teezy.fluentplayer.pro',
        '{"flutter.volume":0.2}',
      );
      await prepareLinuxApplicationIdentity(
        environment: {'XDG_DATA_HOME': temporary.path},
      );
      final current = File(
        p.join(temporary.path, linuxApplicationId, 'shared_preferences.json'),
      );
      expect(await current.readAsString(), await oldCommunity.readAsString());
      expect(await full.readAsString(), '{"flutter.volume":0.1}');
      expect(await pro.readAsString(), '{"flutter.volume":0.2}');
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
