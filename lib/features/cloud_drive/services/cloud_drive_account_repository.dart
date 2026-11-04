import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../auth/cloud_drive_credential_store.dart';
import '../models/cloud_drive_models.dart';

/// Account names and credential key names. Cookie values never enter this file.
abstract class CloudDriveAccountMetadataStore {
  Future<String?> read();
  Future<void> write(String value);
}

class MemoryCloudDriveAccountMetadataStore
    implements CloudDriveAccountMetadataStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

/// Login and logout. Subtitle caches listen without sharing tokens.
class CloudDriveSessionSignal extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Owns account identity and which secret key belongs to it.
///
/// Re-login of the same remote account replaces credentials in place.
/// A cancelled login never calls [commitVerified], so the previous jar stays.
class CloudDriveAccountRepository {
  CloudDriveAccountRepository({
    required CloudDriveCredentialStore credentials,
    required CloudDriveAccountMetadataStore metadata,
    Uuid? uuid,
  }) : _credentials = credentials,
       _metadata = metadata,
       _uuid = uuid ?? const Uuid();

  final CloudDriveCredentialStore _credentials;
  final CloudDriveAccountMetadataStore _metadata;
  final Uuid _uuid;
  final List<CloudDriveAccount> _accounts = [];
  var _loaded = false;
  Future<void> _credentialWrites = Future.value();

  /// Bumps when a login is saved or cleared. Subtitle caches listen to this
  /// instead of sharing one token across accounts.
  final CloudDriveSessionSignal sessionChanges = CloudDriveSessionSignal();
  int sessionGeneration = 0;

  List<CloudDriveAccount> get accounts => List.unmodifiable(_accounts);

  Future<void> load() async {
    if (_loaded) return;
    final raw = await _metadata.read();
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final item in decoded.whereType<Map>()) {
          final account = CloudDriveAccount.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (account.localId.isEmpty || account.remoteAccountId.isEmpty) {
            continue;
          }
          _accounts.add(account);
        }
      }
    }
    _loaded = true;
  }

  CloudDriveAccount? findRemote(String providerId, String remoteAccountId) {
    for (final account in _accounts) {
      if (account.providerId == providerId &&
          account.remoteAccountId == remoteAccountId) {
        return account;
      }
    }
    return null;
  }

  CloudDriveAccount? findLocal(String localId) {
    for (final account in _accounts) {
      if (account.localId == localId) return account;
    }
    return null;
  }

  Future<CloudDriveCredential?> credentialFor(CloudDriveAccount account) {
    final current = findLocal(account.localId);
    if (current == null ||
        current.authState == CloudDriveAuthState.needsLogin) {
      return Future.value();
    }
    if (!current.credentialPersisted) {
      return Future.value(_credentials.ephemeralFor(current.credentialKey));
    }
    return _credentials.read(current.credentialKey);
  }

  /// Atomically replaces the matching remote account, or adds a new one.
  Future<CloudDriveAccount> commitVerified({
    required String providerId,
    required String remoteAccountId,
    required String displayName,
    String? avatar,
    required CloudDriveCredential credential,
    String driveId = '0',
  }) => _serialize(() async {
    await load();
    final existing = findRemote(providerId, remoteAccountId);
    final localId = existing?.localId ?? _uuid.v4();
    final key = existing?.credentialKey ?? 'cloud_drive_cred_v1_$localId';
    final persisted = await _credentials.write(key, credential);
    final account = CloudDriveAccount(
      localId: localId,
      providerId: providerId,
      remoteAccountId: remoteAccountId,
      displayName: displayName,
      avatar: avatar,
      credentialKey: key,
      authState: persisted
          ? CloudDriveAuthState.signedIn
          : CloudDriveAuthState.temporarySession,
      lastVerifiedAt: DateTime.now().toUtc(),
      credentialPersisted: persisted,
      driveId: driveId,
    );
    final index = _accounts.indexWhere((item) => item.localId == localId);
    if (index >= 0) {
      _accounts[index] = account;
    } else {
      _accounts.add(account);
    }
    await _persistMetadata();
    _noteSessionChanged();
    return account;
  });

  Future<T> _serialize<T>(Future<T> Function() work) {
    final result = _credentialWrites.then((_) => work());
    _credentialWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Persist rotated tokens only while the source login is still current.
  /// Serializing also prevents a delayed refresh from overwriting a new login.
  Future<void> refreshCredential(
    CloudDriveCredential previous,
    CloudDriveCredential next,
  ) {
    return _serialize(() async {
      final stamp = cloudDriveCredentialStamp(previous);
      for (final account in List<CloudDriveAccount>.of(_accounts)) {
        final current = await credentialFor(account);
        if (current == null || cloudDriveCredentialStamp(current) != stamp) {
          continue;
        }
        if (findLocal(account.localId)?.authState ==
            CloudDriveAuthState.needsLogin) {
          continue;
        }
        final persisted = await _credentials.write(account.credentialKey, next);
        final index = _accounts.indexWhere((a) => a.localId == account.localId);
        if (index < 0) {
          await _credentials.delete(account.credentialKey);
          continue;
        }
        if (_accounts[index].credentialPersisted != persisted) {
          _accounts[index] = _accounts[index].copyWith(
            credentialPersisted: persisted,
            authState: persisted
                ? CloudDriveAuthState.signedIn
                : CloudDriveAuthState.temporarySession,
          );
          await _persistMetadata();
        }
      }
    });
  }

  /// Clears the secret but keeps the account row so the same files stay linked.
  Future<void> signOut(String localId) => _serialize(() async {
    await load();
    final index = _accounts.indexWhere((item) => item.localId == localId);
    if (index < 0) return;
    final account = _accounts[index];
    _accounts[index] = account.copyWith(
      authState: CloudDriveAuthState.needsLogin,
      credentialPersisted: false,
    );
    await _persistMetadata();
    _noteSessionChanged();
    await _credentials.delete(account.credentialKey);
  });

  /// Drops the session and this account's secret. Watch history stays.
  Future<void> remove(String localId) => _serialize(() async {
    await load();
    final index = _accounts.indexWhere((item) => item.localId == localId);
    if (index < 0) return;
    final account = _accounts.removeAt(index);
    await _persistMetadata();
    _noteSessionChanged();
    await _credentials.delete(account.credentialKey);
  });

  void _noteSessionChanged() {
    sessionGeneration++;
    sessionChanges.changed();
  }

  Future<void> _persistMetadata() async {
    final encoded = jsonEncode(
      _accounts.map((account) => account.toJson()).toList(),
    );
    await _metadata.write(encoded);
  }
}
