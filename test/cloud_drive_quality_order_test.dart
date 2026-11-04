import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_quality_order.dart';

CloudDriveQualityChoice _quality(String id, String label) =>
    CloudDriveQualityChoice(
      id: id,
      label: label,
      transcoded: id != 'original',
      complete: true,
    );

void main() {
  test('original leads and actual pixels outrank provider tier names', () {
    final input = [
      _quality('low', '270P 转码'),
      _quality('high', '540P 转码'),
      _quality('normal', '720P 转码'),
      _quality('original', '原画'),
      _quality('4k', '4K 转码'),
    ];
    expect(sortCloudDriveQualities(input).map((q) => q.id), [
      'original',
      '4k',
      'normal',
      'high',
      'low',
    ]);
    expect(input.first.id, 'low');
  });

  test(
    'newly discovered higher qualities precede existing lower qualities',
    () {
      final current = [_quality('original', '原画'), _quality('low', '270P')];
      final discovered = [_quality('HD', '720P'), _quality('FHD', '1080P')];
      expect(
        sortCloudDriveQualities([...current, ...discovered]).map((q) => q.id),
        ['original', 'FHD', 'HD', 'low'],
      );
    },
  );

  test(
    'equal resolutions keep their source order and unknown tiers stay last',
    () {
      expect(
        sortCloudDriveQualities([
          _quality('a', '720P HEVC'),
          _quality('unknown', '其他'),
          _quality('b', '720P AVC'),
          _quality('super', '超清'),
        ]).map((q) => q.id),
        ['super', 'a', 'b', 'unknown'],
      );
    },
  );
}
