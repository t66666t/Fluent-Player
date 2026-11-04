// Test-only protocol proxy: use the production native worker but expose one
// actual route so pipeline/fault tests cannot silently select DirectML.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  const executable = String.fromEnvironment('ASR_ROUTE_REAL_WORKER');
  const route = String.fromEnvironment('ASR_ROUTE_BACKEND');
  if (executable.isEmpty || route.isEmpty) exit(2);
  final child = await Process.start(
    executable,
    const [],
    workingDirectory: File(executable).parent.path,
  );
  final operations = <int, String>{};
  final errors = child.stderr.drain<void>();
  final replies = child.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        try {
          final value = jsonDecode(line) as Map<String, dynamic>;
          final id = value['id'];
          if (id is! int || !operations.containsKey(id)) return;
          if (operations.remove(id) == 'capabilities') {
            value['devices'] = (value['devices'] as List? ?? const [])
                .where((d) => d is Map && d['backend'] == route)
                .toList();
            value['optionalBackends'] = <String>[];
          }
          stdout.writeln(jsonEncode(value));
        } catch (_) {
          /* Native converter diagnostics are not protocol replies. */
        }
      });
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      operations[message['id'] as int] = message['op'] as String;
      if (message['op'] == 'capabilities') message['probeBackend'] = route;
      child.stdin.writeln(jsonEncode(message));
      await child.stdin.flush();
    }
    await child.stdin.close();
    exitCode = await child.exitCode;
  } finally {
    child.kill();
    await replies.cancel();
    await errors;
  }
}
