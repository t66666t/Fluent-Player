import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Both Dart FFI and the renderer must use the very same mpv ABI and library.
/// A system libmpv.so.2 and a plugin linked to bundled .so.1 cannot share handles.
String? bundledLinuxMpv(Directory application) {
  final metadata = File(p.join(application.path, 'linux-runtime.json'));
  if (metadata.existsSync()) {
    final record = jsonDecode(metadata.readAsStringSync());
    final soname = record is Map ? record['mpvSoname'] : null;
    if (soname != 'libmpv.so.1' && soname != 'libmpv.so.2') {
      throw StateError('媒体运行库清单无效，请完整重新解压安装包');
    }
    final library = File(p.join(application.path, 'lib', soname as String));
    if (!library.existsSync()) throw StateError('安装包缺少 $soname，请完整重新解压');
    return library.path;
  }
  final libraries = ['libmpv.so.2', 'libmpv.so.1']
      .map((name) => File(p.join(application.path, 'lib', name)))
      .where((file) => file.existsSync())
      .toList();
  if (libraries.length > 1) throw StateError('检测到多套 mpv 运行库，请使用完整的新安装目录');
  return libraries.firstOrNull?.path;
}

void initializeLinuxMediaRuntime() {
  if (!Platform.isLinux) return;
  MediaKit.ensureInitialized(
    libmpv: bundledLinuxMpv(File(Platform.resolvedExecutable).parent),
  );
}
