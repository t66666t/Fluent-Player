import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_credential_store.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_account_repository.dart';

class MemorySecret implements CloudDriveSecretStorage {
  final Map<String, String> values = {};
  var fail = false;
  var failDelete = false;

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('keychain deletion failed');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('keychain down');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('keychain down');
    values[key] = value;
  }
}

CloudDriveCredential jar(String token) => CloudDriveCredential(
  cookies: [
    CloudDriveCookie(name: 'BDUSS', value: token, domain: '.baidu.com'),
  ],
);

void main() {
  test(
    'failed keychain deletion stays signed out across repository reloads',
    () async {
      final secrets = MemorySecret();
      final metadata = MemoryCloudDriveAccountMetadataStore();
      final credentials = CloudDriveCredentialStore(storage: secrets);
      final repo = CloudDriveAccountRepository(
        credentials: credentials,
        metadata: metadata,
      );
      final account = await repo.commitVerified(
        providerId: 'baidu',
        remoteAccountId: 'uk',
        displayName: 'test',
        credential: jar('fake-session'),
      );
      secrets.failDelete = true;
      await expectLater(
        repo.signOut(account.localId),
        throwsA(isA<CloudDriveSecureStorageException>()),
      );
      expect(await credentials.read(account.credentialKey), isNull);
      expect(await repo.credentialFor(account), isNull);
      final restored = CloudDriveAccountRepository(
        credentials: CloudDriveCredentialStore(storage: secrets),
        metadata: metadata,
      );
      await restored.load();
      expect(await restored.credentialFor(restored.accounts.single), isNull);
      secrets.failDelete = false;
      final relogged = await repo.commitVerified(
        providerId: 'baidu',
        remoteAccountId: 'uk',
        displayName: 'test',
        credential: jar('replacement'),
      );
      expect(
        (await repo.credentialFor(relogged))!.cookies.single.value,
        'replacement',
      );
    },
  );
  test('relogin updates the same remote account', () async {
    final secrets = MemorySecret();
    final repo = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: secrets),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    final first = await repo.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      displayName: '甲',
      credential: jar('old'),
    );
    final second = await repo.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      displayName: '甲二',
      credential: jar('new'),
    );
    expect(repo.accounts, hasLength(1));
    expect(second.localId, first.localId);
    expect(
      (await repo.credentialFor(
        second,
      ))!.headerFor(Uri.https('pan.baidu.com', '/')),
      contains('new'),
    );
    expect(repo.metadataSnapshot(), isNot(contains('old')));
  });

  test('cancelled login does not replace the saved account', () async {
    final repo = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: MemorySecret()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    await repo.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      displayName: '甲',
      credential: jar('keep'),
    );
    expect(repo.accounts.single.displayName, '甲');
    expect(
      (await repo.credentialFor(repo.accounts.single))!.cookies.single.value,
      'keep',
    );
  });

  test('two accounts do not share cookies', () async {
    final repo = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: MemorySecret()),
      metadata: MemoryCloudDriveAccountMetadataStore(),
    );
    final a = await repo.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk-a',
      displayName: 'A',
      credential: jar('cookie-a'),
    );
    final b = await repo.commitVerified(
      providerId: 'baidu',
      remoteAccountId: 'uk-b',
      displayName: 'B',
      credential: jar('cookie-b'),
    );
    expect((await repo.credentialFor(a))!.cookies.single.value, 'cookie-a');
    expect((await repo.credentialFor(b))!.cookies.single.value, 'cookie-b');
  });

  test('a temporary replacement never reloads the old saved credential', () async {
    final secrets = MemorySecret();
    final metadata = MemoryCloudDriveAccountMetadataStore();
    final repo = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: secrets),
      metadata: metadata,
    );
    await repo.commitVerified(providerId: 'baidu', remoteAccountId: 'uk-1',
      displayName: 'A', credential: jar('old'));
    secrets.fail = true;
    final temporary = await repo.commitVerified(providerId: 'baidu', remoteAccountId: 'uk-1',
      displayName: 'A', credential: jar('new'));
    expect((await repo.credentialFor(temporary))!.cookies.single.value, 'new');
    secrets.fail = false;
    final restored = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: secrets), metadata: metadata,
    );
    await restored.load();
    expect(restored.accounts.single.credentialPersisted, isFalse);
    expect(await restored.credentialFor(restored.accounts.single), isNull);
  });

  test('secure storage failure does not write plaintext', () async {
    final secrets = MemorySecret()..fail = true;
    final metadata = MemoryCloudDriveAccountMetadataStore();
    final repo = CloudDriveAccountRepository(
      credentials: CloudDriveCredentialStore(storage: secrets),
      metadata: metadata,
    );
    final account = await repo.commitVerified(
      providerId: 'quark',
      remoteAccountId: 'uid-1',
      displayName: '临时',
      credential: CloudDriveCredential(
        cookies: [
          CloudDriveCookie(
            name: '__puus',
            value: 'secret',
            domain: '.quark.cn',
          ),
        ],
      ),
    );
    expect(account.credentialPersisted, isFalse);
    expect(account.authState, CloudDriveAuthState.temporarySession);
    expect(secrets.values, isEmpty);
    expect(metadata.value, isNot(contains('secret')));
  });
}

extension on CloudDriveAccountRepository {
  String metadataSnapshot() =>
      accounts.map((account) => account.toJson()).join();
}
