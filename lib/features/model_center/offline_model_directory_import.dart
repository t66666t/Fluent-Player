import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'model_catalog.dart';

/// One fixed installed filename and the finite source layouts already accepted
/// by the corresponding model manager. No directory-wide scan is requested.
class OfflineModelImportFile {
  OfflineModelImportFile({
    required this.targetPath,
    required Iterable<String> relativePaths,
    required this.expectedBytes,
  }) : relativePaths = List.unmodifiable(relativePaths);

  final String targetPath;
  final List<String> relativePaths;
  final int expectedBytes;

  static List<OfflineModelImportFile> forArtifact(
    ModelArtifact artifact, {
    String? componentDirectory,
  }) => [
    for (final file in artifact.files)
      OfflineModelImportFile(
        targetPath: componentDirectory == null
            ? file.name
            : '$componentDirectory/${file.name}',
        relativePaths: [
          if (componentDirectory != null) '$componentDirectory/${file.name}',
          file.name,
        ],
        expectedBytes: file.bytes,
      ),
  ];

  Map<String, Object> toMessage() => {
    'targetPath': targetPath,
    'relativePaths': relativePaths,
    'expectedBytes': expectedBytes,
  };
}

/// Android SAF trees are materialized by the host into a token-owned cache.
/// Other platforms keep their existing local directory picker and source path.
class OfflineModelDirectoryImporter {
  OfflineModelDirectoryImporter({
    bool? isAndroid,
    MethodChannel channel = const MethodChannel(
      'com.example.video_player_app/model_directory_import',
    ),
    Future<String?> Function(String title)? pickLocalDirectory,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _channel = channel,
       _pickLocalDirectory =
           pickLocalDirectory ??
           ((title) =>
               FilePicker.platform.getDirectoryPath(dialogTitle: title));

  final bool _isAndroid;
  final MethodChannel _channel;
  final Future<String?> Function(String title) _pickLocalDirectory;

  Future<bool> importFiles({
    required String dialogTitle,
    required List<OfflineModelImportFile> files,
    required Future<void> Function(Directory directory) install,
  }) async {
    _validate(files);
    if (!_isAndroid) {
      final path = await _pickLocalDirectory(dialogTitle);
      if (path == null) {
        return false;
      }
      await install(Directory(path));
      return true;
    }

    final result = await _channel.invokeMapMethod<String, dynamic>(
      'selectAndStage',
      {
        'files': [for (final file in files) file.toMessage()],
      },
    );
    if (result == null) {
      return false;
    }
    final token = result['token'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('模型目录导入未返回有效的临时文件凭据');
    }
    Object? installationError;
    try {
      final path = result['directoryPath'];
      if (path is! String ||
          path.isEmpty ||
          Uri.tryParse(path)?.scheme == 'content') {
        throw const FormatException('模型目录导入未返回可读取的临时目录');
      }
      await install(Directory(path));
      return true;
    } catch (error) {
      installationError = error;
      rethrow;
    } finally {
      try {
        await _channel.invokeMethod<void>('cleanup', {'token': token});
      } catch (error) {
        if (installationError == null) {
          rethrow;
        }
        // Preserve the actionable installation error; the host owns cache-only
        // cleanup and never receives a source directory to remove.
        debugPrint('模型导入临时目录清理失败：$error');
      }
    }
  }

  static void _validate(List<OfflineModelImportFile> files) {
    final targets = <String>{};
    var candidates = 0;
    for (final file in files) {
      candidates += file.relativePaths.length;
      if (!_safeRelativePath(file.targetPath) ||
          !targets.add(file.targetPath) ||
          file.expectedBytes <= 0 ||
          file.relativePaths.isEmpty ||
          file.relativePaths.length > 32 ||
          file.relativePaths.any((path) => !_safeRelativePath(path))) {
        throw const FormatException('模型导入文件清单无效');
      }
    }
    if (files.isEmpty || files.length > 128 || candidates > 128) {
      throw const FormatException('模型导入文件清单超出范围');
    }
  }

  static bool _safeRelativePath(String path) =>
      path.isNotEmpty &&
      !RegExp(r'[:\\\x00-\x1f\x7f]').hasMatch(path) &&
      path
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');
}
