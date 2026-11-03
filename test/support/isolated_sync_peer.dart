import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Second process for a folder sync check.
///
/// The parent serves bytes. This process writes them only inside its own data
/// directory, then a later invocation reloads that directory and checks the
/// file. It must not treat the sender's path as its own media.
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: isolated_sync_peer.dart <receive|reload> <dataDir> ...');
    exitCode = 64;
    return;
  }
  final command = args[0];
  final dataDir = Directory(args[1]);
  await dataDir.create(recursive: true);
  if (command == 'receive') {
    final port = int.parse(args[2]);
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/video.bin'),
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        exitCode = 1;
        return;
      }
      final bytes = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final file = File('${dataDir.path}${Platform.pathSeparator}video.bin');
      await file.writeAsBytes(bytes.takeBytes(), flush: true);
      await File(
        '${dataDir.path}${Platform.pathSeparator}library.json',
      ).writeAsString(
        jsonEncode({'path': file.path, 'length': await file.length()}),
        flush: true,
      );
    } finally {
      client.close(force: true);
    }
    return;
  }
  if (command == 'reload') {
    final senderDir = args[2];
    final saved = jsonDecode(
      await File(
        '${dataDir.path}${Platform.pathSeparator}library.json',
      ).readAsString(),
    );
    final file = File(saved['path'] as String);
    if (!await file.exists() || await file.length() != saved['length']) {
      exitCode = 2;
      return;
    }
    if (pEquals(file.path, senderDir) || _inside(senderDir, file.path)) {
      exitCode = 3;
      return;
    }
    stdout.writeln('reloaded ${await file.length()}');
    return;
  }
  exitCode = 64;
}

bool pEquals(String a, String b) =>
    a.replaceAll('\\', '/').toLowerCase() ==
    b.replaceAll('\\', '/').toLowerCase();

bool _inside(String parent, String child) {
  final root = parent.replaceAll('\\', '/').toLowerCase();
  final path = child.replaceAll('\\', '/').toLowerCase();
  return path.startsWith(root.endsWith('/') ? root : '$root/');
}
