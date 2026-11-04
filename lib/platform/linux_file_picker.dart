import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Uses the runner's GTK chooser, including on desktops without a portal bus.
/// Register once after the generated Dart plugin registrant has run.
class LinuxFilePicker extends FilePicker {
  LinuxFilePicker({
    MethodChannel channel = const MethodChannel(
      'io.github.t66666t.FluentPlayer/files',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  bool _open = false;

  static void install() {
    if (Platform.isLinux) FilePicker.platform = LinuxFilePicker();
  }

  Future<List<String>> _choose(
    String action, {
    String? title,
    String? directory,
    String? name,
    List<String>? extensions,
    bool multiple = false,
  }) async {
    if (_open) throw StateError('已有一个文件选择窗口，请先完成该窗口中的操作');
    _open = true;
    try {
      return await _channel.invokeListMethod<String>('choose', {
            'action': action,
            'title': title,
            'directory': directory,
            'name': name,
            'extensions': extensions,
            'multiple': multiple,
          }) ??
          const [];
    } finally {
      _open = false;
    }
  }

  List<String>? _extensions(FileType type, List<String>? custom) =>
      switch (type) {
        FileType.any => null,
        FileType.custom => custom,
        FileType.image => [
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'bmp',
          'heic',
          'avif',
        ],
        FileType.audio => [
          'mp3',
          'm4a',
          'flac',
          'wav',
          'ogg',
          'opus',
          'aac',
          'alac',
        ],
        FileType.video => [
          'mp4',
          'mkv',
          'mov',
          'webm',
          'avi',
          'm4v',
          'ts',
          'mpeg',
        ],
        FileType.media => [
          'mp4',
          'mkv',
          'mov',
          'webm',
          'avi',
          'mp3',
          'm4a',
          'flac',
          'wav',
          'ogg',
        ],
      };

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    int compressionQuality = 0,
  }) async {
    final paths = await _choose(
      'open',
      title: dialogTitle,
      directory: initialDirectory,
      extensions: _extensions(type, allowedExtensions),
      multiple: allowMultiple,
    );
    if (paths.isEmpty) return null;
    final files = <PlatformFile>[];
    onFileLoading?.call(FilePickerStatus.picking);
    try {
      for (final path in paths) {
        final file = File(path);
        files.add(
          PlatformFile(
            path: path,
            name: p.basename(path),
            size: await file.length(),
            bytes: withData ? await file.readAsBytes() : null,
            readStream: withReadStream ? file.openRead() : null,
          ),
        );
      }
      return FilePickerResult(files);
    } finally {
      onFileLoading?.call(FilePickerStatus.done);
    }
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    final paths = await _choose(
      'directory',
      title: dialogTitle,
      directory: initialDirectory,
    );
    return paths.firstOrNull;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    final paths = await _choose(
      'save',
      title: dialogTitle,
      directory: initialDirectory,
      name: fileName,
      extensions: _extensions(type, allowedExtensions),
    );
    final path = paths.firstOrNull;
    if (path != null && bytes != null) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return path;
  }
}
