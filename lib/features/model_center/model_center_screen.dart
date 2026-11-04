import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ai_subtitle_api_settings.dart';
import '../../widgets/transcription_language_selector.dart';
import '../../services/ai_subtitle_translator.dart';
import '../../services/subtitle_translate_settings.dart';
import '../../services/subtitle_translation_service.dart';
import '../../services/transcription_manager.dart';
import '../../theme/app_page_transitions.dart';
import '../../utils/route_transition_work.dart';
import '../../models/subtitle_punctuation.dart';
import '../../widgets/ai_subtitle_api_dialog.dart';
import '../../widgets/translation_language_controls.dart';
import '../../widgets/media_library_shell.dart';
import 'inference_scheduler.dart';
import 'asr_enhancement_screen.dart';
import 'asr_enhancement_options.dart';
import 'asr_enhancement_processing.dart';
import 'asr_native_enhancer.dart';
import 'asr_acceleration.dart';
import 'asr_benchmark.dart';
import 'device_resource_monitor.dart';
import 'device_resource_snapshot.dart';
import 'inference_resource_governor.dart';
import 'local_asr_worker.dart';
import 'local_subtitle_translator.dart';
import 'model_catalog.dart';
import 'model_center_service.dart';
import 'offline_model_directory_import.dart';
import 'model_adapters.dart';
import 'model_center_widgets.dart';
import 'model_device_info.dart';
import 'model_download_sources.dart';
import 'model_language_summary.dart';
import 'model_transcription.dart';
import 'cloud_asr_editor.dart';
import 'subtitle_segmentation_screen.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> openModelCenter(
  BuildContext context, {
  int? tab,
  SubtitleTranslateSettings? translateSettings,
  ModelCenterService? service,
  bool transcriptionOnly = false,
}) async {
  final center = service ?? ModelCenterService.instance;
  center.selectedTab = tab ?? 0;
  final settings =
      translateSettings ??
      lookupSubtitleTranslateSettings(context, listen: false);
  await pushAboveMediaLibrary<void>(
    context,
    AppMaterialPageRoute(
      builder: (_) => ModelCenterScreen(
        service: center,
        translateSettings: settings,
        initialTab: tab ?? 0,
        transcriptionOnly: transcriptionOnly,
      ),
    ),
  );
}

class ModelCenterScreen extends StatefulWidget {
  const ModelCenterScreen({
    super.key,
    this.service,
    this.translateSettings,
    this.deviceInfo,
    this.initialTab,
    this.transcriptionOnly = false,
    this.directoryImporter,
  });
  final ModelCenterService? service;
  final SubtitleTranslateSettings? translateSettings;
  final ModelDeviceInfo? deviceInfo;
  final int? initialTab;
  final bool transcriptionOnly;
  final OfflineModelDirectoryImporter? directoryImporter;
  @override
  State<ModelCenterScreen> createState() => _ModelCenterScreenState();
}

class _ModelCenterScreenState extends State<ModelCenterScreen> {
  late final center = widget.service ?? ModelCenterService.instance;
  late SubtitleTranslateSettings translation;
  late final search = TextEditingController(text: center.search);
  final terminology = TextEditingController();
  final terminologyFocus = FocusNode();
  final terminologyScroll = ScrollController(keepScrollOffset: false);
  final _localTerminologyFocus = FocusNode();
  final _localTerminologyScroll = ScrollController(keepScrollOffset: false);
  Route<void>? _managementRoute;
  Route<void>? _localSettingsRoute;
  bool _initialDestinationOpened = false;
  bool _detailVisible = false;
  final _detailError = ValueNotifier<String?>(null);
  final Set<String> _pendingDownloads = {};
  final _pageStorage = PageStorageBucket();
  final _viewChanges = ValueNotifier<int>(0);
  final _routeWork = RouteTransitionWork();
  bool _bound = false;
  Completer<void>? _translationBenchmarkCancel;
  String? _translationBenchmarkActivity;
  Completer<void>? _asrBenchmarkCancel;
  String? _asrBenchmarkModel;
  Set<String> get _checking => center.checking;
  late final Future<ModelDeviceInfo> deviceInfo = widget.deviceInfo == null
      ? ModelDeviceInfo.load()
      : Future.value(widget.deviceInfo);
  final Map<int, ScrollController> _scrolls = {};
  late final Future<DeviceResourceSnapshot> _recommendation =
      widget.deviceInfo == null
      ? DeviceResourceMonitor.instance.readOnce()
      : Future.value(
          DeviceResourceSnapshot(
            platform: Platform.operatingSystem,
            processors: widget.deviceInfo!.processors,
            memoryBytes: widget.deviceInfo!.memoryBytes,
            availableMemoryBytes: widget.deviceInfo!.availableMemoryBytes,
            capturedAt: DateTime.now(),
          ),
        );
  ScrollController _scrollFor(int tab) => _scrolls.putIfAbsent(tab, () {
    final storageKey = tab == 0 ? 'configuration-v2' : '$tab';
    final controller = ScrollController(
      initialScrollOffset: center.scrollPositions[storageKey] ?? 0,
    );
    controller.addListener(() {
      center.scrollPositions[storageKey] = controller.offset;
    });
    return controller;
  });

  @override
  void initState() {
    super.initState();
    center.addListener(_changed);
    if (center.loaded) {
      _initialized();
    } else {
      unawaited(
        center
            .initialize()
            .then((_) => _initialized())
            .catchError((Object _) {}),
      );
    }
  }

  void _initialized() {
    if (!mounted) return;
    search.text = center.search;
    center.selectedTab = 0;
    _changed();
    if (_initialDestinationOpened) return;
    _initialDestinationOpened = true;
    final destination = (widget.initialTab ?? 0).clamp(0, 3);
    if (destination != 0) {
      _routeWork.schedule('initial-destination', () {
        if (mounted) unawaited(_openManagement(destination));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeWork.bind(ModalRoute.of(context));
    if (_bound) return;
    translation =
        widget.translateSettings ??
        lookupSubtitleTranslateSettings(context, listen: false) ??
        SubtitleTranslateSettings();
    translation.useModelCenter(center);
    translation.addListener(_changed);
    terminology.text = translation.aiOptions.customPrompt;
    unawaited(translation.ensureLoaded());
    _bound = true;
  }

  @override
  void dispose() {
    _routeWork.dispose();
    if (_asrBenchmarkCancel case final cancel?) {
      if (!cancel.isCompleted) cancel.complete();
    }
    final benchmarkCancel = _translationBenchmarkCancel;
    if (benchmarkCancel != null && !benchmarkCancel.isCompleted) {
      benchmarkCancel.complete();
    }
    center.removeListener(_changed);
    translation.removeListener(_changed);
    center.rememberView();
    search.dispose();
    terminology.dispose();
    terminologyFocus.dispose();
    terminologyScroll.dispose();
    _localTerminologyFocus.dispose();
    _localTerminologyScroll.dispose();
    _detailError.dispose();
    _viewChanges.dispose();
    for (final controller in _scrolls.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (_bound &&
        !terminologyFocus.hasFocus &&
        !_localTerminologyFocus.hasFocus &&
        terminology.text != translation.aiOptions.customPrompt) {
      terminology.text = translation.aiOptions.customPrompt;
    }
    if (mounted) {
      _viewChanges.value++;
      setState(() {});
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  void _changeView(VoidCallback change) {
    if (!mounted) return;
    setState(change);
    _viewChanges.value++;
  }

  Future<void> _benchmarkTranslation() async {
    if (_translationBenchmarkCancel != null) return;
    final cancel = Completer<void>();
    _changeView(() {
      _translationBenchmarkCancel = cancel;
      _translationBenchmarkActivity = '正在准备本机翻译测速';
    });
    try {
      final spec = await captureLocalTranslation(center);
      LocalTranslationMetrics? measured;
      center.clearTranslationPerformance(spec.profile.model);
      await center.settingsChanged();
      await LocalSubtitleTranslator(center: center).translate(
        texts: const [
          'Good morning, everyone.',
          'Today we will learn how this machine works.',
          'First, make sure the power is turned off.',
          'Do not touch the red wire.',
          'Can you pass me the small screwdriver?',
          'Be careful. This part is very fragile.',
          'You can change the brightness in the settings.',
          'Thank you for your help.',
        ],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        specification: ModelJobSpec(
          profile: spec.profile,
          artifactIdentity: spec.artifactIdentity,
          translation: Platform.isAndroid
              ? spec.translation
              : spec.translation.copyWith(
                  acceleration: TranslationAcceleration.auto,
                ),
        ),
        onProgress: (_) {},
        onActivity: (value) {
          if (mounted) _changeView(() => _translationBenchmarkActivity = value);
        },
        onMetrics: (metrics) => measured = metrics,
        cancelSignal: cancel.future,
        resume: false,
        calibrate: true,
        checkpointScope: 'performance-probe',
      );
      if (mounted && !cancel.isCompleted && measured != null) {
        _changeView(
          () => _translationBenchmarkActivity =
              (Platform.isAndroid
                  ? null
                  : center
                        .translationPerformance[spec.profile.model]
                        ?.summary) ??
              '本机测速完成 · ${measured!.backend} · ${(measured!.elapsedMs / 1000).toStringAsFixed(2)} 秒 · ${measured!.threads} 个 CPU 线程',
        );
      }
    } catch (_) {
      if (mounted) {
        _changeView(
          () => _translationBenchmarkActivity = cancel.isCompleted
              ? '测速已取消'
              : '测速未完成，可重试或选择 CPU',
        );
      }
      if (!cancel.isCompleted) rethrow;
    } finally {
      if (mounted) _changeView(() => _translationBenchmarkCancel = null);
    }
  }

  Future<void> _openManagement(int section) async {
    if (_managementRoute != null || !mounted) return;
    _routeWork.cancel('initial-destination');
    TranscriptionManager? transcription;
    if (section == 3) {
      try {
        transcription = Provider.of<TranscriptionManager>(
          context,
          listen: false,
        );
      } on ProviderNotFoundException {
        // Standalone configuration pages may not have a transcription manager.
      }
    }
    center.selectedTab = section;
    center.rememberView();
    final route = AppMaterialPageRoute<void>(
      builder: (pageContext) => ListenableBuilder(
        listenable: Listenable.merge([_viewChanges, ?transcription]),
        builder: (_, _) => PageStorage(
          bucket: _pageStorage,
          child: Scaffold(
            appBar: AppBar(
              title: Text(switch (section) {
                1 => '本地模型',
                2 => '服务管理',
                _ => '下载与任务',
              }),
            ),
            body: SafeArea(
              top: false,
              child: switch (section) {
                1 => _models(),
                2 => _services(),
                _ => _tasks(transcription),
              },
            ),
          ),
        ),
      ),
    );
    _managementRoute = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      _managementRoute = null;
      center.selectedTab = 0;
      center.rememberView();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageStorage(
      bucket: _pageStorage,
      child: Scaffold(
        key: const ValueKey('model-center-home'),
        appBar: AppBar(title: Text(widget.transcriptionOnly ? '转录设置' : '模型中心')),
        body: SafeArea(
          top: false,
          child: !center.loaded
              ? Center(
                  child: center.initializationError == null
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(center.initializationError!),
                              const SizedBox(height: 12),
                              DesktopButtonClickRegion(child: FilledButton(
                                onPressed: () => _act(center.initialize),
                                child: const Text('重新加载'),
                              )),
                            ],
                          ),
                        ),
                )
              : _features(),
        ),
      ),
    );
  }

  Widget _managementLinks() => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final wide = constraints.maxWidth >= 1000;
      final buttons = [
        for (final entry in [
          (1, Icons.memory_outlined, '本地模型'),
          (2, Icons.cloud_outlined, '服务管理'),
          (3, Icons.downloading_rounded, '下载与任务'),
        ])
          DesktopButtonClickRegion(child: OutlinedButton(
            key: ValueKey('model-center-manage-${entry.$1}'),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.onSurfaceVariant,
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 12 : 4,
                vertical: 8,
              ),
              minimumSize: Size(0, wide ? 48 : 56),
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => _openManagement(entry.$1),
            child: wide
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible:
                            entry.$1 == 3 && center.activeDownloads > 0,
                        label: Text('${center.activeDownloads}'),
                        child: Icon(entry.$2, size: 18),
                      ),
                      const SizedBox(width: 8),
                      Text(entry.$3),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Badge(
                        isLabelVisible:
                            entry.$1 == 3 && center.activeDownloads > 0,
                        label: Text('${center.activeDownloads}'),
                        child: Icon(entry.$2, size: 20),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.$1 == 3 ? '下载任务' : entry.$3,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          )),
      ];
      return Row(
        children: [
          if (wide)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('功能配置', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '自动保存，对新建任务生效。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          for (var index = 0; index < buttons.length; index++) ...[
            if (index > 0) const SizedBox(width: 8),
            if (wide) buttons[index] else Expanded(child: buttons[index]),
          ],
        ],
      );
    },
  );

