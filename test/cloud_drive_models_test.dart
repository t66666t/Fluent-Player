import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';

void main() {
  test('old media source json still loads', () {
    final parsed = MediaSourceRef.fromJson({
      'value': 'BV1xx',
      'kind': 'bilibiliBv',
      'bvid': 'BV1xx',
      'unknown': 'kept-out',
    });
    expect(parsed.kind, MediaSourceKind.bilibiliBv);
    expect(parsed.bvid, 'BV1xx');
    expect(parsed.cloudDrive, isNull);
  });

  test('cloud source json has no cookie or temporary url', () {
    const cloud = CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      driveId: '0',
      fileId: '99',
      pathHint: '/电影/测试 文件.mp4',
    );
    final source = MediaSourceRef(
      value: cloud.sourceKey,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: cloud,
    );
    final json = source.toJson().toString();
    expect(json.contains('BDUSS'), isFalse);
    expect(json.contains('http'), isFalse);
    final again = MediaSourceRef.fromJson(source.toJson());
    expect(again.cloudDrive?.sourceKey, cloud.sourceKey);
    expect(again.cloudDrive?.logicalUri, startsWith('cloud-drive://'));
  });

  test('same file keeps the same source key after another login', () {
    final first = cloudDriveSourceKey(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      driveId: '0',
      fileId: 'file-a',
    );
    final second = cloudDriveSourceKey(
      providerId: 'baidu',
      remoteAccountId: 'uk-1',
      driveId: '0',
      fileId: 'file-a',
    );
    final otherAccount = cloudDriveSourceKey(
      providerId: 'baidu',
      remoteAccountId: 'uk-2',
      driveId: '0',
      fileId: 'file-a',
    );
    expect(second, first);
    expect(otherAccount, isNot(first));
    expect(cloudDriveItemId(first), cloudDriveItemId(second));
  });
}
