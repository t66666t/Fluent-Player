import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:video_player_app/utils/app_data_paths.dart';

import '../../debug/developer_log.dart' as developer;

/// Minimal key/value secret storage, so tests can replace the OS keychain.
abstract interface class BilibiliSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Default implementation backed by the platform secure storage
/// (Windows: AES-GCM file + Credential Manager key, Android: Keystore,
/// Linux: libsecret, Apple: Keychain).
class PlatformBilibiliSecretStorage implements BilibiliSecretStorage {
  PlatformBilibiliSecretStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Outcome of moving the old plain-text cookie folder into secure storage.
enum BilibiliLegacyCookieMigration {
  /// No legacy cookie folder exists.
  none,

  /// Cookies were stored securely and the legacy folder was removed.
  migrated,

  /// The legacy folder had no usable cookie and was removed.
  discardedEmpty,

  /// Secure storage could not be written or verified; the legacy folder is
  /// kept so the next start can retry. [legacyCookies] still holds the login
  /// so the current session is not signed out.
  failedKeptLegacy,
}

class BilibiliLegacyCookieMigrationResult {
  const BilibiliLegacyCookieMigrationResult(
    this.outcome, [
    this.legacyCookies = const <String, String>{},
  ]);

  final BilibiliLegacyCookieMigration outcome;
  final Map<String, String> legacyCookies;
}

/// Stores the single Bilibili login session (cookie name -> value) in the
/// platform secure storage instead of a plain-text file.
///
/// Values are never logged. Callers must only pass cookies that have already
/// been confirmed by the nav endpoint, except for the one-time migration of
/// the legacy file which preserves whatever the user already had.
class BilibiliCookieStore {
  BilibiliCookieStore({
    BilibiliSecretStorage? storage,
    Future<Directory> Function()? dataDirectory,
    Duration operationTimeout = const Duration(seconds: 8),
  }) : _storage = storage ?? PlatformBilibiliSecretStorage(),
       _dataDirectory = dataDirectory ?? resolveAppDataDirectory,
       _timeout = operationTimeout;

  static const String storageKey = 'bilibili_session_cookies_v1';

  /// Legacy `PersistCookieJar(FileStorage(...))` folder name.
  static const String legacyFolderName = '.bilibili_cookies';

  /// Login and browser identity cookies kept together after verification.
  /// Discarding the browser identity breaks video write validation.
  static const Set<String> sessionCookieNames = <String>{
    'SESSDATA',
    'bili_jct',
    'DedeUserID',
    'DedeUserID__ckMd5',
    'sid',
    'buvid3',
    'buvid4',
    'b_nut',
    '_uuid',
    'buvid_fp',
    'buvid_fp_plain',
    'b_lsid',
    'bili_ticket',
    'bili_ticket_expires',
    'fingerprint',
  };

  final BilibiliSecretStorage _storage;
  final Future<Directory> Function() _dataDirectory;
  final Duration _timeout;

  /// Reads the stored session. Throws when secure storage is unavailable so
  /// callers can tell "no login" apart from "cannot read right now".
  Future<Map<String, String>> readCookies() async {
    final raw = await _storage.read(storageKey).timeout(_timeout);
    return decode(raw);
  }

  /// Replaces the stored session and reads it back to make sure the write
  /// really landed.
  Future<void> replaceCookies(Map<String, String> cookies) async {
    final filtered = filterSessionCookies(cookies);
    if ((filtered['SESSDATA'] ?? '').isEmpty) {
      throw ArgumentError('Refusing to store a session without SESSDATA.');
    }
    final encoded = jsonEncode(filtered);
    await _storage.write(storageKey, encoded).timeout(_timeout);
    final readBack = await _storage.read(storageKey).timeout(_timeout);
    if (readBack != encoded) {
      throw StateError('Secure storage read-back mismatch.');
    }
  }

  Future<void> clear() => _storage.delete(storageKey).timeout(_timeout);

