import 'dart:io';

/// A test-only certificate and key, generated locally for each test process.
class TemporaryTlsFixture {
  TemporaryTlsFixture._(this.directory);

  final Directory directory;
  String get certificate =>
      '${directory.path}${Platform.pathSeparator}cert.pem';
  String get privateKey => '${directory.path}${Platform.pathSeparator}key.pem';

  static Future<TemporaryTlsFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'fluent-player-tls-',
    );
    final fixture = TemporaryTlsFixture._(directory);
    try {
      final executable = await _opensslExecutable();
      final result = await Process.run(executable, [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '2',
        '-keyout',
        fixture.privateKey,
        '-out',
        fixture.certificate,
        '-subj',
        '/CN=Fluent Player local test',
        '-addext',
        'subjectAltName=DNS:origin.test,DNS:proxy.test,DNS:localhost,IP:127.0.0.1,IP:::1',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'OpenSSL could not generate a test certificate: ${result.stderr}',
        );
      }
      return fixture;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static Future<String> _opensslExecutable() async {
    try {
      final result = await Process.run('openssl', ['version']);
      if (result.exitCode == 0) return 'openssl';
    } on ProcessException {
      // Git for Windows also ships OpenSSL, even when it is not on PATH.
    }
    if (Platform.isWindows) {
      final result = await Process.run('where', ['git.exe']);
      if (result.exitCode == 0) {
        for (final path in (result.stdout as String).trim().split(
          RegExp(r'\r?\n'),
        )) {
          final git = File(path.trim());
          final candidate = File(
            '${git.parent.parent.path}\\usr\\bin\\openssl.exe',
          );
          if (await candidate.exists()) return candidate.path;
        }
      }
    }
    throw StateError(
      'OpenSSL is required to generate temporary TLS test certificates.',
    );
  }

  Future<void> dispose() async {
    await directory.delete(recursive: true);
  }
}
