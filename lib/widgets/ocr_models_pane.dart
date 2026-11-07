import 'subtitle_settings_layout.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/model_center/device_resource_monitor.dart';
import '../features/model_center/device_resource_snapshot.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_download_sources.dart';
import '../features/model_center/offline_model_directory_import.dart';
import '../models/ocr_subtitle_models.dart';
import '../services/ocr_model_manager.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class OcrModelsPane extends StatefulWidget {
  const OcrModelsPane({
    super.key,
    required this.manager,
    required this.language,
    required this.canChoose,
    required this.onChoose,
    this.focusModelId,
    this.directoryImporter,
  });
  final OcrModelManager manager;
  final OcrSubtitleLanguage language;
  final bool canChoose;
  final void Function(OcrModelPreset) onChoose;
  final String? focusModelId;
  final OfflineModelDirectoryImporter? directoryImporter;
  @override
  State<OcrModelsPane> createState() => _OcrModelsPaneState();
}

class _OcrModelsPaneState extends State<OcrModelsPane> {
  List<OcrModelPreset>? _models;
  DeviceResourceSnapshot? _device;
  String? _error;
  final _busy = <String>{};
  final _probes = <String, CancelToken>{};
  final _results = <String, List<ModelSourceProbeResult>>{};
  final _cardKeys = <String, GlobalKey>{};
  final _detailsControllers = <String, ExpansibleController>{};
  final _scrollController = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.manager.center.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant OcrModelsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusModelId != widget.focusModelId) _scheduleFocus();
  }

  void _scheduleFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = widget.focusModelId;
      if (id == null) return;
      _detailsControllers[id]?.expand();
      final target = _cardKeys[id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 250),
          ),
        );
      }
    });
  }

  Future<void> _load() async {
    try {
      await widget.manager.initialize();
      final models = await widget.manager.presets();
      final device = await DeviceResourceMonitor.instance.readOnce();
      if (mounted) {
        setState(() {
          _models = models;
          _device = device;
          _error = null;
        });
        _scheduleFocus();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.manager.center.removeListener(_changed);
    for (final cancel in _probes.values) {
      cancel.cancel('页面已关闭');
    }
    _scrollController.dispose();
    for (final controller in _detailsControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _perform(
    OcrModelPreset model,
    Future<void> Function() action,
  ) async {
    if (!_busy.add(model.id)) return;
    _changed();
    try {
      await action();
    } catch (e) {
      if (mounted) AppToast.show('$e', type: AppToastType.error);
    } finally {
      _busy.remove(model.id);
      _changed();
    }
  }

  Future<void> _probe(OcrModelPreset model) async {
    if (_probes.containsKey(model.id)) {
      _probes.remove(model.id)?.cancel('已停止检测');
      _changed();
      return;
    }
    final cancel = CancelToken();
    _probes[model.id] = cancel;
    _changed();
    try {
      final results = await widget.manager.probe(model, cancel);
      if (mounted && !cancel.isCancelled) {
        setState(() => _results[model.id] = results);
      }
    } catch (e) {
      if (mounted && !cancel.isCancelled) {
        AppToast.show('$e', type: AppToastType.error);
      }
    } finally {
      _probes.remove(model.id);
      _changed();
    }
  }

  Future<void> _import(OcrModelPreset model) => _perform(model, () async {
    await (widget.directoryImporter ?? OfflineModelDirectoryImporter())
        .importFiles(
          dialogTitle: '选择 OCR 模型组合目录（包含各组件子目录）',
          files: [
            for (final id in model.componentIds)
              ...OfflineModelImportFile.forArtifact(
                widget.manager.center.artifact(id) ??
                    (throw StateError('OCR 模型组件不存在：$id')),
                componentDirectory: id,
              ),
          ],
          install: (directory) => widget.manager.importFiles(model, directory),
        );
  });
  String _language(String code) =>
      const {
        'zh-Hans': '简体中文',
        'zh-Hant': '繁体中文',
        'en': '英语',
        'ja': '日语',
        'ko': '韩语',
        'af': '南非荷兰语',
        'az': '阿塞拜疆语',
        'bs': '波斯尼亚语',
        'ca': '加泰罗尼亚语',
        'cs': '捷克语',
        'cy': '威尔士语',
        'da': '丹麦语',
        'de': '德语',
        'es': '西班牙语',
        'et': '爱沙尼亚语',
        'eu': '巴斯克语',
        'fi': '芬兰语',
        'fr': '法语',
        'ga': '爱尔兰语',
        'gl': '加利西亚语',
        'hr': '克罗地亚语',
        'hu': '匈牙利语',
        'id': '印度尼西亚语',
        'is': '冰岛语',
        'it': '意大利语',
        'ku': '库尔德语',
        'la': '拉丁语',
        'lb': '卢森堡语',
        'lt': '立陶宛语',
        'lv': '拉脱维亚语',
        'mi': '毛利语',
        'ms': '马来语',
        'mt': '马耳他语',
        'nl': '荷兰语',
        'no': '挪威语',
        'oc': '奥克语',
        'pi': '巴利语',
        'pl': '波兰语',
        'pt': '葡萄牙语',
        'qu': '克丘亚语',
        'rm': '罗曼什语',
        'ro': '罗马尼亚语',
        'sk': '斯洛伐克语',
        'sl': '斯洛文尼亚语',
        'sq': '阿尔巴尼亚语',
        'sv': '瑞典语',
        'sw': '斯瓦希里语',
        'tl': '他加禄语',
        'tr': '土耳其语',
        'uz': '乌兹别克语',
        'vi': '越南语',
        'chinese': '中文',
        'english': '英文',
        'japanese': '日文',
        'korean': '韩文',
        'latin': '拉丁语种',
      }[code] ??
      code;

  @override
  Widget build(BuildContext context) {
    final center = widget.manager.center;
    return SubtitleSettingsTheme(
      child: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : _models == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              key: const PageStorageKey('ocr-models'),
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('模型按需下载，完成后可离线识别。离开页面后下载仍会继续。'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('ocr-source-${center.ocrSourcePreference}'),
                    initialValue: center.ocrSourcePreference,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'OCR 下载来源',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final key in [
                        'auto',
                        'mainland',
                        'official',
                        'mirror',
                        'mirror_proxy',
                      ])
                        DropdownMenuItem(
                          value: key,
                          child: Text(
                            key == 'auto' ? '自动检测并选择' : modelSourceLabel(key),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        center.ocrSourcePreference = value;
                        unawaited(center.settingsChanged());
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本机推荐依据处理器、内存余量、语言和可对比的历史测速；选择后固定使用该模型。'
                    '${_device?.memoryBytes == null ? '' : ' 设备内存约 ${(_device!.memoryBytes! / 1073741824).round()} GB。'}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: SubtitleSettingsTheme.secondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final model in _models!.where(
                    (m) => !m.legacy || widget.manager.ready(m),
                  ))
                    _modelCard(model),
                ],
              ),
            ),
    );
  }

  Widget _modelCard(OcrModelPreset model) {
    final manager = widget.manager, center = manager.center;
    final ready = manager.ready(model), inUse = manager.inUse(model);
    final downloading = model.componentIds.any(
      (id) => const [
        ModelDownloadPhase.downloading,
        ModelDownloadPhase.queued,
        ModelDownloadPhase.verifying,
      ].contains(center.downloads[id]?.phase),
    );
    final states = model.componentIds
        .map((id) => center.downloads[id])
        .whereType<ModelDownload>()
        .toList();
    final bytes = model.bytes(center.catalog);
    final received = model.componentIds.fold<int>(
      0,
      (n, id) =>
          n +
          (center.installed(id)
              ? center.artifact(id)!.bytes
              : center.downloads[id]?.received ?? 0),
    );
    final speed = states.fold<double>(0, (n, s) => n + s.bytesPerSecond);
    final remaining = speed > 0 ? ((bytes - received) / speed).ceil() : null;
    final busy = _busy.contains(model.id);
    final recommended =
        model.id ==
        recommendedOcrPreset(
          _device,
          widget.language,
          measurements: center.ocrPerformance.values.where(
            (r) => _models!.any(
              (m) =>
                  m.id == r['modelId'] &&
                  manager.identity(m) == r['modelIdentity'],
            ),
          ),
        );
    final measured =
        center.ocrPerformance.values
            .where(
              (r) =>
                  r['modelId'] == model.id &&
                  r['modelIdentity'] == manager.identity(model) &&
                  ocrMeasurementMatches(r, _device, widget.language),
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['testedAt'] as String).compareTo(a['testedAt'] as String),
          );
    final checks =
        _results[model.id] ??
        center.sourceChecks[model.recognition] ??
        const <ModelSourceProbeResult>[];
    final source = center.artifact(model.recognition)!;
    return Card(
      key: ValueKey('ocr-model-${model.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        key: _cardKeys.putIfAbsent(model.id, () => GlobalKey()),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${model.name}${model.legacy ? ' · ${model.groups.map(_language).join('、')}' : ''}',
              style: SubtitleSettingsTheme.heading,
            ),
            if (recommended)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '本机推荐 · 未下载模型的推荐为配置建议',
                  style: TextStyle(color: Color(0xFF8FB8FF), fontSize: 12),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              '${model.parameters} · ${modelBytes(bytes)} · FP32 / ONNX',
              style: const TextStyle(
                fontSize: 12,
                color: SubtitleSettingsTheme.secondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(model.description),
            Text(
              '建议 ${model.suggestedRamGb} GB 起，实际取决于当前可用内存。',
              style: const TextStyle(
                fontSize: 12,
                color: SubtitleSettingsTheme.secondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '支持：${model.groups.map(_language).join('、')}',
              style: const TextStyle(fontSize: 12),
            ),
            ExpansionTile(
              key: PageStorageKey('ocr-model-details-${model.id}'),
              controller: _detailsControllers.putIfAbsent(
                model.id,
                () => ExpansibleController(),
              ),
              initiallyExpanded: model.id == widget.focusModelId,
              tilePadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: const Text('语言、兼容性与来源', style: TextStyle(fontSize: 12)),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${model.languages.map(_language).join('、')}\nAndroid、iOS、macOS、Windows、Linux\n'
                    'CPU 保底；硬件加速以本机运行结果为准。\n许可证：${model.license}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse(source.homepage),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('官方模型说明'),
                      ),
                    ),
                    if (!model.legacy)
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => launchUrl(
                            Uri.parse(
                              'https://modelscope.cn/models/PaddlePaddle/${source.name}_onnx',
                            ),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Text('魔搭来源'),
                        ),
                      ),
                  ],
                ),
                if (!model.legacy)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '离线导入：选择包含以下组件子目录的组合目录，各子目录放置官方 inference.onnx 与 inference.yml：\n${model.componentIds.join('\n')}',
                      key: PageStorageKey('ocr-model-import-${model.id}'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: SubtitleSettingsTheme.secondary,
                      ),
                    ),
                  ),
              ],
            ),
            if (downloading ||
                states.any(
                  (s) =>
                      s.phase == ModelDownloadPhase.paused ||
                      s.phase == ModelDownloadPhase.failed,
                )) ...[
              LinearProgressIndicator(
                value: bytes == 0 ? null : (received / bytes).clamp(0, 1),
              ),
              const SizedBox(height: 5),
              Text(
                '${modelBytes(received)} / ${modelBytes(bytes)}${speed > 0 ? ' · ${modelBytes(speed.round())}/s' : ''}'
                '${remaining == null ? '' : ' · 约 ${remaining ~/ 60}分${remaining % 60}秒'}',
                style: const TextStyle(fontSize: 11),
              ),
              for (final s in states.where(
                (s) =>
                    s.message.isNotEmpty &&
                    s.phase != ModelDownloadPhase.installed,
              ))
                Text(
                  s.message,
                  style: TextStyle(
                    fontSize: 11,
                    color: s.phase == ModelDownloadPhase.failed
                        ? Colors.redAccent
                        : SubtitleSettingsTheme.secondary,
                  ),
                ),
            ],
            if (ready)
              const Text(
                '已就绪 · 可离线使用',
                style: TextStyle(fontSize: 12, color: Colors.greenAccent),
              ),
            if (measured.isNotEmpty)
              Text(
                '本机上次任务：${((measured.first['mediaMs'] as num) / 1000).round()} 秒视频用时 '
                '${((measured.first['elapsedMs'] as num) / 1000).toStringAsFixed(1)} 秒 · ${measured.first['backend']}。'
                '实际速度随素材和区域变化。',
                style: const TextStyle(
                  fontSize: 11,
                  color: SubtitleSettingsTheme.secondary,
                ),
              ),
            for (final check in checks)
              Text(
                '${modelSourceLabel(check.key)}：${check.available ? '${modelBytes(check.bytesPerSecond.round())}/s' : '本次检测未连通'}',
                style: const TextStyle(
                  fontSize: 11,
                  color: SubtitleSettingsTheme.secondary,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (ready)
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed:
                          !busy &&
                              widget.canChoose &&
                              model.supports(widget.language)
                          ? () => widget.onChoose(model)
                          : null,
                      child: const Text('选择此模型'),
                    ),
                  )
                else if (!model.legacy) ...[
                  DesktopButtonClickRegion(
                    child: OutlinedButton(
                      onPressed:
                          !busy &&
                              widget.canChoose &&
                              model.supports(widget.language)
                          ? () => widget.onChoose(model)
                          : null,
                      child: const Text('选择此模型'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed: busy
                          ? null
                          : () => _perform(
                              model,
                              () => downloading
                                  ? manager.pause(model)
                                  : manager.download(model),
                            ),
                      child: Text(downloading ? '暂停下载' : '下载 / 继续'),
                    ),
                  ),
                ],
                if (!model.legacy)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => _probe(model),
                      child: Text(
                        _probes.containsKey(model.id) ? '停止检测' : '检测下载源',
                      ),
                    ),
                  ),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: busy || inUse ? null : () => _import(model),
                    child: const Text('离线导入'),
                  ),
                ),
                if (ready)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: busy || inUse
                          ? null
                          : () => _perform(model, () => manager.verify(model)),
                      child: const Text('手动校验'),
                    ),
                  ),
                if (ready)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: busy || inUse
                          ? null
                          : () => _perform(model, () => manager.remove(model)),
                      child: Text(inUse ? '使用中' : '删除'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