  /// Moves the legacy plain-text cookie folder into secure storage.
  ///
  /// The legacy folder is only deleted after the secure copy has been
  /// written and read back. Any failure keeps the folder for a later retry.
  Future<BilibiliLegacyCookieMigrationResult> migrateLegacyIfPresent() async {
    final Directory baseDir;
    try {
      baseDir = await _dataDirectory();
    } catch (error) {
      developer.log(
        'Bilibili cookie migration: no data directory',
        error: error,
      );
      return const BilibiliLegacyCookieMigrationResult(
        BilibiliLegacyCookieMigration.none,
      );
    }
    final legacyPath =
        '${baseDir.path}${Platform.pathSeparator}$legacyFolderName';
    final type = FileSystemEntity.typeSync(legacyPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const BilibiliLegacyCookieMigrationResult(
        BilibiliLegacyCookieMigration.none,
      );
    }

    Map<String, String> legacy;
    try {
      legacy = type == FileSystemEntityType.directory
          ? await _readLegacyJar(legacyPath)
          : const <String, String>{};
    } catch (error) {
      developer.log(
        'Bilibili cookie migration: legacy cookies unreadable, keeping them',
        error: error.runtimeType,
      );
      return const BilibiliLegacyCookieMigrationResult(
        BilibiliLegacyCookieMigration.failedKeptLegacy,
      );
    }

    final hasSession = (legacy['SESSDATA'] ?? '').isNotEmpty;
    if (hasSession) {
      try {
        final existing = await readCookies();
        // A session already in secure storage is newer (a previous migration
        // succeeded but deleting the folder failed, or the user re-logged in).
        if ((existing['SESSDATA'] ?? '').isEmpty) {
          await replaceCookies(legacy);
        }
      } catch (error) {
        developer.log(
          'Bilibili cookie migration: secure storage unavailable, keeping legacy cookies',
          error: error.runtimeType,
        );
        return BilibiliLegacyCookieMigrationResult(
          BilibiliLegacyCookieMigration.failedKeptLegacy,
          legacy,
        );
      }
    }

    try {
      await _deleteLegacy(legacyPath, type);
    } catch (error) {
      // The secure copy exists; the next start retries deleting the folder.
      developer.log(
        'Bilibili cookie migration: could not delete legacy cookie folder',
        error: error.runtimeType,
      );
    }
    developer.log(
      hasSession
          ? 'Bilibili cookie migration: moved login into secure storage'
          : 'Bilibili cookie migration: removed empty legacy cookie folder',
    );
    return BilibiliLegacyCookieMigrationResult(
      hasSession
          ? BilibiliLegacyCookieMigration.migrated
          : BilibiliLegacyCookieMigration.discardedEmpty,
    );
  }

  Future<Map<String, String>> _readLegacyJar(String legacyPath) async {
    // Same options the old code used: PersistCookieJar defaults.
    final jar = PersistCookieJar(storage: FileStorage(legacyPath));
    final merged = <String, String>{};
    for (final url in const <String>[
      'https://api.bilibili.com',
      'https://www.bilibili.com',
      'https://passport.bilibili.com',
    ]) {
      final cookies = await jar.loadForRequest(Uri.parse(url));
      for (final cookie in cookies) {
        if (cookie.value.isEmpty) continue;
        merged.putIfAbsent(cookie.name, () => cookie.value);
      }
    }
    return filterSessionCookies(merged);
  }

  Future<void> _deleteLegacy(String path, FileSystemEntityType type) async {
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  }

  static Map<String, String> filterSessionCookies(Map<String, String> input) {
    final out = <String, String>{};
    input.forEach((name, value) {
      final v = value.trim();
      if (sessionCookieNames.contains(name) && v.isNotEmpty) out[name] = v;
    });
    return out;
  }

  static Map<String, String> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      decoded.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          out[key] = value;
        }
      });
      return out;
    } on FormatException {
      return <String, String>{};
    }
  }
}

/// Parses user input from the manual login box. Accepts either a bare
/// SESSDATA value or a `name=value; name2=value2` cookie header.
Map<String, String> parseBilibiliCookieInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return <String, String>{};
  if (!text.contains('=')) {
    return <String, String>{'SESSDATA': text};
  }
  final out = <String, String>{};
  for (final part in text.split(';')) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    final name = part.substring(0, index).trim();
    final value = part.substring(index + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    out[name] = value;
  }
  return out;
}

/// Builds a `Cookie` request header. The result contains secrets and must
/// never be logged.
String buildBilibiliCookieHeader(Map<String, String> cookies) =>
    cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
