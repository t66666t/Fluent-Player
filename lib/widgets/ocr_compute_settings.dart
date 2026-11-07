import 'subtitle_settings_layout.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/ocr_compute_preferences.dart';
import '../services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class OcrComputeSettings extends StatefulWidget {
  const OcrComputeSettings({super.key, required this.manager});
  final OcrSubtitleManager manager;
  @override
  State<OcrComputeSettings> createState() => _OcrComputeSettingsState();
}

class _OcrComputeSettingsState extends State<OcrComputeSettings> {
  OcrComputeCapabilities? _capabilities;
  bool _expanded = false, _loading = false;
  @override
  void initState() {
    super.initState();
    // Restoring one small preference does not initialize models or drivers.
    unawaited(
      widget.manager
          .initialize()
          .then((_) {
            if (mounted) {
              setState(
                () => _expanded =
                    widget.manager.computePreferences.mode ==
                    OcrComputeMode.accelerated,
              );
              if (widget.manager.computePreferences.mode ==
                  OcrComputeMode.accelerated) {
                unawaited(_detect());
              }
            }
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _detect({bool refresh = false}) async {
    if (_loading || widget.manager.isRunning) return;
    setState(() => _loading = true);
    try {
      final value = await widget.manager.detectComputeDevices(refresh: refresh);
      if (mounted) setState(() => _capabilities = value);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _chooseMode(OcrComputeMode mode) async {
    await widget.manager.setComputePreferences(
      widget.manager.computePreferences.copyWith(mode: mode),
    );
    if (mounted) setState(() => _expanded = mode == OcrComputeMode.accelerated);
    if (mode == OcrComputeMode.accelerated &&
        _capabilities == null &&
        mounted) {
      await _detect();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.manager,
    builder: (context, _) {
      final manager = widget.manager;
      final running = manager.isRunning;
      final prefs = running
          ? manager.job?.compute ?? manager.computePreferences
          : manager.computePreferences;
      final showDevices = _expanded;
      final devices = _capabilities?.accelerators ?? const <OcrComputeDevice>[];
      final selectedDevice = devices
          .where(
            (d) =>
                d.provider == prefs.provider &&
                (prefs.deviceKey != null
                    ? d.key == prefs.deviceKey
                    : d.id == prefs.deviceId),
          )
          .firstOrNull;
      final deviceValue = prefs.provider == 'auto'
          ? 'auto'
          : selectedDevice?.key ??
                prefs.deviceKey ??
                '${prefs.provider}:${prefs.deviceId}';
      final missing =
          deviceValue != 'auto' && !devices.any((d) => d.key == deviceValue);
      final mobile = Platform.isAndroid || Platform.isIOS;
      final description = switch (prefs.mode) {
        OcrComputeMode.automatic =>
          mobile
              ? '推荐。自动分配算力，识别过程中采用校验通过且更快的加速方式，兼顾播放与手机温度。'
              : '推荐。根据设备余量分配算力，只采用校验通过且更快的加速方式。',
        OcrComputeMode.cpu => '使用优化的 CPU 识别，适合兼容性优先或显卡正在忙碌时。',
        OcrComputeMode.accelerated =>
          '优先尝试所选设备；不兼容或资源不足时自动回退 CPU。首次启用需要一些准备时间。',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final mode in OcrComputeMode.values)
                ChoiceChip(
                  key: ValueKey('ocr-compute-${mode.name}'),
                  label: Text(
                    mode == OcrComputeMode.automatic
                        ? '自动（推荐）'
                        : mode == OcrComputeMode.cpu
                        ? 'CPU'
                        : '硬件加速优先',
                  ),
                  selected: prefs.mode == mode,
                  onSelected: running
                      ? null
                      : (_) => unawaited(_chooseMode(mode)),
                  visualDensity: VisualDensity.compact,
                  selectedColor: const Color(0xFF324C72),
                  checkmarkColor: const Color(0xFFBDD7FF),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: prefs.mode == mode ? Colors.white : Colors.white70,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description, style: SubtitleSettingsTheme.description),
          if (running) ...[
            const SizedBox(height: 8),
            Text(
              '当前任务 · ${manager.activeBackend}',
              key: const ValueKey('ocr-compute-active'),
              style: const TextStyle(
                color: Color(0xFF9BBFFF),
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '任务结束后可更改识别设备',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButtonClickRegion(
              child: TextButton.icon(
                key: const ValueKey('ocr-compute-details'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: const Text('设备与加速详情', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _expanded = !_expanded);
                  if (_expanded && _capabilities == null && !running) {
                    unawaited(_detect());
                  }
                },
              ),
            ),
          ),
          if (showDevices) ...[
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '正在检测可用设备…',
                        style: SubtitleSettingsTheme.description,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_loading && _capabilities != null) ...[
              if (devices.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey('ocr-compute-device-$deviceValue'),
                  initialValue: deviceValue,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF292E36),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    color: Colors.white,
                  ),
                  decoration: const InputDecoration(
                    labelText: '加速设备',
                    labelStyle: TextStyle(fontSize: 12),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'auto',
                      child: Text('自动选择设备'),
                    ),
                    if (missing)
                      DropdownMenuItem(
                        value: deviceValue,
                        enabled: false,
                        child: const Text('之前的设备（当前不可用）'),
                      ),
                    for (final d in devices)
                      DropdownMenuItem(
                        value: d.key,
                        child: Text(
                          '${const ['windows', 'linux'].contains(_capabilities!.platform) ? 'GPU ${d.id + 1} · ' : ''}${d.name} · ${d.provider}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: running
                      ? null
                      : (value) {
                          final device = devices
                              .where((d) => d.key == value)
                              .firstOrNull;
                          unawaited(
                            manager.setComputePreferences(
                              prefs.copyWith(
                                provider: device?.provider ?? 'auto',
                                deviceId: device?.id ?? 0,
                                deviceKey: device?.key,
                                clearDevice: device == null,
                              ),
                            ),
                          );
                        },
                )
              else
                Text(
                  _capabilities!.note.isEmpty
                      ? '当前没有可用的硬件加速，任务将使用 CPU 优化识别。'
                      : _capabilities!.note,
                  style: SubtitleSettingsTheme.description,
                ),
              if (devices.any((d) => d.provider == 'CoreML') &&
                  (prefs.provider == 'auto' || prefs.provider == 'CoreML')) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('ocr-coreml-${prefs.coreMLUnits}'),
                  initialValue: prefs.coreMLUnits,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF292E36),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 12,
                    color: Colors.white,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Apple 加速方式',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ALL', child: Text('系统自动分配（推荐）')),
                    DropdownMenuItem(
                      value: 'CPUAndGPU',
                      child: Text('CPU 与 GPU'),
                    ),
                    DropdownMenuItem(
                      value: 'CPUAndNeuralEngine',
                      child: Text('CPU 与神经网络引擎'),
                    ),
                  ],
                  onChanged: running
                      ? null
                      : (v) => unawaited(
                          manager.setComputePreferences(
                            prefs.copyWith(coreMLUnits: v),
                          ),
                        ),
                ),
              ],
              if (_capabilities!.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _capabilities!.note,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              if (_capabilities!.platform == 'android')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Android 硬件加速取决于手机驱动与模型支持；部分设备使用 CPU 更快。',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              if (!running)
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButtonClickRegion(
                    child: TextButton.icon(
                      key: const ValueKey('ocr-compute-refresh'),
                      onPressed: () => unawaited(_detect(refresh: true)),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text(
                        '重新检测并重试加速',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ],
      );
    },
  );
}
