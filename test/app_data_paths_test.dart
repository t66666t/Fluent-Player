import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/utils/app_data_paths.dart';

void main() {
  test('XDG_DATA_HOME fallback uses app folder name', () async {
    final root = await Directory.systemTemp.createTemp('app_data_paths_');
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final dir = await createXdgDataHomeFallback(
      environment: <String, String>{'XDG_DATA_HOME': root.path},
    );

    expect(dir.path, p.join(root.path, kAppDataFolderName));
    expect(await dir.exists(), isTrue);
    expect(kAppDataFolderName, 'io.github.t66666t.FluentPlayer');
  });

  test('HOME fallback uses the formal Linux application ID', () async {
    final root = await Directory.systemTemp.createTemp('app_data_home_');
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final dir = await createXdgDataHomeFallback(
      environment: <String, String>{'HOME': root.path},
    );

    expect(dir.path, p.join(root.path, '.local', 'share', kAppDataFolderName));
    expect(await dir.exists(), isTrue);
  });
}
