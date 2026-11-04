import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/cloud_drive_models.dart';

/// Key/value secret storage. Tests replace the OS keychain with memory.
abstract interface class CloudDriveSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformCloudDriveSecretStorage implements CloudDriveSecretStorage {
  PlatformCloudDriveSecretStorage({FlutterSecureStorage? storage})
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

class CloudDriveSecureStorageException implements Exception {
  const CloudDriveSecureStorageException();
}

/// Stores cookie jars outside SharedPreferences. A failed write stays in
/// memory for this process and is never copied into a plain-text file.
class CloudDriveCredentialStore {
  CloudDriveCredentialStore({
    CloudDriveSecretStorage? storage,
    Duration timeout = const Duration(seconds: 8),
  }) : _storage = storage ?? PlatformCloudDriveSecretStorage(),
       _timeout = timeout;

  final CloudDriveSecretStorage _storage;
  final Duration _timeout;
  final Map<String, CloudDriveCredential> _ephemeral = {};
  final Set<String> _deleted = {};

  Future<CloudDriveCredential?> read(String key) async {
    if (_deleted.contains(key)) return null;
    final memory = _ephemeral[key];
    if (memory != null) return memory;
    try {
      final raw = await _storage.read(key).timeout(_timeout);
      return CloudDriveCredential.tryParse(raw);
    } on TimeoutException {
      throw const CloudDriveSecureStorageException();
    } catch (_) {
      throw const CloudDriveSecureStorageException();
    }
  }

  /// Returns false when the jar is only kept for this process.
  Future<bool> write(String key, CloudDriveCredential credential) async {
    final encoded = jsonEncode(credential.toJson());
    try {
      await _storage.write(key, encoded).timeout(_timeout);
      final readBack = await _storage.read(key).timeout(_timeout);
      if (readBack != encoded) {
        throw const CloudDriveSecureStorageException();
      }
      _ephemeral.remove(key);
      _deleted.remove(key);
      return true;
    } catch (_) {
      _ephemeral[key] = credential;
      _deleted.remove(key);
      return false;
    }
  }

  Future<void> delete(String key) async {
    _ephemeral.remove(key);
    _deleted.add(key);
    try {
      await _storage.delete(key).timeout(_timeout);
    } catch (_) {
      // Keep this process revoked even if the OS credential store is locked.
      throw const CloudDriveSecureStorageException();
    }
  }

  bool get hasEphemeralSessions => _ephemeral.isNotEmpty;

  CloudDriveCredential? ephemeralFor(String key) => _ephemeral[key];
}