  Widget _list(List<Widget> children, {required int section}) => LayoutBuilder(
    builder: (context, constraints) => Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: constraints.maxWidth.clamp(0.0, 1280.0),
        child: ListView(
          controller: _scrollFor(section),
          padding: EdgeInsets.all(constraints.maxWidth < 600 ? 12 : 24),
          children: [
            for (final child in children)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
          ],
        ),
      ),
    ),
  );

  Widget _card(
    String title,
    String subtitle,
    List<Widget> children, {
    IconData icon = Icons.tune,
  }) => ModelCenterPanel(
    title: title,
    subtitle: subtitle,
    icon: icon,
    children: children,
  );

  Widget _field(Widget child) =>
      Padding(padding: const EdgeInsets.only(top: 10), child: child);

  String _performanceSummary(bool asr) {
    if (asr) {
      if (center.asrExecution == AsrExecutionMode.lowMemory) return '省内存模式';
      return center.asrCpuThreads == 0 &&
              center.asrAccelerationFor(center.asrProfile.model) ==
                  AsrAcceleration.auto
          ? '自动加速 · 推荐'
          : '自定义性能';
    }
    final options = center.translationOptions;
    return options.threads == 0 &&
            options.acceleration == TranslationAcceleration.auto &&
            options.batchSize == 8 &&
            options.gpuLayers == 999
        ? '自动加速 · 推荐'
        : '自定义性能';
  }

  void _rememberPerformanceExpansion(bool asr, bool expanded) {
    final key = asr ? 'asr' : 'translation';
    if (expanded) {
      center.expandedPerformanceSections.add(key);
    } else {
      center.expandedPerformanceSections.remove(key);
    }
    center.rememberView();
  }

  Future<void> _openLocalSettings(bool asr) async {
    if (_localSettingsRoute != null) return;
    _routeWork.cancel('initial-destination');
    final route = AppMaterialPageRoute<void>(
      builder: (_) => ListenableBuilder(
        listenable: _viewChanges,
        builder: (_, _) => PageStorage(
          bucket: _pageStorage,
          child: Scaffold(
            key: ValueKey(asr ? 'local-asr-page' : 'local-translation-page'),
            appBar: AppBar(title: Text(asr ? '本地转录设置' : '本地翻译设置')),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final performance = ModelCenterPanel(
                    title: '性能',
                    icon: Icons.speed_rounded,
                    subtitle: _performanceSummary(asr),
                    children: [
                      if (center.artifact(
                            asr
                                ? center.asrProfile.model
                                : center.translationModelId,
                          )
                          case final model?)
                        ModelCenterSetting(
                          label: '当前模型',
                          value: model.name,
                          trailing: _modelDownloadButton(model),
                          onTap: () => _openModelDetails(model.id),
                        ),
                      _deviceRecommendation(asr: asr),
                      if (asr)
                        _asrPerformanceControls()
                      else
                        _translationPerformanceControls(),
                      _resourceControls(asr: asr),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: DesktopButtonClickRegion(child: TextButton.icon(
                          key: ValueKey(
                            asr
                                ? 'restore-asr-performance'
                                : 'restore-translation-performance',
                          ),
                          icon: const Icon(Icons.restore_rounded),
                          label: const Text('使用推荐设置'),
                          onPressed: () => _act(() async {
                            if (asr) {
                              center.asrCpuThreads = 0;
                              center.asrExecution = AsrExecutionMode.auto;
                              center.asrAccelerationOptions[center
                                      .asrProfile
                                      .model] =
                                  AsrAcceleration.auto;
                              center.asrBackendStatus.remove(
                                center.asrProfile.model,
                              );
                            } else {
                              center.translationOptions =
                                  const LocalTranslationOptions();
                            }
                            await center.settingsChanged();
                          }),
                        )),
                      ),
                    ],
                  );
                  final output = ModelCenterPanel(
                    title: asr ? '字幕处理' : '翻译要求',
                    icon: asr
                        ? Icons.subtitles_outlined
                        : Icons.translate_rounded,
                    children: asr
                        ? [
                            ListTile(
                              key: const ValueKey('open-asr-enhancements'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('识别增强'),
                              subtitle: const Text('降噪、时间精校与声道'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      AsrEnhancementScreen(center: center),
                                ),
                              ),
                            ),
                            ListTile(
                              key: const ValueKey('open-subtitle-segmentation'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('字幕分句'),
                              subtitle: Text(
                                center.subtitleSegmentation.summary,
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => SubtitleSegmentationScreen(
                                    center: center,
                                  ),
                                ),
                              ),
                            ),
                          ]
                        : [
                            if (center.artifact(center.translationModelId)
                                case final model?)
                              _languageHint(model),
                            _terminologyField(local: true),
                          ],
                  );
                  return SingleChildScrollView(
                    controller: _scrollFor(asr ? 10 : 11),
                    key: PageStorageKey(
                      asr ? 'local-asr-scroll' : 'local-translation-scroll',
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1280),
                        child: constraints.maxWidth >= 1000
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: performance),
                                  const SizedBox(width: 16),
                                  Expanded(child: output),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  performance,
                                  const SizedBox(height: 12),
                                  output,
                                ],
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    _localSettingsRoute = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      _localSettingsRoute = null;
    }
  }

  Widget _deviceRecommendation({bool? asr}) =>
      FutureBuilder<DeviceResourceSnapshot>(
        future: _recommendation,
        builder: (_, snapshot) {
          final device = snapshot.data;
          if (device == null) return const Text('正在检测本机推荐配置…');
          if (!device.memoryKnown) return const Text('资源信息暂不完整，任务开始后自动调整。');
          final auxiliary =
              center.asrEnhancements.enabled &&
              (center.asrEnhancements.denoise ||
                  center.asrEnhancements.alignment ||
                  center.asrEnhancements.punctuation ||
                  center.asrEnhancements.trimSilence);
          final budget = InferenceResourceGovernor(
            device,
            now: () => device.capturedAt,
          ).decide(pipelineRequested: auxiliary);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (asr != false)
                Text(
                  '转录建议：自动 · 最多 ${budget.asrThreads} 个计算线程',
                  key: const ValueKey('asr-thread-recommendation'),
                ),
              if (asr != true)
                Text(
                  '翻译建议：自动 · 生成 ${budget.translationThreads} 个计算线程',
                  key: const ValueKey('translation-thread-recommendation'),
                ),
              if (asr != false) const Text('默认流水线，按设备情况自动调整。'),
            ],
          );
        },
      );

  String _modelStatus(ModelArtifact model) {
    if (center.installed(model.id)) return '已安装';
    final state = center.downloads[model.id];
    if (state?.phase == ModelDownloadPhase.failed) return '下载失败';
    return state == null || state.phase == ModelDownloadPhase.installed
        ? '未下载'
        : state.label;
  }

  bool _modelDownloading(ModelArtifact model) => const [
    ModelDownloadPhase.queued,
    ModelDownloadPhase.downloading,
    ModelDownloadPhase.verifying,
  ].contains(center.downloads[model.id]?.phase);

  bool _isQwenAsr(ModelArtifact model) =>
      model.purpose == ModelPurpose.transcription &&
      model.engine == 'qwen3-asr';

  List<ModelArtifact> _downloadComponents(ModelArtifact model) =>
      model.purpose == ModelPurpose.transcription
      ? center.asrDownloadComponents(model) : [model];

  bool _needsDownload(ModelArtifact model) =>
      _downloadComponents(model).any((part) => !center.installed(part.id));

  String _downloadSizeSummary(ModelArtifact model) {
    if (!_isQwenAsr(model)) return modelBytes(model.bytes);
    final enhancements = center.asrEnhancementArtifacts(model);
    final bytes = enhancements.fold(0, (n, part) => n + part.bytes);
    return '主模型 ${modelBytes(model.bytes)}${bytes == 0 ? '' : ' + 共享增强 ${modelBytes(bytes)}'}';
  }

  Future<void> _downloadFromFeatures(ModelArtifact model) =>
      _openModelDetails(model.id, download: !_isQwenAsr(model));

  Future<void> _enqueueModel(ModelArtifact model) async {
    if (!_needsDownload(model) ||
        (!_isQwenAsr(model) && _modelDownloading(model)) ||
        !_pendingDownloads.add(model.id)) {
      return;
    }
    _detailError.value = null;
    try {
      if (model.purpose == ModelPurpose.transcription) {
        await center.queueAsrDownload(model);
      } else {
        await center.enqueue(model.id);
      }
    } finally {
      _pendingDownloads.remove(model.id);
    }
  }

  Widget? _modelDownloadButton(ModelArtifact? model) {
    if (model == null || !_needsDownload(model)) return null;
    final downloading = _downloadComponents(model).any(_modelDownloading);
    return DesktopButtonClickRegion(child: IconButton(
      key: ValueKey('selected-download-${model.id}'),
      tooltip:
          '${downloading ? '查看下载' : '下载'} ${model.name}${_isQwenAsr(model) ? '（含所需增强组件）' : ''}',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Icon(
        downloading ? Icons.downloading_rounded : Icons.download_outlined,
      ),
      onPressed: () => _downloadFromFeatures(model),
    ));
  }

  String _asrLanguages(String id, Map<String, ModelArtifact> models) {
    final model =
        models[id] ?? center.artifact(center.profiles[id]?.model ?? '');
    if (model != null) return modelLanguageSummary(model);
    if (center.profiles[id]?.kind == TranscriptionServiceKind.gongyi) {
      return '支持：普通话、英语';
    }
    return '支持语言以所配置的服务端模型为准';
  }

  Widget _languageHint(ModelArtifact model) => Tooltip(
    message: modelLanguageSummary(model, full: true),
    child: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        modelLanguageSummary(model),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );

  Future<void> _benchmarkAsr(ModelArtifact model) async {
    if (_asrBenchmarkCancel != null || _checking.contains(model.id)) return;
    final cancel = _asrBenchmarkCancel = Completer<void>();
    _asrBenchmarkModel = model.id;
    _checking.add(model.id);
    await center.settingsChanged();
    try {
      await benchmarkLocalAsr(
        center: center,
        model: model,
        cancelSignal: cancel.future,
        onProgress: (_) {
          if (mounted) _changeView(() {});
        },
      );
    } finally {
      _checking.remove(model.id);
      if (mounted) {
        _changeView(() {
          _asrBenchmarkCancel = null;
          _asrBenchmarkModel = null;
        });
      }
      await center.settingsChanged();
    }
  }

  Widget _asrAccelerationControls({bool advanced = false}) {
    final model = center.asrProfile.local
        ? center.artifact(center.asrProfile.model)
        : null;
    if (model == null) return const SizedBox.shrink();
    final pack = center.artifact(asrAccelerationPackId(model.id));
    final benchmarking = _asrBenchmarkModel == model.id;
    final previous =
        center.asrPerformance.entries
            .where((e) => e.key.startsWith('${model.id}:'))
            .map((e) => e.value)
            .toList()
          ..sort((a, b) => b.testedAt.compareTo(a.testedAt));
    final status =
        center.asrBackendStatus[model.id] ?? previous.firstOrNull?.summary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!advanced) ...[
            CapsuleDropdownButtonFormField<AsrAcceleration>(
              key: ValueKey('asr-acceleration-${model.id}'),
              initialValue: center.asrAccelerationFor(model.id),
              isExpanded: true,
              selectedItemBuilder: (_) => const [
                Text('自动 · 推荐'),
                Text('CPU'),
                Text('GPU / 硬件加速'),
              ],
              decoration: const InputDecoration(
                labelText: '计算方式',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: AsrAcceleration.auto,
                  child: Text('自动 · 推荐'),
                ),
                DropdownMenuItem(
                  value: AsrAcceleration.cpu,
                  child: Text('CPU · 优先兼容'),
                ),
                DropdownMenuItem(
                  value: AsrAcceleration.gpu,
                  child: Text('GPU / 硬件加速 · 失败回退 CPU'),
                ),
              ],
              onChanged: (value) => _act(() async {
                center.asrAccelerationOptions[model.id] = value!;
                center.asrBackendStatus.remove(model.id);
                await center.settingsChanged();
              }),
            ),
            const SizedBox(height: 8),
            const Text('无需先测速；硬件加速不可用时自动使用 CPU。'),
          ],
          if (advanced) ...[
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(status),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                DesktopButtonClickRegion(child: FilledButton.tonalIcon(
                  key: const ValueKey('asr-benchmark'),
                  onPressed:
                      center.installed(model.id) &&
                          _asrBenchmarkCancel == null &&
                          !_checking.contains(model.id)
                      ? () => _act(() => _benchmarkAsr(model))
                      : null,
                  icon: const Icon(Icons.speed),
                  label: Text(previous.isEmpty ? '本机测速' : '重新测速'),
                )),
                if (benchmarking)
                  DesktopButtonClickRegion(child: TextButton(
                    onPressed: () {
                      final cancel = _asrBenchmarkCancel;
                      if (cancel != null && !cancel.isCompleted) {
                        cancel.complete();
                      }
                    },
                    child: const Text('取消测速'),
                  )),
                DesktopButtonClickRegion(child: TextButton(
                  key: const ValueKey('asr-clear-benchmark'),
                  onPressed: benchmarking
                      ? null
                      : () => _act(() async {
                          center.clearAsrPerformance(model.id);
                          center.asrBackendStatus.remove(model.id);
                          await center.settingsChanged();
                        }),
                  child: const Text('清除测速记录'),
                )),
              ],
            ),
            if (pack != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '可选 GPU 权重 · ${modelBytes(pack.bytes)}\n${_modelStatus(pack)}；不替换原 CPU 模型',
                    ),
                  ),
                  ?_modelDownloadButton(pack),
                ],
              ),
              const Text(
                '现有权重也会先尝试加速。额外包只在用户下载后参与选择；下载包不保证此设备的 GPU 比 CPU 更快。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String get _segmentationLabel => switch (center.subtitleSegmentation.preset) {
    'natural' => '自然分句',
    'short' => '短句',
    'standard' => '标准分句',
    'original' => '保留语音段',
    _ => '自定义分句',
  };

  bool get _localAsr => center.asrProfile.local;
  bool get _localTranslation =>
      translation.providerEnZh == SubtitleTranslateProvider.local;
  bool get _aiTranslation =>
      translation.providerEnZh == SubtitleTranslateProvider.ai;

  String _providerLabel(SubtitleTranslateProvider provider) =>
      switch (provider) {
        SubtitleTranslateProvider.local => '应用内本地模型',
        SubtitleTranslateProvider.ai => 'AI 接口 / Ollama',
        _ => subtitleTranslateProviderLabels[provider]!,
      };

  ModelCenterChoice<String> _modelChoice(
    ModelArtifact model, {
    String? value,
  }) => ModelCenterChoice(
    value: value ?? model.id,
    title: model.name,
    group: '应用内本地模型',
    subtitle: modelLanguageSummary(model, compact: true),
    detail: '${_modelStatus(model)} · ${_downloadSizeSummary(model)}',
    actionLabel: center.installed(model.id)
        ? null
        : '${_modelDownloading(model) ? '查看下载' : '下载'} ${model.name}',
    actionIcon: _modelDownloading(model)
        ? Icons.downloading_rounded
        : Icons.download_outlined,
    actionKey: ValueKey('option-download-${model.id}'),
  );

  Future<void> _chooseAsr() async {
    final models = {
      for (final model in center.catalog)
        if (model.purpose == ModelPurpose.transcription)
          'local:${model.id}': model,
    };
    final result = await showModelCenterPicker<String>(
      context,
      title: '选择转录服务',
      selected: center.asrProfileId,
      choices: [
        for (final profile in center.profiles.values.where(
          (profile) => !profile.local,
        ))
          ModelCenterChoice(
            value: profile.id,
            title: profile.name,
            group: profile.kind == TranscriptionServiceKind.gongyi
                ? '在线服务'
                : '转录接口',
            subtitle: _asrLanguages(profile.id, models),
            detail: profile.kind == TranscriptionServiceKind.gongyi
                ? ''
                : profile.model,
          ),
        for (final entry in models.entries)
          _modelChoice(entry.value, value: entry.key),
      ],
    );
    if (result == null || !mounted) return;
    final model = models[result.value];
    if (result.action && model != null) {
      await _downloadFromFeatures(model);
      return;
    }
    if (model != null && _isQwenAsr(model) && _needsDownload(model)) {
      await _openModelDetails(model.id);
      return;
    }
    await _act(() async {
      if (model != null) {
        await center.selectAsr(model);
      } else {
        center.asrProfileId = result.value;
        await center.settingsChanged();
      }
    });
  }

  Future<void> _chooseTranslationProvider() async {
    final result = await showModelCenterPicker<SubtitleTranslateProvider>(
      context,
      title: '选择翻译服务',
      selected: translation.providerEnZh,
      searchable: false,
      choices: [
        for (final provider in SubtitleTranslateProvider.values)
          ModelCenterChoice(
            value: provider,
            title: _providerLabel(provider),
            group: switch (provider) {
              SubtitleTranslateProvider.ai => 'AI 接口',
              SubtitleTranslateProvider.local => '应用内本地模型',
              _ => '在线翻译',
            },
            subtitle: switch (provider) {
              SubtitleTranslateProvider.ai => '使用已配置的 AI 服务，包括本机或局域网 Ollama',
              SubtitleTranslateProvider.local => '下载模型，在应用内运行',
              _ => '通过在线服务翻译，无需下载模型',
            },
          ),
      ],
    );
    if (result != null && mounted) {
      await _act(() => translation.setProviderEnZh(result.value));
    }
  }

  Future<void> _chooseTranslationModel() async {
    final result = await showModelCenterPicker<String>(
      context,
      title: '选择本地翻译模型',
      selected: center.translationModelId,
      choices: [
        for (final model in center.catalog.where(
          (model) => model.purpose == ModelPurpose.translation,
        ))
          _modelChoice(model),
      ],
    );
    if (result == null || !mounted) return;
    final model = center.artifact(result.value);
    if (model == null) return;
    if (result.action) {
      await _downloadFromFeatures(model);
    } else {
      await _act(() async {
        center.translationModelId = model.id;
        await center.settingsChanged();
      });
    }
  }

  Future<void> _chooseLanguage() => _act(() async {
    await chooseTranscriptionLanguage(context, center, queueEnhancements: true);
  });

  Future<void> _chooseDirection() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      child: TranslationLanguageControls(settings: translation),
    ),
  );

  Future<void> _choosePunctuation() async {
    final result = await showModelCenterPicker<SubtitlePunctuation>(
      context,
      title: '生成字幕的标点',
      selected: center.subtitlePunctuation,
      searchable: false,
      choices: [
        for (final mode in SubtitlePunctuation.values)
          ModelCenterChoice(
            value: mode,
            title: mode.label,
            subtitle: mode.description,
            group: '',
          ),
      ],
    );
    if (result != null && mounted) {
      await _act(() async {
        center.subtitlePunctuation = result.value;
        await center.settingsChanged();
      });
    }
  }

  Widget _features() => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1000;
      final asr = _asrConfiguration();
      final translationCard = _translationConfiguration();
      final output = ModelCenterPanel(
        key: const ValueKey('model-center-output'),
        title: '字幕输出',
        icon: Icons.text_fields_rounded,
        children: [
          ModelCenterSetting(
            key: const ValueKey('model-center-punctuation'),
            label: '标点处理',
            value: center.subtitlePunctuation.label,
            onTap: _choosePunctuation,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '应用于原文和译文，对新建任务生效。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
      final device = _deviceConfiguration();
      final controller = _scrollFor(0);
      return Scrollbar(
        controller: controller,
        child: SingleChildScrollView(
          key: const PageStorageKey('model-center-features-scroll'),
          controller: controller,
          padding: EdgeInsets.all(wide ? 24 : 12),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.transcriptionOnly ? 860 : 1280,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _managementLinks(),
                  const SizedBox(height: 12),
                  if (wide && !widget.transcriptionOnly)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [asr, const SizedBox(height: 12), output],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            children: [
                              translationCard,
                              const SizedBox(height: 12),
                              device,
                            ],
                          ),
                        ),
                      ],
                    )
                  else ...[
                    asr,
                    if (!widget.transcriptionOnly) ...[
                      const SizedBox(height: 12),
                      translationCard,
                    ],
                    const SizedBox(height: 12),
                    output,
                    if (!widget.transcriptionOnly) ...[
                      const SizedBox(height: 12),
                      device,
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _asrConfiguration() {
    final model = _localAsr ? center.artifact(center.asrProfile.model) : null;
    final languages = _asrLanguages(center.asrProfileId, {
      for (final item in center.catalog) 'local:${item.id}': item,
    });
    return ModelCenterPanel(
      key: const ValueKey('model-center-asr'),
      title: '字幕转录',
      icon: Icons.subtitles_outlined,
      trailing: ModelCenterStatus(_localAsr ? '应用内本地' : '在线 / 接口'),
      children: [
        ModelCenterSetting(
          key: ValueKey('asr-binding-${center.asrProfileId}'),
          label: '默认转录服务',
          value: center.asrProfile.name,
          onTap: _chooseAsr,
          trailing: _modelDownloadButton(model),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            model == null ? languages : '${_modelStatus(model)} · $languages',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (model != null && _isQwenAsr(model) && _needsDownload(model))
          DesktopButtonClickRegion(child: TextButton(
            key: const ValueKey('asr-missing-components'),
            onPressed: () => _openModelDetails(model.id),
            child: const Text('查看所需增强组件与总下载大小'),
          )),
        const SizedBox(height: 8),
        ModelCenterSetting(
          key: const ValueKey('model-center-audio-language'),
          label: '音频语言',
          value: center.currentAsrLanguageOptions.label(
            center.effectiveAsrLanguage,
          ),
          onTap: center.currentAsrLanguageOptions.editable
              ? _chooseLanguage
              : null,
        ),
        if (_localAsr)
          ListTile(
            key: const PageStorageKey('local-asr-settings'),
            contentPadding: EdgeInsets.zero,
            title: const Text('本地转录设置'),
            subtitle: Text(
              '${_performanceSummary(true)} · $_segmentationLabel',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openLocalSettings(true),
          ),
        if (!_localAsr &&
            center.asrProfile.kind != TranscriptionServiceKind.gongyi)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButtonClickRegion(child: TextButton.icon(
              key: const ValueKey('model-center-edit-asr'),
              onPressed: () => _act(() => _editService(center.asrProfile)),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('配置当前接口'),
            )),
          ),
      ],
    );
  }

  Widget _translationConfiguration() {
    final model = _localTranslation
        ? center.artifact(center.translationModelId)
        : null;
    return ModelCenterPanel(
      key: const ValueKey('model-center-translation'),
      title: '字幕翻译',
      icon: Icons.translate_rounded,
      trailing: ModelCenterStatus(
        _localTranslation
            ? '应用内本地'
            : _aiTranslation
            ? 'AI 接口'
            : '在线翻译',
      ),
      children: [
        ModelCenterSetting(
          key: ValueKey('translation-${translation.providerEnZh}'),
          label: '默认翻译服务',
          value: _providerLabel(translation.providerEnZh),
          onTap: _chooseTranslationProvider,
        ),
        if (_localTranslation) ...[
          const SizedBox(height: 8),
          ModelCenterSetting(
            key: ValueKey('translation-model-${center.translationModelId}'),
            label: '翻译模型${model == null ? '' : ' · ${_modelStatus(model)}'}',
            value: model?.name ?? '请选择模型',
            onTap: _chooseTranslationModel,
            trailing: _modelDownloadButton(model),
          ),
        ],
        if (_aiTranslation) ...[
          const SizedBox(height: 8),
          ModelCenterSetting(
            key: const ValueKey('model-center-ai-binding'),
            label: '当前 AI 接口与模型',
            value: translation.binding.label,
            onTap: () => _act(_translationEndpoint),
          ),
        ],
        const SizedBox(height: 8),
        ModelCenterSetting(
          key: const ValueKey('model-center-translation-direction'),
          label: '翻译语言',
          value: translation.languageSummary,
          onTap: _chooseDirection,
        ),
        if (_localTranslation)
          ListTile(
            key: const PageStorageKey('local-translation-settings'),
            contentPadding: EdgeInsets.zero,
            title: const Text('本地翻译设置'),
            subtitle: Text('${_performanceSummary(false)} · 术语与性能'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openLocalSettings(false),
          ),
        if (_aiTranslation)
          ExpansionTile(
            key: const PageStorageKey('ai-translation-settings'),
            tilePadding: EdgeInsets.zero,
            title: const Text('AI 翻译设置'),
            subtitle: const Text('术语、批次与并发数'),
            children: [
              _terminologyField(),
              _field(
                CapsuleDropdownButtonFormField<int>(
                  key: ValueKey('ai-batch-${translation.aiOptions.batchSize}'),
                  initialValue: translation.aiOptions.batchSize,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '每批字幕条数',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final count
                        in AiSubtitleTranslationSettings.batchChoices)
                      DropdownMenuItem(value: count, child: Text('$count 条')),
                  ],
                  onChanged: (value) => _act(
                    () => translation.setAiOptions(
                      translation.aiOptions.copyWith(batchSize: value),
                    ),
                  ),
                ),
              ),
              _field(
                CapsuleDropdownButtonFormField<int>(
                  key: ValueKey(
                    'ai-threads-${translation.aiOptions.threadNum}',
                  ),
                  initialValue: translation.aiOptions.threadNum,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '并发请求数',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final count
                        in AiSubtitleTranslationSettings.threadChoices)
                      DropdownMenuItem(value: count, child: Text('$count')),
                  ],
                  onChanged: (value) => _act(
                    () => translation.setAiOptions(
                      translation.aiOptions.copyWith(threadNum: value),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
      ],
    );
  }

  Widget _terminologyField({bool local = false}) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: const ValueKey('model-center-terminology'),
      controller: terminology,
      focusNode: local ? _localTerminologyFocus : terminologyFocus,
      scrollController: local ? _localTerminologyScroll : terminologyScroll,
      minLines: 2,
      maxLines: 4,
      decoration: const InputDecoration(
        labelText: '术语与翻译要求',
        hintText: '例如：将 subtitle 统一译为“字幕”',
        border: OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      onChanged: (value) => unawaited(
        translation.setAiOptions(
          translation.aiOptions.copyWith(customPrompt: value),
        ),
      ),
    ),
  );

  Widget _deviceConfiguration() => ModelCenterPanel(
    key: const ValueKey('model-center-device'),
    title: '本机推荐',
    icon: Icons.devices_rounded,
    children: [
      _deviceRecommendation(),
      ExpansionTile(
        key: const PageStorageKey('model-center-device-settings'),
        tilePadding: EdgeInsets.zero,
        title: const Text('设备详情与推荐模型'),
        children: [
          FutureBuilder<ModelDeviceInfo>(
            future: deviceInfo,
            builder: (_, snapshot) {
              final info = snapshot.data;
              if (info == null) return const Text('正在读取设备资源…');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${info.memoryGb == null ? '未能读取物理内存' : '物理内存约 ${info.memoryGb} GB'} · ${info.processors} 个逻辑核心',
                  ),
                  for (final model in info.recommend(
                    center.catalog,
                    center.effectiveAsrLanguage,
                  ))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(model.name),
                      subtitle: Text(
                        '${model.purpose == ModelPurpose.transcription ? '转录' : '翻译'} · ${modelBytes(model.bytes)}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openModelDetails(model.id),
                    ),
                  const Text('建议基于设备内存；实际速度与可用性可安装后通过本机检查确认。'),
                ],
              );
            },
          ),
        ],
      ),
    ],
  );

  Widget _asrPerformanceControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _asrAccelerationControls(),
      ExpansionTile(
        key: const PageStorageKey('local-asr-performance'),
        initiallyExpanded: center.expandedPerformanceSections.contains('asr'),
        onExpansionChanged: (expanded) =>
            _rememberPerformanceExpansion(true, expanded),
        tilePadding: EdgeInsets.zero,
        title: const Text('高级设置'),
        subtitle: const Text('处理方式、线程与测速'),
        children: [
          _field(
            CapsuleDropdownButtonFormField<AsrExecutionMode>(
              key: const ValueKey('asr-execution-mode'),
              initialValue: center.asrExecution == AsrExecutionMode.lowMemory
                  ? AsrExecutionMode.lowMemory
                  : AsrExecutionMode.auto,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '处理方式',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: AsrExecutionMode.auto,
                  child: Text('流水线 · 推荐'),
                ),
                DropdownMenuItem(
                  value: AsrExecutionMode.lowMemory,
                  child: Text('省内存 · 顺序处理'),
                ),
              ],
              onChanged: (value) => _act(() async {
                center.asrExecution = value!;
                await center.settingsChanged();
              }),
            ),
          ),
          const Text('流水线会提前处理下一段音频；内存不足时自动缩小缓冲。'),
          _field(
            CapsuleDropdownButtonFormField<int>(
              key: ValueKey('asr-cpu-${center.asrCpuThreads}'),
              initialValue: center.asrCpuThreads,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '识别线程上限',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: 0, child: Text('自动 · 推荐')),
                for (var i = 1; i <= 12; i++)
                  DropdownMenuItem(value: i, child: Text('$i 个线程 · 上限')),
              ],
              onChanged: (value) => _act(() async {
                center.asrCpuThreads = value!;
                await center.settingsChanged();
              }),
            ),
          ),
          const Text('线程是计算用量，不是流水线数量；无需设成核心数。'),
          _asrAccelerationControls(advanced: true),
          _tuningReset(true),
        ],
      ),
    ],
  );

  Widget _translationPerformanceControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _field(
        CapsuleDropdownButtonFormField<TranslationAcceleration>(
          key: const ValueKey('local-translation-acceleration'),
          initialValue: center.translationOptions.acceleration,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '计算方式',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
              value: TranslationAcceleration.auto,
              child: Text('自动选择 · 推荐'),
            ),
            const DropdownMenuItem(
              value: TranslationAcceleration.cpu,
              child: Text('CPU · 兼容模式'),
            ),
            DropdownMenuItem(
              value: TranslationAcceleration.gpu,
              child: Text(
                Platform.isAndroid ? '优先 GPU · 试验' : '优先 GPU · 失败回退 CPU',
              ),
            ),
          ],
          onChanged: (value) => _act(() async {
            center.translationOptions = center.translationOptions.copyWith(
              acceleration: value!,
            );
            await center.settingsChanged();
          }),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          Platform.isAndroid
              ? '自动沿用本机测速结果；GPU 在独立进程中运行，异常会回退 CPU。'
              : '自动选择本机已验证的计算方式，无需先测速。',
        ),
      ),
      ExpansionTile(
        key: const PageStorageKey('translation-advanced-settings'),
        initiallyExpanded: center.expandedPerformanceSections.contains(
          'translation',
        ),
        onExpansionChanged: (expanded) =>
            _rememberPerformanceExpansion(false, expanded),
        tilePadding: EdgeInsets.zero,
        title: const Text('高级设置'),
        subtitle: const Text('线程、GPU 层数和字幕批次'),
        children: [
          _field(
            CapsuleDropdownButtonFormField<String>(
              key: ValueKey(
                'translation-backend-${center.translationOptions.backend}',
              ),
              initialValue: center.translationOptions.backend,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'GPU 加速路线',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('系统推荐 · 推荐')),
                for (final backend in {
                  if (Platform.isAndroid) ...['opencl', 'vulkan'],
                  if (Platform.isWindows || Platform.isLinux) ...[
                    'cuda',
                    'vulkan',
                  ],
                  if (Platform.isIOS || Platform.isMacOS) 'metal',
                  if (center.translationOptions.backend != 'auto')
                    center.translationOptions.backend,
                })
                  DropdownMenuItem(
                    value: backend,
                    child: Text(switch (backend) {
                      'cuda' => 'CUDA · NVIDIA 显卡',
                      'opencl' => 'OpenCL · 手机 GPU',
                      'metal' => 'Metal · Apple GPU',
                      _ => 'Vulkan · 通用 GPU',
                    }),
                  ),
              ],
              onChanged:
                  center.translationOptions.acceleration ==
                      TranslationAcceleration.cpu
                  ? null
                  : (value) => _act(() async {
                      center.translationOptions = center.translationOptions
                          .copyWith(backend: value);
                      center.translationPerformance.remove(
                        center.translationModelId,
                      );
                      await center.settingsChanged();
                    }),
            ),
          ),
          if (center.translationPerformance[center.translationModelId]
              case final profile?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                profile.summary,
                key: const ValueKey('translation-performance-result'),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DesktopButtonClickRegion(child: OutlinedButton.icon(
                key: const ValueKey('translation-benchmark'),
                onPressed:
                    _translationBenchmarkCancel != null ||
                        center.hasModelLeases ||
                        !center.installed(center.translationModelId)
                    ? null
                    : () => _act(_benchmarkTranslation),
                icon: const Icon(Icons.speed_rounded, size: 18),
                label: const Text('本机测速'),
              )),
              if (_translationBenchmarkCancel != null)
                DesktopButtonClickRegion(child: TextButton(
                  onPressed: () {
                    final cancel = _translationBenchmarkCancel;
                    if (cancel != null && !cancel.isCompleted) {
                      cancel.complete();
                    }
                  },
                  child: const Text('取消测速'),
                )),
            ],
          ),
          if (_translationBenchmarkActivity != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_translationBenchmarkActivity!),
            ),
          _field(
            CapsuleDropdownButtonFormField<int>(
              key: const ValueKey('local-translation-gpu-layers'),
              initialValue: center.translationOptions.gpuLayers,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'GPU 卸载层数',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final layers in <int>{
                  999,
                  8,
                  16,
                  24,
                  32,
                  center.translationOptions.gpuLayers,
                })
                  DropdownMenuItem(
                    value: layers,
                    child: Text(layers == 999 ? '全部层 · 默认' : '$layers 层'),
                  ),
              ],
              onChanged: (value) => _act(() async {
                center.translationOptions = center.translationOptions.copyWith(
                  gpuLayers: value!,
                );
                await center.settingsChanged();
              }),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text('显存不足时可减少 GPU 层数，剩余层由 CPU 计算；线程和批次越大不一定越快。'),
          ),
          _field(
            CapsuleDropdownButtonFormField<int>(
              initialValue: center.translationOptions.threads,
              key: const ValueKey('local-translation-threads'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '翻译线程上限',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: 0, child: Text('自动 · 推荐')),
                for (var i = 1; i <= 12; i++)
                  DropdownMenuItem(value: i, child: Text('$i 个线程')),
              ],
              onChanged: (value) => _act(() async {
                center.translationOptions = center.translationOptions.copyWith(
                  threads: value!,
                );
                await center.settingsChanged();
              }),
            ),
          ),
          _field(
            CapsuleDropdownButtonFormField<int>(
              initialValue: center.translationOptions.batchSize,
              key: const ValueKey('local-translation-batch-size'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '每批字幕数',
                border: OutlineInputBorder(),
              ),
              items: [
                for (var i = 1; i <= 12; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text('$i 条${i == 8 ? ' · 推荐起点' : ''}'),
                  ),
              ],
              onChanged: (value) => _act(() async {
                center.translationOptions = center.translationOptions.copyWith(
                  batchSize: value!,
                );
                await center.settingsChanged();
              }),
            ),
          ),
          _tuningReset(false),
        ],
      ),
      const Text('长字幕自动缩小批次；已完成的译文会保留。'),
    ],
  );

  Widget _resourceControls({required bool asr}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ValueListenableBuilder<InferenceBudgetDecision?>(
        valueListenable: DeviceResourceMonitor.instance.budget,
        builder: (context, budget, _) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            budget == null
                ? '任务开始后显示实际分配。'
                : asr
                ? '当前分配：识别 ${budget.activeAsrThreads} · 辅助 ${budget.activeAuxiliaryThreads} 个线程\n${budget.reason}'
                : '当前分配：翻译 ${budget.activeTranslationThreads} 个线程\n${budget.reason}',
            key: const ValueKey('inference-actual-budget'),
          ),
        ),
      ),
    ],
  );

  Widget _tuningReset(bool asr) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: DesktopButtonClickRegion(child: TextButton.icon(
          key: const ValueKey('clear-inference-tuning'),
          onPressed: center.hasModelLeases
              ? null
              : () => _act(() async {
                  final id = asr
                      ? center.asrProfile.model
                      : center.translationModelId;
                  center.inferenceTuning.removeWhere(
                    (key, value) => key.startsWith('$id:'),
                  );
                  if (asr) {
                    center.clearAsrPerformance(id);
                    center.asrBackendStatus.remove(id);
                  } else {
                    center.translationPerformance.removeWhere(
                      (key, _) => key == id || key.startsWith('$id:'),
                    );
                  }
                  await center.settingsChanged();
                }),
          icon: const Icon(Icons.restart_alt),
          label: const Text('清除本机调优记录'),
        )),
      ),
      const Text('仅清除当前模型的本机性能记录。'),
    ],
  );

  Widget _models() {
    final query = center.search.toLowerCase();
    final models = center.catalog.where((model) {
      if (model.purpose == ModelPurpose.ocr) return false;
      final matchesQuery =
          query.isEmpty ||
          '${model.name} ${model.description} ${model.languages.join(' ')}'
              .toLowerCase()
              .contains(query);
      final matchesFilter =
          center.filter == 'all' ||
          center.filter == 'installed' && center.installed(model.id) ||
          center.filter == model.purpose.name;
      return matchesQuery && matchesFilter;
    }).toList();
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                key: const ValueKey('model-center-library-search'),
                controller: search,
                decoration: InputDecoration(
                  hintText: '搜索模型、语言或能力',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : DesktopButtonClickRegion(child: IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            search.clear();
                            center.search = '';
                            center.rememberView();
                            _changed();
                          },
                          icon: const Icon(Icons.clear_rounded),
                        )),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) {
                  center.search = value;
                  center.rememberView();
                  _changed();
                },
              ),
            ),
            SizedBox(
              height: MediaQuery.textScalerOf(context).scale(52),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final entry in const {
                    'all': '全部',
                    'transcription': '转录',
                    'translation': '翻译',
                    'enhancement': '增强包',
                    'acceleration': '加速包',
                    'installed': '已安装',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('model-center-filter-${entry.key}'),
                        label: Text(entry.value),
                        selected: center.filter == entry.key,
                        onSelected: (_) {
                          center.filter = entry.key;
                          center.rememberView();
                          _changed();
                        },
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: models.isEmpty
                  ? const Center(child: Text('没有符合条件的模型，请调整搜索或筛选。'))
                  : ListView.builder(
                      controller: _scrollFor(1),
                      key: const PageStorageKey('model-center-models'),
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      itemCount: models.length,
                      itemBuilder: (_, index) => _modelRow(models[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _purposeLabel(ModelArtifact model) => switch (model.purpose) {
    ModelPurpose.transcription => '语音转录',
    ModelPurpose.translation => '字幕翻译',
    ModelPurpose.enhancement => '转录增强包',
    ModelPurpose.acceleration => '硬件加速包',
    ModelPurpose.ocr => 'OCR 字幕',
  };

  bool _isDefaultModel(ModelArtifact model) => switch (model.purpose) {
    ModelPurpose.transcription =>
      _localAsr && center.asrProfile.model == model.id,
    ModelPurpose.translation =>
      _localTranslation && center.translationModelId == model.id,
    _ => false,
  };

  Widget _modelRow(ModelArtifact model) {
    final colors = Theme.of(context).colorScheme;
    final downloading = _modelDownloading(model);
    final state = center.downloads[model.id];
    return Card(
      key: ValueKey('model-library-${model.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: center.selectedModelId == model.id
              ? colors.primary
              : colors.outlineVariant.withValues(alpha: .45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openModelDetails(model.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              Icon(
                model.purpose == ModelPurpose.translation
                    ? Icons.translate_rounded
                    : model.purpose == ModelPurpose.transcription
                    ? Icons.subtitles_outlined
                    : Icons.extension_outlined,
                size: 22,
                color: colors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      modelLanguageSummary(model, compact: true),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_modelStatus(model)} · ${_downloadSizeSummary(model)}${_isDefaultModel(model) ? ' · 当前默认' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: state?.phase == ModelDownloadPhase.failed
                            ? colors.error
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    if (downloading) ...[
                      const SizedBox(height: 6),
                      ModelCenterProgress(
                        value: state?.phase == ModelDownloadPhase.downloading
                            ? (state!.received / model.bytes).clamp(0, 1)
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
              if (center.installed(model.id) &&
                  model.purpose != ModelPurpose.ocr &&
                  model.purpose != ModelPurpose.acceleration)
                DesktopButtonClickRegion(child: IconButton(
                  tooltip: '本机推理检查',
                  onPressed: _checking.contains(model.id)
                      ? null
                      : () => _act(() => _checkModel(model)),
                  icon: const Icon(Icons.play_circle_outline_rounded),
                ))
              else
                ?_modelDownloadButton(model),
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.chevron_right_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openModelDetails(
    String modelId, {
    bool download = false,
  }) async {
    if (_detailVisible || !mounted) return;
    _routeWork.cancel('initial-destination');
    _detailVisible = true;
    _detailError.value = null;
    center.selectedModelId = modelId;
    center.rememberView();
    final route = PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: '关闭模型详情',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (detailContext, _, _) => ListenableBuilder(
        listenable: Listenable.merge([center, translation, _detailError]),
        builder: (_, _) => LayoutBuilder(
          builder: (_, constraints) {
            final sidePanel = constraints.maxWidth >= 1000;
            final model = center.artifact(modelId);
            return Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: sidePanel ? 420 : constraints.maxWidth,
                child: Scaffold(
                  key: ValueKey('model-detail-$modelId'),
                  appBar: AppBar(
                    automaticallyImplyLeading: false,
                    leading: DesktopButtonClickRegion(child: IconButton(
                      key: const ValueKey('model-detail-close'),
                      tooltip: sidePanel ? '关闭详情' : '返回',
                      onPressed: () => Navigator.pop(detailContext),
                      icon: Icon(
                        sidePanel
                            ? Icons.close_rounded
                            : Icons.arrow_back_rounded,
                      ),
                    )),
                    title: Text(model?.name ?? '模型不可用'),
                    titleTextStyle: Theme.of(context).textTheme.titleMedium,
                  ),
                  body: SafeArea(
                    top: false,
                    child: model == null
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('此模型已不在当前模型库中，请返回选择其他模型。'),
                            ),
                          )
                        : _modelDetail(model, detailContext),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        ),
        child: child,
      ),
    );
    try {
      final closed = Navigator.of(context).push(route);
      final model = center.artifact(modelId);
      if (download && model != null) {
        unawaited(_detailAct(() => _enqueueModel(model)));
      }
      await closed;
    } finally {
      _detailVisible = false;
      if (mounted) _changed();
    }
  }

  Future<void> _detailAct(Future<void> Function() action) async {
    _detailError.value = null;
    try {
      await action();
    } catch (error) {
      if (mounted) _detailError.value = '$error';
    }
  }

  Widget _asrDownloadContents(
    ModelArtifact model,
    List<ModelArtifact> components, {
    required bool downloading,
  }) {
    final total = components.fold(0, (n, part) => n + part.bytes);
    final missing = components.where((part) => !center.installed(part.id));
    final completed = components.fold(
      0,
      (n, part) =>
          n +
          (center.installed(part.id)
              ? part.bytes
              : (center.downloads[part.id]?.received ?? 0).clamp(
                  0,
                  part.bytes,
                )),
    );
    final options = center.asrEnhancementsFor(model);
    String role(ModelArtifact part) => switch (part.id) {
      AsrEnhancementOptions.alignmentQwenId => '补充字幕时间戳，不改变识别文字',
      AsrEnhancementOptions.languageId => '自动语言模式下，必要时识别音频语言',
      AsrEnhancementOptions.denoiserId => '当前已开启轻量降噪',
      AsrEnhancementOptions.punctuationId => '当前已开启中英文标点恢复',
      _ => '主模型：识别语音文字',
    };
    return ModelCenterPanel(
      key: ValueKey('asr-download-contents-${model.id}'),
      title: '本次下载内容',
      icon: Icons.download_outlined,
      children: [
        Text(
          '完整组合 ${modelBytes(total)} · 未安装文件 ${modelBytes(missing.fold(0, (n, part) => n + part.bytes))}',
          key: const ValueKey('asr-download-total'),
        ),
        Text(
          model.engine == 'parakeet-ja'
              ? '默认保留原音并复用原生时间戳，只需主模型。手动启用降噪或每条精校时，所需组件列在下方。'
              : '以下按当前增强和语言设置列出所需组件，已安装的不重复下载。',
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('asr-download-alignment'),
          contentPadding: EdgeInsets.zero,
          title: const Text('声学时间精校（可选）'),
          subtitle: Text(
            model.engine == 'parakeet-ja'
                ? '默认复用模型自带的词块时间。开启“每条字幕都做声学精校”后，才需要共享精校模型。'
                : '关闭后不下载精校模型，保留语音段时间。此设置对新任务生效。',
          ),
          value: options.enabled && options.alignment,
          onChanged: !options.enabled || downloading
              ? null
              : (value) => _detailAct(() async {
                  center.updateAsrEnhancements(
                    options.copyWith(alignment: value),
                    model: model,
                  );
                  await center.settingsChanged();
                }),
        ),
        for (final part in components) ...[
          const Divider(height: 16),
          Text(part.name, style: Theme.of(context).textTheme.titleSmall),
          Text(role(part), style: Theme.of(context).textTheme.bodySmall),
          Text('${modelBytes(part.bytes)} · ${_modelStatus(part)}'),
          if (center.downloads[part.id]?.message.isNotEmpty == true)
            Text(center.downloads[part.id]!.message),
        ],
        if (downloading || completed > 0) ...[
          const SizedBox(height: 12),
          ModelCenterProgress(value: (completed / total).clamp(0, 1)),
          Text('组合进度 ${modelBytes(completed)} / ${modelBytes(total)}'),
        ],
      ],
    );
  }

  Widget _modelDetail(ModelArtifact model, BuildContext detailContext) {
    final state = center.downloads[model.id];
    final installed = center.installed(model.id);
    final downloading = _modelDownloading(model);
    final components = _downloadComponents(model);
    final missing = components.where((part) => !center.installed(part.id));
    final downloadingComponents = components.any(_modelDownloading);
    final downloadLabel = downloadingComponents
        ? model.purpose == ModelPurpose.transcription
              ? '正在下载模型与组件'
              : state!.label
        : components.any(
            (part) =>
                center.downloads[part.id]?.phase == ModelDownloadPhase.paused,
          )
        ? '继续下载'
        : components.any(
            (part) =>
                center.downloads[part.id]?.phase == ModelDownloadPhase.failed,
          )
        ? '重试下载'
        : _isQwenAsr(model)
        ? installed
              ? '下载缺失增强组件'
              : '下载模型及增强组件'
        : '下载模型';
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            key: PageStorageKey('model-detail-scroll-${model.id}'),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ModelCenterStatus(_purposeLabel(model)),
                    if (model.retired) const ModelCenterStatus('已下架 · 旧任务兼容'),
                    ModelCenterStatus(
                      _modelStatus(model),
                      error: state?.phase == ModelDownloadPhase.failed,
                    ),
                    if (_isDefaultModel(model)) const ModelCenterStatus('当前默认'),
                  ],
                ),
                if (_isQwenAsr(model)) ...[
                  const SizedBox(height: 16),
                  _asrDownloadContents(
                    model,
                    components,
                    downloading: downloadingComponents,
                  ),
                ],
                if (state != null) ...[
                  const SizedBox(height: 16),
                  if (downloading)
                    ModelCenterProgress(
                      value: state.phase == ModelDownloadPhase.downloading
                          ? (state.received / model.bytes).clamp(0, 1)
                          : null,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '${state.label} · ${modelBytes(state.received)} / ${modelBytes(model.bytes)}',
                    key: const ValueKey('model-detail-progress'),
                  ),
                  if (state.bytesPerSecond > 0)
                    Text(
                      '${modelBytes(state.bytesPerSecond.round())}/s',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (state.message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        state.message,
                        style: TextStyle(
                          color: state.phase == ModelDownloadPhase.failed
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                if (_detailError.value case final message?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      message,
                      key: const ValueKey('model-detail-error'),
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(model.description),
                const SizedBox(height: 12),
                Text(modelLanguageSummary(model, full: true)),
                const SizedBox(height: 12),
                Text(
                  '${_isQwenAsr(model) ? '主模型大小' : '下载大小'} ${modelBytes(model.bytes)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  model.memoryNote,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (center.diagnostics[model.id] case final message?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message),
                  ),
                const SizedBox(height: 16),
                ExpansionTile(
                  key: PageStorageKey('model-detail-tools-${model.id}'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('模型工具'),
                  subtitle: const Text('本机检查、文件校验与离线管理'),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (installed &&
                            model.purpose != ModelPurpose.ocr &&
                            model.purpose != ModelPurpose.acceleration)
                          DesktopButtonClickRegion(child: OutlinedButton.icon(
                            onPressed: _checking.contains(model.id)
                                ? null
                                : () => _detailAct(() => _checkModel(model)),
                            icon: const Icon(
                              Icons.play_circle_outline_rounded,
                              size: 18,
                            ),
                            label: Text(
                              _checking.contains(model.id) ? '正在检查…' : '本机推理检查',
                            ),
                          )),
                        if (installed)
                          DesktopButtonClickRegion(child: OutlinedButton(
                            onPressed: downloading
                                ? null
                                : () =>
                                      _detailAct(() => center.verify(model.id)),
                            child: const Text('手动校验文件'),
                          )),
                        DesktopButtonClickRegion(child: OutlinedButton(
                          onPressed: downloading
                              ? null
                              : () => _detailAct(() async {
                                  await (widget.directoryImporter ??
                                          OfflineModelDirectoryImporter())
                                      .importFiles(
                                        dialogTitle: '选择包含该模型固定版本文件的文件夹',
                                        files: OfflineModelImportFile.forArtifact(model),
                                        install: (directory) =>
                                            center.importFiles(model.id, directory),
                                      );
                                }),
                          child: const Text('离线导入'),
                        )),
                        DesktopButtonClickRegion(child: TextButton(
                          onPressed: () => _detailAct(() async {
                            await launchUrl(
                              Uri.parse(model.homepage),
                              mode: LaunchMode.externalApplication,
                            );
                          }),
                          child: const Text('官方资料'),
                        )),
                        if (state != null)
                          DesktopButtonClickRegion(child: TextButton(
                            onPressed: center.inUse(model.id)
                                ? null
                                : () => _detailAct(
                                    () => _removeModel(model, detailContext),
                                  ),
                            child: const Text('删除模型文件'),
                          )),
                      ],
                    ),
                    if (state?.checkedAt case final checked?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '文件检查：${checked.toLocal().toString().split('.').first}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
                ExpansionTile(
                  key: PageStorageKey('model-detail-files-${model.id}'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('技术信息与文件'),
                  subtitle: const Text('参数、版本、许可证及下载来源'),
                  children: [
                    _property('参数量', model.parameters),
                    _property('格式', model.quantization),
                    _property('许可证', model.license),
                    _property(
                      '平台',
                      'Android · iOS 16.4+\nmacOS 14+ · Windows · Linux',
                    ),
                    _property(
                      '运行时',
                      model.purpose == ModelPurpose.translation
                          ? 'llama.cpp · Metal / Vulkan / CPU'
                          : model.purpose == ModelPurpose.ocr
                          ? 'ONNX Runtime · CPU / 本机可用加速'
                          : model.purpose == ModelPurpose.enhancement
                          ? 'sherpa-onnx / ONNX Runtime · CPU'
                          : 'sherpa-onnx / ONNX Runtime · CPU / 可选硬件加速',
                    ),
                    _property('语言标签', model.languages.join(' · ')),
                    _property('版本', model.revision.substring(0, 12)),
                    for (final file in model.files)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '${file.name}\n${modelBytes(file.bytes)} · SHA-256 ${file.sha256.substring(0, 12)}…',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final source in file.sources.entries)
                                  DesktopButtonClickRegion(child: TextButton(
                                    onPressed: () => _detailAct(() async {
                                      await launchUrl(
                                        Uri.parse(source.value),
                                        mode: LaunchMode.externalApplication,
                                      );
                                    }),
                                    child: Text(modelSourceLabel(source.key)),
                                  )),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: model.retired
                    ? const DesktopButtonClickRegion(child:  FilledButton(onPressed: null, child: Text('模型已下架')))
                    : missing.isNotEmpty
                    ? DesktopButtonClickRegion(child: FilledButton.icon(
                        key: ValueKey('model-detail-download-${model.id}'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: downloadingComponents
                            ? null
                            : () => _detailAct(() => _enqueueModel(model)),
                        icon: Icon(
                          downloadingComponents
                              ? Icons.downloading_rounded
                              : Icons.download_outlined,
                          size: 20,
                        ),
                        label: Text(
                          downloadLabel,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                        ),
                      ))
                    : DesktopButtonClickRegion(child: FilledButton(
                        key: ValueKey('model-detail-default-${model.id}'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed:
                            _isDefaultModel(model) ||
                                (model.purpose != ModelPurpose.transcription &&
                                    model.purpose != ModelPurpose.translation)
                            ? null
                            : () => _detailAct(() async {
                                if (model.purpose ==
                                    ModelPurpose.transcription) {
                                  await center.selectAsr(model);
                                } else {
                                  center.translationModelId = model.id;
                                  await center.settingsChanged();
                                  await translation.setProviderEnZh(
                                    SubtitleTranslateProvider.local,
                                  );
                                }
                                if (detailContext.mounted) {
                                  Navigator.pop(detailContext);
                                }
                              }),
                        child: Text(
                          _isDefaultModel(model)
                              ? '当前默认模型'
                              : model.purpose == ModelPurpose.transcription
                              ? '设为默认转录'
                              : model.purpose == ModelPurpose.translation
                              ? '设为默认翻译'
                              : '已安装',
                        ),
                      )),
              ),
              if (downloadingComponents) ...[
                const SizedBox(width: 8),
                DesktopButtonClickRegion(child: OutlinedButton(
                  key: ValueKey('model-detail-pause-${model.id}'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: () => _detailAct(() async {
                    for (final part in components.where(_modelDownloading)) {
                      await center.pause(part.id);
                    }
                  }),
                  child: const Text('暂停'),
                )),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _removeModel(
    ModelArtifact model,
    BuildContext detailContext,
  ) async {
    final confirmed = await showDialog<bool>(
      context: detailContext,
      builder: (context) => AlertDialog(
        title: const Text('删除模型文件？'),
        content: const Text('已保存的配置会保留，重新下载后可继续使用。'),
        actions: [
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          )),
          DesktopButtonClickRegion(child: FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          )),
        ],
      ),
    );
    if (confirmed == true) await center.remove(model.id);
  }

  Widget _property(String title, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(title, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: SelectableText(
            value,
            key: PageStorageKey('model-property-$title'),
          ),
        ),
      ],
    ),
  );

  Widget _services() => _list([
    _card('转录服务', '选择转录服务，或添加自己的接口配置。', [
      for (final profile in center.profiles.values.where((e) => !e.local)) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(profile.name),
          subtitle: profile.kind == TranscriptionServiceKind.gongyi
              ? const Text('识别时上传本地音频，无需配置密钥。')
              : Text('${profile.model}\n${profile.endpoint}', maxLines: 3),
          trailing: profile.kind == TranscriptionServiceKind.gongyi
              ? null
              : DesktopButtonClickRegion(child: IconButton(
                  tooltip: '编辑服务',
                  onPressed: () => _act(() => _editService(profile)),
                  icon: const Icon(Icons.edit_outlined),
                )),
          onTap: profile.kind == TranscriptionServiceKind.gongyi
              ? null
              : () => _act(() => _editService(profile)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(child: TextButton.icon(
            onPressed: center.asrProfileId == profile.id
                  ? null
                : () => _act(() async {
                    center.asrProfileId = profile.id;
                    await center.settingsChanged();
                  }),
            icon: Icon(
              center.asrProfileId == profile.id
                  ? Icons.check_circle_outline_rounded
                  : Icons.check_rounded,
              size: 18,
            ),
            label: Text(
              center.asrProfileId == profile.id ? '当前默认转录' : '设为默认转录',
            ),
          )),
        ),
        if (profile.kind != TranscriptionServiceKind.gongyi) ...[
          if (center.diagnostics[profile.id] case final message?)
            Text(message, style: Theme.of(context).textTheme.bodySmall),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButtonClickRegion(child: TextButton.icon(
              onPressed: center.checking.contains(profile.id)
                  ? null
                  : () => _act(() => _checkService(profile)),
              icon: const Icon(Icons.network_check),
              label: Text(
                center.checking.contains(profile.id)
                    ? '正在检查…'
                    : '语音样本检查 · 约 11 秒用量',
              ),
            )),
          ),
        ],
      ],
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final provider in CloudAsrProvider.values)
            DesktopButtonClickRegion(child: OutlinedButton.icon(
              onPressed: () => _act(() => _editService(null,
                kind: TranscriptionServiceKind.values.byName(provider.name))),
              icon: const Icon(Icons.add), label: Text(provider.label))),
          DesktopButtonClickRegion(child: OutlinedButton.icon(
            onPressed: () => _act(
              () => _editService(null, kind: TranscriptionServiceKind.openai),
            ),
            icon: const Icon(Icons.add),
            label: const Text('兼容转录接口'),
          )),
        ],
      ),
      const SizedBox(height: 10),
      const Text(
        '样本检查会向所选平台上传内置英语样本，并按平台规则产生少量用量，用于验证鉴权、上传和字幕时间轴。请选择支持英语的引擎。',
        style: TextStyle(fontSize: 12),
      ),
    ], icon: Icons.cloud_outlined),
    _card('AI 翻译接口', '连接云端 AI、Ollama 或局域网兼容服务。', [
      Text(
        translation.binding.api?.model.isNotEmpty == true
            ? translation.binding.label
            : '配置接口后可为每个模型记住翻译语言。',
      ),
      const SizedBox(height: 10),
      DesktopButtonClickRegion(child: FilledButton.tonal(
        onPressed: () => _act(_translationEndpoint),
        child: const Text('配置接口与检查连接'),
      )),
    ], icon: Icons.api),
  ], section: 2);

  Widget _downloadSettings() => ModelCenterPanel(
    title: '下载设置',
    icon: Icons.tune_rounded,
    children: [
      ExpansionTile(
        key: const PageStorageKey('model-center-download-settings'),
        tilePadding: EdgeInsets.zero,
        title: const Text('下载来源'),
        subtitle: Text(
          const {
                'auto': '自动测速 · 推荐',
                'official': '优先 Hugging Face',
                'mainland': '优先国内源 · ModelScope',
                'mirror': '优先 HF Mirror',
                'mirror_proxy': '优先 HF Mirror.net',
              }[center.sourcePreference] ??
              '自动测速 · 推荐',
        ),
        children: [
          CapsuleDropdownButtonFormField<String>(
            key: ValueKey('model-download-source-${center.sourcePreference}'),
            initialValue: center.sourcePreference,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '优先来源',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('自动测速 · 推荐')),
              DropdownMenuItem(value: 'official', child: Text('Hugging Face')),
              DropdownMenuItem(
                value: 'mainland',
                child: Text('国内源 · ModelScope'),
              ),
              DropdownMenuItem(
                value: 'mirror',
                child: Text('HF Mirror · 第三方镜像'),
              ),
              DropdownMenuItem(
                value: 'mirror_proxy',
                child: Text('HF Mirror.net · 第三方镜像'),
              ),
            ],
            onChanged: (value) => _act(() async {
              center.sourcePreference = value!;
              await center.settingsChanged();
            }),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('自动比较各来源的实际速度；优先来源失败或持续过慢时尝试其他来源。'),
          ),
        ],
      ),
    ],
  );

  Widget _tasks(TranscriptionManager? asr) {
    final entries = center.downloads.values.toList()
      ..sort((a, b) {
        int rank(ModelDownload state) => switch (state.phase) {
          ModelDownloadPhase.downloading || ModelDownloadPhase.verifying => 0,
          ModelDownloadPhase.queued => 1,
          ModelDownloadPhase.failed => 2,
          ModelDownloadPhase.paused => 3,
          ModelDownloadPhase.installed => 4,
        };
        return rank(a).compareTo(rank(b));
      });
    return _list([
      _downloadSettings(),
      const Text('离开页面后下载继续，手动暂停的任务需要点击继续。'),
      if (asr?.isProcessing == true)
        _card('正在转录', asr!.statusMessage, [
          ModelCenterProgress(value: asr.progress),
        ]),
      ListenableBuilder(
        listenable: SubtitleTranslationService.instance,
        builder: (_, _) {
          final service = SubtitleTranslationService.instance;
          return service.isTranslating
              ? _card('正在翻译', service.activity ?? '正在处理字幕', [
                  ModelCenterProgress(value: service.progress),
                ])
              : const SizedBox.shrink();
        },
      ),
      if (entries.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('暂无模型下载任务')),
        ),
      for (final state in entries)
        if (center.artifact(state.artifactId) case final model?)
          _card(
            model.name,
            '${state.label} · ${modelBytes(state.received)} / ${modelBytes(model.bytes)}',
            [
              if (state.phase == ModelDownloadPhase.downloading ||
                  state.phase == ModelDownloadPhase.verifying)
                ModelCenterProgress(
                  value: state.phase == ModelDownloadPhase.verifying
                      ? null
                      : (state.received / model.bytes).clamp(0, 1),
                ),
              if (state.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(state.message),
                ),
              if (state.bytesPerSecond > 0)
                Text(
                  '${modelBytes(state.bytesPerSecond.round())}/s · 约 ${((model.bytes - state.received) / state.bytesPerSecond / 60).ceil()} 分钟',
                ),
              Wrap(
                spacing: 8,
                children: [
                  if (const [
                    ModelDownloadPhase.queued,
                    ModelDownloadPhase.downloading,
                    ModelDownloadPhase.verifying,
                  ].contains(state.phase))
                    DesktopButtonClickRegion(child: TextButton(
                      onPressed: () => _act(() => center.pause(model.id)),
                      child: const Text('暂停'),
                    )),
                  if (!model.retired &&
                      (state.phase == ModelDownloadPhase.paused ||
                          state.phase == ModelDownloadPhase.failed))
                    DesktopButtonClickRegion(child: TextButton(
                      onPressed: () => _act(() => center.enqueue(model.id)),
                      child: Text(state.phase == ModelDownloadPhase.failed ? '重试下载' : '继续下载'),
                    )),
                  DesktopButtonClickRegion(child: TextButton(
                    onPressed: () => _openModelDetails(model.id),
                    child: const Text('模型详情'),
                  )),
                ],
              ),
            ],
            icon: Icons.downloading_rounded,
          ),
    ], section: 3);
  }

  Future<void> _translationEndpoint() async {
    final store = AiSubtitleApiSettingsStore();
    final settings = await store.load();
    if (!mounted) return;
    final result = await showDialog<AiSubtitleApiSettings>(
      context: context,
      builder: (_) => AiSubtitleApiDialog(settings: settings),
    );
    if (result != null) {
      await store.save(result);
      if (mounted) {
        translation.notifyApiChanged();
      }
    }
  }

  Future<void> _checkService(ModelServiceProfile profile) async {
    if (!center.checking.add(profile.id)) return;
    await center.settingsChanged();
    final watch = Stopwatch()..start();
    try {
      final cues = await ModelTranscriptionRunner(center: center).run(
        spec: ModelJobSpec(profile: profile),
        sourceIdentity:
            'service-probe:${profile.id}:${DateTime.now().microsecondsSinceEpoch}',
        duration: const Duration(seconds: 11),
        prepareAudio: (_, _, _, _) async {
          final asset = await rootBundle.load(
            'assets/models/asr/speech_probe.wav',
          );
          final file = File(
            p.join(
              (await center.storage.featureDirectory('model_jobs')).path,
              'service-probe-${DateTime.now().microsecondsSinceEpoch}.wav',
            ),
          );
          await file.writeAsBytes(
            asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
            flush: true,
          );
          return file.path;
        },
        onProgress: (event) {
          center.updateDiagnostic(profile.id, event.message);
        },
      );
      if (cues.isEmpty) throw StateError('样本未返回字幕，请检查所选引擎的语言');
      center.diagnostics[profile.id] =
          '样本检查通过 · ${watch.elapsedMilliseconds} ms\n${cues.map((e) => e.text).join(' ')}';
    } catch (error) {
      center.diagnostics[profile.id] = '样本检查失败：$error';
      rethrow;
    } finally {
      center.checking.remove(profile.id);
      await center.settingsChanged();
    }
  }

  Future<void> _editService(
    ModelServiceProfile? profile, {
    TranscriptionServiceKind? kind,
  }) async {
    final secret = profile == null ? '' : await center.readSecret(profile.id);
    if (!mounted) return;
    final selectedKind = kind ?? profile!.kind;
    final provider = CloudAsrProvider.values.where((p) => p.name == selectedKind.name).firstOrNull;
    final Widget editor = provider != null ? CloudAsrEditor(center: center,
      provider: provider, profile: profile, secret: secret) : _ServiceEditor(
      profile: profile,
      kind: selectedKind,
      secret: secret,
    );
    final result = MediaQuery.sizeOf(context).width < 600
        ? await Navigator.of(context).push<(ModelServiceProfile, String)>(
            MaterialPageRoute(builder: (_) => editor),
          )
        : await showDialog<(ModelServiceProfile, String)>(
            context: context,
            builder: (_) => editor,
          );
    if (result != null) {
      await center.saveProfile(result.$1, secret: result.$2);
    }
  }

  Future<void> _checkModel(ModelArtifact model) async {
    if (model.purpose == ModelPurpose.ocr) {
      throw StateError('请在 OCR 字幕页面选择完整模型组合后识别');
    }
    if (model.purpose == ModelPurpose.acceleration) {
      throw StateError('请在“模型中心 → 本地转录设置 → 性能”中进行本机测速');
    }
    _checking.add(model.id);
    await center.settingsChanged();
    final watch = Stopwatch()..start();
    try {
      if (model.purpose == ModelPurpose.translation) {
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'check',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
          ),
          artifactIdentity: model.identity,
          threads: center.threads,
          translation: center.translationOptionsFor(model.id),
        );
        LocalTranslationMetrics? metrics;
        final result = await LocalSubtitleTranslator(center: center).translate(
          texts: const ['Hello, welcome.', 'The next train leaves at seven.'],
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          onProgress: (_) {},
          specification: spec,
          resume: false,
          onMetrics: (value) => metrics = value,
        );
        if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(result.first)) {
          throw StateError('模型未返回中文测试译文');
        }
        center.diagnostics[model.id] =
            '本机翻译通过 · ${metrics?.backend ?? 'CPU'} · ${watch.elapsed.inMilliseconds} ms\n${result.join('\n')}';
      } else if (model.purpose == ModelPurpose.enhancement) {
        final message = await InferenceScheduler.instance.run(
          () => center.usingModel(model.id, (model, dir) async {
            final directories = <String, String>{model.id: dir.path};
            final sample = await rootBundle.load(
              'assets/models/asr/speech_probe_zh.wav',
            );
            final audio = decodeModelWave(
              sample.buffer.asUint8List(
                sample.offsetInBytes,
                sample.lengthInBytes,
              ),
            );
            final resources = InferenceResourceSession.current!;
            return resources.run(InferenceLane.auxiliary, (permit) async {
              await resources.checkAllocation(
                model.engine == 'qwen3-alignment'
                    ? qwenAudioWorkingSetBytes(model.bytes)
                    : model.bytes * 3,
                permit: permit,
              );
              return probeAsrEnhancement(
                model.engine,
                directories,
                audio,
                threads: permit.threads,
              );
            });
          }),
        );
        center.diagnostics[model.id] =
            '本机增强推理通过 · ${watch.elapsedMilliseconds} ms\n$message';
      } else {
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'check',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
          ),
          artifactIdentity: model.identity,
        );
        final vad = await center.prepareAsrVad(
          onProgress: (message) => center.updateDiagnostic(model.id, message),
        );
        await InferenceScheduler.instance.run(
          () => center.usingAsrModels(spec, (model, dir, _) async {
            final wave = File(
              p.join(
                (await center.storage.featureDirectory('model_jobs')).path,
                'probe-${model.id}.wav',
              ),
            );
            final speech = await rootBundle.load(
              localAsrProbeAsset(model.engine, model.languages),
            );
            await wave.writeAsBytes(
              speech.buffer.asUint8List(
                speech.offsetInBytes,
                speech.lengthInBytes,
              ),
              flush: true,
            );
            final resources = InferenceResourceSession.current!;
            resources.asrMaximum = center.asrCpuThreads;
            resources.pipelineRequested = false;
            final worker = LocalAsrWorker()
              ..configureResources(resources, modelBytes: model.bytes);
            try {
              await worker.start(
                engine: model.engine,
                directory: dir.path,
                vadPath: vad.path,
                language: 'auto',
                threads: resources.decision.asrThreads,
              );
              final cues = await worker.recognize(wave.path);
              if (cues.isEmpty) throw StateError('语音样本未返回识别结果');
              center.diagnostics[model.id] =
                  '本机语音识别通过 · ${watch.elapsed.inMilliseconds} ms\n'
                  '${cues.map((e) => e.text).join(' ')}\n'
                  '含模型加载和短样本推理耗时；长音频速度以实际任务为准。';
            } finally {
              await worker.close();
              if (await wave.exists()) await wave.delete();
            }
          }),
        );
      }
      await center.settingsChanged();
    } catch (error) {
      center.diagnostics[model.id] = '本机检查失败：$error';
      await center.settingsChanged();
      rethrow;
    } finally {
      _checking.remove(model.id);
      await center.settingsChanged();
    }
  }
}

class _ServiceEditor extends StatefulWidget {
  const _ServiceEditor({
    required this.profile,
    required this.kind,
    required this.secret,
  });
  final ModelServiceProfile? profile;
  final TranscriptionServiceKind kind;
  final String secret;
  @override
  State<_ServiceEditor> createState() => _ServiceEditorState();
}

class _ServiceEditorState extends State<_ServiceEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text:
        widget.profile?.name ??
        switch (widget.kind) {
          TranscriptionServiceKind.tencent => '腾讯云极速版',
          TranscriptionServiceKind.aliyun => '阿里云百炼',
          _ => '兼容转录接口',
        },
  );
  late final endpoint = TextEditingController(
    text:
        widget.profile?.endpoint ??
        (widget.kind == TranscriptionServiceKind.aliyun
            ? 'https://dashscope.aliyuncs.com'
            : 'http://localhost:8080/v1/audio/transcriptions'),
  );
  late final model = TextEditingController(
    text:
        widget.profile?.model ??
        switch (widget.kind) {
          TranscriptionServiceKind.tencent => '16k_zh_en',
          TranscriptionServiceKind.aliyun => 'fun-asr',
          _ => '',
        },
  );
  late final appId = TextEditingController(text: widget.profile?.appId ?? '');
  late final key = TextEditingController(
    text: widget.kind == TranscriptionServiceKind.tencent
        ? _tencentKey('secretKey')
        : widget.secret,
  );
  late final secretId = TextEditingController(text: _tencentKey('secretId'));
  String _tencentKey(String field) {
    try {
      return (jsonDecode(widget.secret) as Map)[field] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  void dispose() {
    for (final controller in [name, endpoint, model, appId, key, secretId]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!form.currentState!.validate()) return;
    if (widget.kind != TranscriptionServiceKind.tencent) {
      final uri = Uri.tryParse(endpoint.text.trim());
      if (uri == null ||
          !uri.hasAuthority ||
          !{'http', 'https'}.contains(uri.scheme)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请填写有效的 HTTP / HTTPS 地址')));
        return;
      }
    }
    final profile = ModelServiceProfile(
      id:
          widget.profile?.id ??
          'service-${DateTime.now().microsecondsSinceEpoch}',
      name: name.text.trim(),
      kind: widget.kind,
      endpoint: endpoint.text.trim(),
      model: model.text.trim(),
      appId: appId.text.trim(),
    );
    Navigator.pop(context, (
      profile,
      widget.kind == TranscriptionServiceKind.tencent
          ? jsonEncode({
              'secretId': secretId.text.trim(),
              'secretKey': key.text.trim(),
            })
          : key.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final fields = Form(
      key: form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _input(name, '服务名称'),
            if (widget.kind != TranscriptionServiceKind.tencent)
              _input(
                endpoint,
                widget.kind == TranscriptionServiceKind.aliyun
                    ? '服务根地址'
                    : '完整转录接口地址',
              ),
            _input(model, '模型 / 引擎名称'),
            if (widget.kind == TranscriptionServiceKind.tencent) ...[
              _input(appId, 'AppID'),
              _input(secretId, 'SecretID'),
            ],
            _input(
              key,
              widget.kind == TranscriptionServiceKind.tencent
                  ? 'SecretKey'
                  : widget.kind == TranscriptionServiceKind.openai
                  ? 'API Key（可留空）'
                  : 'API Key',
              secret: true,
              optional: widget.kind == TranscriptionServiceKind.openai,
            ),
            if (widget.kind == TranscriptionServiceKind.aliyun)
              Text(
                '使用百炼异步文件转录，保存远端任务进度。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (widget.kind == TranscriptionServiceKind.openai)
              Text(
                '接口需要支持音频上传及带时间轴的 verbose_json 或 SRT 结果。localhost 指当前设备。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
    if (MediaQuery.sizeOf(context).width < 600) {
      return Scaffold(
        appBar: AppBar(title: const Text('配置转录服务')),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: fields),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: DesktopButtonClickRegion(child: FilledButton(
                    key: const ValueKey('model-center-save-service'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _save,
                    child: const Text('保存服务'),
                  )),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return AlertDialog(
      title: const Text('配置转录服务'),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(width: 480, child: fields),
      actions: [
        DesktopButtonClickRegion(child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        )),
        DesktopButtonClickRegion(child: FilledButton(
          key: const ValueKey('model-center-save-service'),
          onPressed: _save,
          child: const Text('保存服务'),
        )),
      ],
    );
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    bool secret = false,
    bool optional = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: (value) => !optional && (value == null || value.trim().isEmpty)
          ? '请填写$label'
          : null,
    ),
  );
}
