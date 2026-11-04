import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Proves a second process can store and reload a received file without using
/// the sender directory as its library. This is not a phone/desktop speed run.
void main() {
  test('an isolated process reloads its own received file', () async {
    final dart = await _dartExecutable();
    final root = await Directory.systemTemp.createTemp('isolated_sync_');
    final sender = Directory(p.join(root.path, 'sender'));
    final receiver = Directory(p.join(root.path, 'receiver'));
    await sender.create();
    final payload = List<int>.generate(128, (index) => index);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.contentLength = payload.length;
      request.response.add(payload);
      request.response.close();
    });
    final script = p.join(
      Directory.current.path,
      'test',
      'support',
      'isolated_sync_peer.dart',
    );
    try {
      final received = await Process.run(dart, [
        script,
        'receive',
        receiver.path,
        '${server.port}',
      ]);
      expect(received.exitCode, 0, reason: '${received.stdout}${received.stderr}');
      final reloaded = await Process.run(dart, [
        script,
        'reload',
        receiver.path,
        sender.path,
      ]);
      expect(reloaded.exitCode, 0, reason: '${reloaded.stdout}${reloaded.stderr}');
      expect(reloaded.stdout.toString(), contains('reloaded 128'));
      final saved = jsonDecode(
        await File(p.join(receiver.path, 'library.json')).readAsString(),
      );
      expect(await File(saved['path'] as String).readAsBytes(), payload);
      expect(p.isWithin(sender.path, saved['path'] as String), isFalse);
    } finally {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}

Future<String> _dartExecutable() async {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?)
      p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
    p.join(p.dirname(Platform.resolvedExecutable), 'dart.exe'),
  ];
  final lookup = await Process.run('where.exe', ['dart']);
  if (lookup.exitCode == 0) {
    for (final raw in lookup.stdout.toString().split(RegExp(r'\r?\n'))) {
      final found = raw.trim();
      if (found.isEmpty) continue;
      if (found.toLowerCase().endsWith('.exe')) candidates.add(found);
      // `where dart` often returns dart.bat, which cannot be spawned directly.
      if (found.toLowerCase().endsWith('.bat')) {
        candidates.add(
          p.join(p.dirname(found), 'cache', 'dart-sdk', 'bin', 'dart.exe'),
        );
      }
    }
  }
  for (final candidate in candidates) {
    if (await File(candidate).exists()) return candidate;
  }
  throw StateError('找不到 dart，无法启动独立接收进程');
}
