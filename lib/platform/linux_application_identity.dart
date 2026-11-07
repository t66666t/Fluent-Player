import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../utils/app_branding.dart';

const linuxApplicationId = kApplicationId;
// Only the former community edition is eligible for settings/catalog reuse.
// The unsuffixed identity belongs to historical Pro/full builds.
const linuxLegacyApplicationIds = <String>['cn.teezy.fluentplayer.community'];

/// Copy the settings used by the old GTK application ID before any preferences
/// singleton is loaded. Original settings/catalogs/media are never moved.
Future<void> prepareLinuxApplicationIdentity({
  Map<String, String>? environment,
}) async {
  if (environment == null && !Platform.isLinux) return;
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_DATA_HOME'];
  final home = env['HOME'];
  final base = xdg != null && p.isAbsolute(xdg)
      ? xdg
      : home != null && p.isAbsolute(home)
      ? p.join(home, '.local', 'share')
      : null;
  if (base == null) throw const FileSystemException('无法确定 Linux 应用数据目录');
  final destination = File(
    p.join(base, linuxApplicationId, 'shared_preferences.json'),
  );
  if (await destination.exists()) return;
  // The former application ID had priority over the executable-name fallback.
  // Keep the same priority, rather than choosing settings by modification time.
  for (final legacy in linuxLegacyApplicationIds) {
    final source = File(p.join(base, legacy, 'shared_preferences.json'));
    if (!await source.exists()) continue;
    final bytes = await source.readAsBytes();
    if (jsonDecode(utf8.decode(bytes)) is! Map) {
      throw const FormatException('旧版 Linux 设置不是有效的 JSON 对象，原文件已保留');
    }
    await destination.parent.create(recursive: true);
    final lock = await File(
      p.join(destination.parent.path, 'identity-migration.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      if (!await destination.exists()) {
        final pending = File('${destination.path}.migrating');
        await pending.writeAsBytes(bytes, flush: true);
        if (Platform.isLinux) {
          final permission = await Process.run('chmod', ['600', pending.path]);
          if (permission.exitCode != 0) {
            throw const FileSystemException('无法设置迁移设置文件的私有权限');
          }
        }
        await pending.rename(destination.path);
      }
    } finally {
      await lock.close();
    }
    return;
  }
}
