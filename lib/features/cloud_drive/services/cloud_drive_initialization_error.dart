import 'dart:io';

import 'package:flutter/services.dart';

import '../../../services/app_storage_service.dart';
import '../models/cloud_drive_models.dart';

String cloudDriveInitializationMessage(Object error) {
  if (error is StorageUnavailableException) return error.message;
  if (error is CloudDriveFailure) return error.message;
  if (error is FileSystemException) {
    return '无法读取网盘账号记录。请确认数据磁盘已连接、目录可读写，然后重试。';
  }
  if (error is FormatException) {
    return '网盘账号记录无法解析，原记录已保留。请恢复账号记录备份后重试。';
  }
  if (error is PlatformException || error is MissingPluginException) {
    return '系统凭据服务不可用。Linux 请启动桌面密钥环和用户 D-Bus 会话后重试。';
  }
  return '网盘初始化失败。请重试；若仍失败，可在诊断日志中查看原因。';
}
