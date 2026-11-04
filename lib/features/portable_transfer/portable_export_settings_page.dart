import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/library_service.dart';
import '../../utils/app_toast.dart';
import '../../utils/select_all_on_acquire.dart';
import 'portable_export_format_page.dart';
import 'portable_export_cache_dialog.dart';
import 'portable_export_readiness.dart';
import 'portable_export_settings_memory.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_service.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class PortableExportSettingsPage extends StatefulWidget {
  const PortableExportSettingsPage({
    super.key,
    required this.library,
    required this.rootIds,
    required this.format,
    required this.mediaCount,
    required this.folderCount,
  });

  final LibraryService library;
  final List<String> rootIds;
  final PortableExportFormatChoice format;
  final int mediaCount;
  final int folderCount;

  @override
  State<PortableExportSettingsPage> createState() =>
      _PortableExportSettingsPageState();
}

class _PortableExportSettingsPageState
    extends State<PortableExportSettingsPage> {
  late final TextEditingController _nameController;
  late final FocusNode _nameFocus;
  var _wrap = true;
  var _sidecars = true;
  var _checksums = true;
  var _includeDanmaku = true;
  var _embedSubtitles = true;
  var _externalSubtitles = false;
  var _starting = false;
  var _settingsReady = false;
  PortableCompression _compression = PortableCompression.fast;
  // Writes stay ordered so a slower older choice cannot overwrite a newer one.
  Future<void> _rememberQueue = Future<void>.value();

  bool get _zip => widget.format == PortableExportFormatChoice.zip;

  PortableExportFormat get _exportFormat =>
      _zip ? PortableExportFormat.zip : PortableExportFormat.fluentPack;

  @override
  void initState() {
    super.initState();
    // The package name stays time-based so two exports do not share a file name.
    // Switches and compression are restored per format below.
    _nameController = TextEditingController(
      text:
          'Fluent Player ${DateFormat('yyyy-MM-dd HH-mm').format(DateTime.now())}',
    );
    _nameFocus = FocusNode();
    _restoreRememberedSettings();
  }

  Future<void> _restoreRememberedSettings() async {
    final remembered = await PortableExportSettingsMemory.load(_exportFormat);
    if (!mounted) return;
    setState(() {
      _compression = remembered.compression;
      _wrap = remembered.wrapInFolder;
      _sidecars = remembered.includeSidecars;
      _checksums = remembered.verifyChecksums;
      _embedSubtitles = remembered.zipEmbedSubtitles;
      _externalSubtitles = remembered.zipExternalSubtitles;
      _includeDanmaku = remembered.includeDanmaku;
      _settingsReady = true;
    });
  }

  PortableExportRememberedSettings _rememberedSnapshot() {
    return PortableExportRememberedSettings(
      compression: _compression,
      wrapInFolder: _wrap,
      includeSidecars: _sidecars,
      verifyChecksums: _checksums,
      zipEmbedSubtitles: _embedSubtitles,
      zipExternalSubtitles: _externalSubtitles,
      includeDanmaku: _includeDanmaku,
      includeBilibiliCache: false,
    );
  }

  void _rememberCurrentSettings() {
    final snapshot = _rememberedSnapshot();
    final format = _exportFormat;
    _rememberQueue = _rememberQueue.then(
      (_) => PortableExportSettingsMemory.save(format, snapshot),
    );
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    final packageName = _nameController.text.trim();
    if (packageName.isEmpty) return;
    _rememberCurrentSettings();
    setState(() => _starting = true);
    try {
      await _rememberQueue;
    } catch (_) {
      // A failed preference write must not block the export itself.
    }
    try {
      final missing = await uncachedCloudExportItems(
        widget.library,
        widget.rootIds,
      );
      if (!mounted) return;
      if (missing.isNotEmpty) {
        final ready = await showDialog<bool>(
          context: context,
          builder: (_) => PortableExportCacheDialog(
            library: widget.library,
            rootIds: widget.rootIds,
            missing: missing,
          ),
        );
        if (ready != true || !mounted) return;
      }
      final extension = _zip ? 'zip' : PortableTransferService.extension;
      final outputPath = await _chooseOutputPath(
        fileName: '${_safeFileName(packageName)}.$extension',
        extension: extension,
        zip: _zip,
      );
      if (outputPath == null || !mounted) return;
      await PortableTransferService.instance.exportSelection(
        library: widget.library,
        rootIds: widget.rootIds,
        outputPath: outputPath,
        options: PortableExportOptions(
          packageName: packageName,
          wrapInFolder: _zip ? false : _wrap,
          includeSidecars: _zip ? false : _sidecars,
          verifyChecksums: _zip ? false : _checksums,
          compression: _compression,
          format: _zip
              ? PortableExportFormat.zip
              : PortableExportFormat.fluentPack,
          zipEmbedSubtitles: _embedSubtitles,
          zipExternalSubtitles: _externalSubtitles,
          includeDanmaku: _includeDanmaku,
          includeBilibiliCache: false,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      AppToast.show('无法开始导出：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inheritedTheme = Theme.of(context);
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return PortableExportEscapeScope(
      child: Theme(
        data: inheritedTheme.copyWith(
          textTheme: inheritedTheme.textTheme.apply(fontFamily: 'Noto Sans SC'),
          primaryTextTheme: inheritedTheme.primaryTextTheme.apply(
            fontFamily: 'Noto Sans SC',
          ),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          appBar: AppBar(title: Text(_zip ? 'Zip 导出设置' : 'Fluent Pack 导出设置')),
          body: SafeArea(
            top: false,
            child: _settingsReady
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    children: [
                      Text(
                        _summary(widget.mediaCount, widget.folderCount),
                        style: const TextStyle(
                          color: Colors.white54,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _note(
                        icon: _zip
                            ? Icons.folder_zip_outlined
                            : Icons.cloud_done_outlined,
                        text: _zip
                            ? '本地媒体按卡片标题命名，重名自动加序号。字幕与本地弹幕文件可以内嵌；无法内嵌时保留外挂文件并在任务中说明。封面和章节按需写入，不重新编码视频，需要预留约等于媒体大小的临时空间。'
                            : '将本地媒体随包携带到另一台设备，保留文件夹、字幕、笔记与播放信息。开启附属文件可原样保留本地字幕、弹幕和预览图。缺失的媒体需要先重新定位或导入本地文件。',
                      ),
                      if (mobile) ...[
                        const SizedBox(height: 10),
                        _note(
                          icon: Icons.mobile_friendly_rounded,
                          color: const Color(0xFF70D8A4),
                          text:
                              '移动端会流式生成文件，避免大文件撑爆内存。完成后可在任务卡片中分享、存储到“文件”或用其他应用打开。',
                        ),
                      ],
                      const SizedBox(height: 20),
                      SelectAllOnAcquire(
                        controller: _nameController,
                        focusNode: _nameFocus,
                        builder: (context, onTap) => TextField(
                          controller: _nameController,
                          focusNode: _nameFocus,
                          // The suggested title is selected on entry so typing
                          // replaces it. A later click edits part of the name.
                          selectAllOnFocus: true,
                          onTap: onTap,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '导出包名称',
                            prefixIcon: Icon(Icons.drive_file_rename_outline),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      CapsuleDropdownButtonFormField<PortableCompression>(
                        initialValue: _compression,
                        decoration: const InputDecoration(
                          labelText: '压缩策略',
                          prefixIcon: Icon(Icons.compress_rounded),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: PortableCompression.fast,
                            child: Text('极速 · 推荐给视频'),
                          ),
                          DropdownMenuItem(
                            value: PortableCompression.balanced,
                            child: Text('均衡 · 稍省空间'),
                          ),
                          DropdownMenuItem(
                            value: PortableCompression.smallest,
                            child: Text('最小体积 · 耐心模式'),
                          ),
                        ],
                        onChanged: _starting
                            ? null
                            : (value) {
                                setState(() => _compression = value!);
                                _rememberCurrentSettings();
                              },
                      ),
                      if (_zip) ...[
                        const SizedBox(height: 18),
                        const Text(
                          '字幕',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '范围是这张卡片上已经关联的全部字幕。两个都可以打开。文件里原来就有的字幕会保留，从成片里拆出来的副本不会再嵌一遍。',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _embedSubtitles,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _embedSubtitles = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('软字幕内嵌'),
                          subtitle: const Text(
                            '写进媒体，播放器里可以切换；ASS 弹幕使用 MKV 保留滚动效果。多数播放器一次显示一条。',
                          ),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _externalSubtitles,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _externalSubtitles = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('外挂字幕'),
                          subtitle: const Text('在视频旁边再放一份字幕文件。只有一条时使用同名文件。'),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _includeDanmaku,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _includeDanmaku = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('包含弹幕'),
                          subtitle: Text(
                            _danmakuSubtitle(
                              _embedSubtitles,
                              _externalSubtitles,
                            ),
                          ),
                        ),
                      ] else ...[
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _wrap,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _wrap = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('最外层包一层文件夹'),
                          subtitle: const Text('解压后桌面不会突然“下文件雨”'),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _sidecars,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _sidecars = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('包含字幕与附属文件'),
                          subtitle: const Text('保留外挂字幕、弹幕和已管理字幕'),
                        ),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: _checksums,
                          onChanged: _starting
                              ? null
                              : (value) {
                                  setState(() => _checksums = value);
                                  _rememberCurrentSettings();
                                },
                          title: const Text('生成完整性校验'),
                          subtitle: const Text('导出前多看一眼，跨设备更安心'),
                        ),
                      ],
                      const SizedBox(height: 12),
                      DesktopButtonClickRegion(
                        child: FilledButton.icon(
                          onPressed:
                              _nameController.text.trim().isEmpty || _starting
                              ? null
                              : _start,
                          icon: _starting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt_rounded),
                          label: Text(
                            _starting
                                ? '正在检查并准备'
                                : mobile
                                ? '开始导出'
                                : '选择保存位置',
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

Widget _note({
  required IconData icon,
  required String text,
  Color color = const Color(0xFFAEB8FF),
}) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF222532),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

String _danmakuSubtitle(bool embed, bool external) {
  if (embed && external) {
    return '嵌进视频，并另存为旁边的「标题.弹幕.ass」。播放器里需要手动打开那条轨道。';
  }
  if (external) return '保存为旁边的「标题.弹幕.ass」。';
  return '作为一条不自动打开的软字幕嵌进视频。支持 ASS 的播放器里可以手动打开，看到滚动弹幕。';
}

String _summary(int mediaCount, int folderCount) {
  if (mediaCount == 0) {
    return '$folderCount 个文件夹将合并为一个文件';
  }
  if (folderCount == 0) return '$mediaCount 个媒体将合并为一个文件';
  return '$mediaCount 个媒体、$folderCount 个文件夹将合并为一个文件';
}

Future<String?> _chooseOutputPath({
  required String fileName,
  required String extension,
  required bool zip,
}) async {
  final desktop =
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  if (desktop) {
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: zip ? '保存 Zip' : '保存 Fluent Pack',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: <String>[extension],
    );
    if (picked == null || picked.trim().isEmpty) return null;
    return picked.toLowerCase().endsWith('.$extension')
        ? picked
        : '$picked.$extension';
  }
  final documents = await getApplicationDocumentsDirectory();
  final exportDirectory = Directory(
    p.join(documents.path, 'Fluent Player', 'Exports'),
  );
  await exportDirectory.create(recursive: true);
  return _nextAvailablePath(exportDirectory, fileName);
}

String _nextAvailablePath(Directory directory, String fileName) {
  final extension = p.extension(fileName);
  final stem = p.basenameWithoutExtension(fileName);
  var candidate = p.join(directory.path, fileName);
  var suffix = 2;
  while (File(candidate).existsSync()) {
    candidate = p.join(directory.path, '$stem ($suffix)$extension');
    suffix++;
  }
  return candidate;
}

String _safeFileName(String value) => value
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
    .replaceAll(RegExp(r'[. ]+$'), '');
