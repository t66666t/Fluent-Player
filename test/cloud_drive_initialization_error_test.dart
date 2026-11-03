import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_initialization_error.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/services/app_storage_service.dart';

void main() {
  test(
    'cloud drive errors describe a recovery action without exposing private details',
    () {
      expect(
        cloudDriveInitializationMessage(
          const FileSystemException('secret account data'),
        ),
        contains('数据磁盘'),
      );
      expect(
        cloudDriveInitializationMessage(
          const FormatException('private cookies'),
        ),
        contains('恢复账号记录备份'),
      );
      expect(
        cloudDriveInitializationMessage(
          PlatformException(code: 'secret-service-unavailable'),
        ),
        contains('密钥环'),
      );
      expect(
        cloudDriveInitializationMessage(
          const CloudDriveFailure(
            CloudDriveFailureKind.unavailable,
            '网盘播放服务尚未初始化',
          ),
        ),
        '网盘播放服务尚未初始化',
      );
      expect(
        cloudDriveInitializationMessage(
          const StorageUnavailableException('数据目录正在迁移'),
        ),
        '数据目录正在迁移',
      );
      expect(
        cloudDriveInitializationMessage(StateError('cookies=private-token')),
        isNot(contains('private-token')),
      );
    },
  );
}
