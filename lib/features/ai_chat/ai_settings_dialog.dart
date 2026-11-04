import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'ai_chat_settings.dart';
import 'ai_agent_catalog.dart';
import 'ai_capsule_menu.dart';
import 'ai_chat_layout.dart';
import 'ai_chat_transport.dart';
import 'ai_model_guide.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

String _tokens(int value) => value >= 1000
    ? '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)}k'
    : '$value';
String _effort(String value) => switch (value) {
  'none' => '关闭',
  'minimal' => '最少',
  'low' => '低',
  'medium' => '中',
  'high' => '高',
  'max' => '最大',
  'xhigh' => '最高',
  _ => value,
};

class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({
    super.key,
    required this.settings,
    this.transport,
    this.onSave,
    this.generationInProgress = false,
  });
  final AiChatSettings settings;
  final AiChatTransport? transport;
  final Future<void> Function(AiChatSettings)? onSave;
  final bool generationInProgress;
  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  final _form = GlobalKey<FormState>();
  final _advanced = ExpansibleController();
  final _outputField = GlobalKey();
  final _contextField = GlobalKey();
  late final TextEditingController _url,
      _key,
      _model,
      _executable,
      _arguments,
      _budget,
      _output,
      _thinkingBudget;
  late final AiChatTransport _transport;
  late AiBackend _backend;
  late AiApiProtocol _protocol;
  late AiApiProtocol _catalogProtocol;
  late List<AiModelInfo> _models;
  late List<AiModelInfo> _apiModels;
  late Map<String, AiCliProfile> _cliProfiles;
  late Map<String, AiApiProfile> _apiProfiles;
  late String _profileId;
  late String _apiModel, _apiEffort;
  bool _restoringProfile = false;
  Timer? _autoFetchTimer;
  String _fetchedFingerprint = '';
  AiCliStatus? _cliStatus;
  bool _detectingCli = false;
  late String _catalogUrl;
  late bool _thinking;
  late AiContextMode _contextMode;
  late bool _fastSummaries;
  late bool _optimizeTokens;
  late String _reasoningEffort;
  late double _temperature;
  bool _reveal = false;
  bool _loadingModels = false;
  bool _testing = false;
  bool _savingSettings = false;
  bool _closing = false;
  bool _invalidSettings = false;
  bool _didAutoSave = false;
  Timer? _autoSaveTimer;
  Future<bool>? _saveOperation;
  String? _saveError;
  late AiChatSettings _lastSavedSettings;
  late String _savedFingerprint;
  String? _status;
  bool _statusError = false;
  AiChatCancellation? _catalogCancellation;
  AiChatCancellation? _testCancellation;

  bool get _desktop =>
      !kIsWeb &&
      const [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ].contains(defaultTargetPlatform);
  AiModelInfo? get _info {
    if (!_api) {
      for (final model in _models) {
        if (model.id == _model.text.trim()) return model;
      }
      return null;
    }
    return widget.settings
        .copyWith(
          baseUrl: _url.text.trim(),
          model: _model.text.trim(),
          savedModels: _models,
          modelCatalogBaseUrl: _catalogUrl,
          apiProtocol: _protocol,
          modelCatalogProtocol: _catalogProtocol,
        )
        .selectedModelInfo;
  }

  List<String> get _argumentValues {
    try {
      return aiParseAgentArguments(_arguments.text);
    } on FormatException {
      return const [];
    }
  }

  String? _argumentError(String? value) {
    if (_backend != AiBackend.acp) return null;
    try {
      aiParseAgentArguments(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  bool _agentAvailable(AiAgentPreset preset) =>
      _desktop &&
      preset.supportsPlatform(
        defaultTargetPlatform.name,
        architecture: aiAgentHostArchitecture,
      );

  bool _backendAvailable(AiBackend backend) {
    if (backend == AiBackend.api) return true;
    if (!_desktop) return false;
    final preset = backend.agentPreset;
    return preset == null || _agentAvailable(preset);
  }

  void _clearCliCatalog() {
    setState(() {
      _models = [];
      _cliStatus = null;
      _status = null;
    });
  }

  bool _validateAgentConnection() {
    if (!_backend.usesAcp) return true;
    final error = !_agentAvailable(_backend.agentPreset!)
        ? '当前系统或处理器架构不支持此 Agent 预设。'
        : _backend == AiBackend.acp && _executable.text.trim().isEmpty
        ? '请选择已安装的 ACP Agent 文件。'
        : _argumentError(_arguments.text);
    if (error == null) return true;
    setState(() {
      _status = error;
      _statusError = true;
    });
    return false;
  }

  bool get _api => _backend == AiBackend.api;
  bool get _locked => _loadingModels || _testing || _detectingCli || _closing;
  double get _temperatureLimit =>
      _protocol == AiApiProtocol.openAiCompatible &&
          const {
            'open.bigmodel.cn',
            'api.z.ai',
          }.contains(Uri.tryParse(_url.text.trim())?.host)
      ? 1
      : 2;

  @override
  void initState() {
    super.initState();
    final settings = widget.settings;
    final backendAvailable = _backendAvailable(settings.backend);
    _transport = widget.transport ?? AiChatTransport();
    _backend = settings.backend;
    _protocol = settings.apiProtocol;
    _catalogProtocol = settings.modelCatalogProtocol;
    _url = TextEditingController(text: settings.baseUrl);
    _key = TextEditingController(text: settings.apiKey);
    _model = TextEditingController(text: settings.model);
    _executable = TextEditingController(text: settings.executablePath);
    _arguments = TextEditingController(text: jsonEncode(settings.cliArguments));
    _budget = TextEditingController(text: settings.contextTokens.toString());
    _output = TextEditingController(text: settings.maxOutputTokens.toString());
    _thinkingBudget = TextEditingController(
      text: settings.thinkingBudget.toString(),
    );
    _apiModels = List.of(settings.savedModels);
    _cliProfiles = Map.of(settings.cliProfiles);
    _apiModel = _api
        ? settings.model
        : settings.apiModel.isNotEmpty
        ? settings.apiModel
        : (settings.baseUrl.contains('api.deepseek.com')
              ? 'deepseek-flash'
              : '');
    _apiEffort = _api ? settings.reasoningEffort : settings.apiReasoningEffort;
    _models = List.of(
      _api
          ? _apiModels
          : _cliProfiles[_backend.name]?.models ?? const <AiModelInfo>[],
    );
    _catalogUrl = settings.modelCatalogBaseUrl;
    _thinking = settings.thinkingEnabled;
    _contextMode = settings.contextMode;
    _fastSummaries = settings.fastSummaries;
    _optimizeTokens = settings.optimizeTokens;
    _reasoningEffort = settings.reasoningEffort;
    if (!_api &&
        _backendAvailable(_backend) &&
        _cliProfiles[_backend.name] == null) {
      if (const ['deepseek-chat', 'deepseek-flash'].contains(_model.text)) {
        _model.clear();
      }
      _reasoningEffort = '';
    }
    _temperature = settings.temperature;
    _profileId = settings.resolvedApiProfileId;
    _apiProfiles = {
      for (final entry in settings.apiProfiles.entries) entry.key: entry.value,
    };
    final remembered = _apiProfiles[_profileId];
    if (remembered != null && _api) {
      if (_key.text.isEmpty && remembered.apiKey.isNotEmpty) {
        _key.text = remembered.apiKey;
      }
      if (_models.isEmpty && remembered.models.isNotEmpty) {
        _models = List.of(remembered.models);
        _apiModels = List.of(remembered.models);
        _catalogUrl = remembered.modelCatalogBaseUrl;
        _catalogProtocol = remembered.modelCatalogProtocol;
      }
    }
    if (!_backendAvailable(_backend)) _applyBackend(AiBackend.api);
    _rememberProfile();
    if (_api && _models.isNotEmpty) {
      _fetchedFingerprint = _connectionFingerprint();
    }
    _url.addListener(_onUrlEdited);
    _key.addListener(_onKeyEdited);
    _model.addListener(_modelChanged);
    _budget.addListener(_budgetChanged);
    _output.addListener(_budgetChanged);
    // A platform fallback must still be persisted when the dialog saves or
    // closes, even if the user does not edit the restored API fields.
    _lastSavedSettings = backendAvailable ? _value() : settings;
    _savedFingerprint = _settingsFingerprint(_lastSavedSettings);
  }

  @override
  void dispose() {
    _advanced.dispose();
    _autoFetchTimer?.cancel();
    _autoSaveTimer?.cancel();
    if (widget.transport == null) unawaited(_transport.dispose());
    _catalogCancellation?.cancel();
    _testCancellation?.cancel();
    for (final controller in [
      _url,
      _key,
      _model,
      _executable,
      _arguments,
      _budget,
      _output,
      _thinkingBudget,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _normalized(String url) => url.trim().replaceFirst(RegExp(r'/+$'), '');

  String _connectionFingerprint() =>
      '${_protocol.name}|${_normalized(_url.text)}|${_key.text.trim()}';

  bool get _localEndpoint {
    final host = Uri.tryParse(_url.text.trim())?.host.toLowerCase() ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  /// Writes the visible API form into the current manufacturer's slot.
  void _rememberProfile() {
    if (!_api || _restoringProfile) return;
    _apiProfiles[_profileId] = AiApiProfile(
      baseUrl: _url.text.trim(),
      protocol: _protocol,
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
      models: List.of(_models),
      reasoningEffort: _reasoningEffort,
      modelCatalogBaseUrl: _catalogUrl,
      modelCatalogProtocol: _catalogProtocol,
    );
  }

  void _clearCatalog() {
    _catalogCancellation?.cancel();
    _autoFetchTimer?.cancel();
    _models = [];
    _apiModels = [];
    _catalogUrl = '';
    _catalogProtocol = _protocol;
    _fetchedFingerprint = '';
  }

  void _onUrlEdited() {
    if (!_api || _restoringProfile) return;
    final catalog = _normalized(_catalogUrl);
    final url = _normalized(_url.text);
    if (catalog.isNotEmpty &&
        (url != catalog || _catalogProtocol != _protocol)) {
      _clearCatalog();
    }
    _rememberProfile();
    _scheduleAutoFetch();
    if (mounted) setState(() => _status = null);
  }

  void _onKeyEdited() {
    if (!_api || _restoringProfile) return;
    if (_fetchedFingerprint.isNotEmpty &&
        _connectionFingerprint() != _fetchedFingerprint) {
      _clearCatalog();
    }
    _rememberProfile();
    _scheduleAutoFetch();
    if (mounted) setState(() => _status = null);
  }

  /// Waits until the key stops changing, then reads that provider's catalog.
  void _scheduleAutoFetch() {
    _autoFetchTimer?.cancel();
    if (!_api || _locked) return;
    final key = _key.text.trim();
    if (key.isEmpty && !_localEndpoint) return;
    if (_urlError(_url.text) != null) return;
    final fingerprint = _connectionFingerprint();
    if (fingerprint == _fetchedFingerprint && _models.isNotEmpty) return;
    _autoFetchTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || _locked || _connectionFingerprint() != fingerprint) {
        return;
      }
      unawaited(_loadModels());
    });
  }

  void _modelChanged() {
    if (_restoringProfile) return;
    _rememberProfile();
    if (mounted) setState(() {});
  }

  void _budgetChanged() {
    if (mounted) setState(() {});
  }

  void _applyProfile(AiApiProfile? saved, AiApiPreset preset) {
    _restoringProfile = true;
    _profileId = preset.id;
    _protocol = saved?.protocol ?? preset.protocol;
    final nextUrl = saved == null
        ? preset.baseUrl
        : (saved.baseUrl.isNotEmpty || preset.baseUrl.isEmpty)
        ? saved.baseUrl
        : preset.baseUrl;
    _url.text = nextUrl;
    _key.text = saved?.apiKey ?? '';
    _model.text = saved != null && saved.model.isNotEmpty
        ? saved.model
        : (preset.id == 'deepseek' ? 'deepseek-flash' : '');
    _models = List.of(saved?.models ?? const <AiModelInfo>[]);
    _apiModels = List.of(_models);
    _catalogUrl = saved?.modelCatalogBaseUrl ?? '';
    _catalogProtocol = saved?.modelCatalogProtocol ?? _protocol;
    if (saved != null && saved.reasoningEffort.isNotEmpty) {
      _reasoningEffort = saved.reasoningEffort;
    }
    _fetchedFingerprint = _models.isNotEmpty ? _connectionFingerprint() : '';
    _restoringProfile = false;
  }

  void _switchPreset(String? id) {
    if (id == null || id == _profileId || _locked) return;
    final preset = aiApiPresets.firstWhere((item) => item.id == id);
    _rememberProfile();
    final saved = _apiProfiles[preset.id];
    setState(() {
      _applyProfile(saved, preset);
      _status = preset.note.isEmpty ? null : preset.note;
      _statusError = false;
    });
    _scheduleAutoFetch();
    _scheduleAutoSave();
  }

  AiChatSettings _value() {
    _rememberProfile();
    return widget.settings.copyWith(
      backend: _backend,
      baseUrl: _url.text.trim(),
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
      executablePath: _executable.text.trim(),
      cliArguments: _argumentValues,
      contextTokens: int.tryParse(_budget.text) ?? 64000,
      contextMode: _contextMode,
      fastSummaries: _fastSummaries,
      optimizeTokens: _optimizeTokens,
      maxOutputTokens: int.tryParse(_output.text) ?? 8192,
      temperature: _temperature.clamp(0, _temperatureLimit).toDouble(),
      thinkingEnabled: _info?.supportsThinking == false
          ? false
          : _info?.canDisableThinking == false
          ? true
          : _thinking,
      reasoningEffort: _reasoningEffort,
      savedModels: _api ? _models : _apiModels,
      modelCatalogBaseUrl: _catalogUrl,
      thinkingBudget: int.tryParse(_thinkingBudget.text) ?? 0,
      apiProtocol: _protocol,
      modelCatalogProtocol: _catalogProtocol,
      apiModel: _api ? _model.text.trim() : _apiModel,
      apiReasoningEffort: _api ? _reasoningEffort : _apiEffort,
      cliProfiles: {
        ..._cliProfiles,
        if (!_api)
          _backend.name: AiCliProfile(
            executablePath: _executable.text.trim(),
            cliArguments: _argumentValues,
            model: _model.text.trim(),
            models: _models,
            reasoningEffort: _reasoningEffort,
          ),
      },
      apiProfileId: _profileId,
      apiProfiles: {
        for (final entry in _apiProfiles.entries) entry.key: entry.value,
      },
    );
  }

  void _applyBackend(AiBackend backend) {
    _restoringProfile = true;
    if (_api) {
      _apiModel = _model.text;
      _apiModels = List.of(_models);
      _apiEffort = _reasoningEffort;
    } else {
      _cliProfiles[_backend.name] = AiCliProfile(
        executablePath: _executable.text,
        cliArguments: _argumentValues,
        model: _model.text,
        models: List.of(_models),
        reasoningEffort: _reasoningEffort,
      );
    }
    _backend = backend;
    if (_api) {
      final saved = _apiProfiles[_profileId];
      _models = List.of(saved?.models ?? _apiModels);
      _apiModels = List.of(_models);
      _model.text = saved != null && saved.model.isNotEmpty
          ? saved.model
          : _apiModel;
      _key.text = saved?.apiKey ?? _key.text;
      if (saved != null && saved.baseUrl.isNotEmpty) {
        _url.text = saved.baseUrl;
      }
      _protocol = saved?.protocol ?? _protocol;
      _catalogUrl = saved?.modelCatalogBaseUrl ?? _catalogUrl;
      _catalogProtocol = saved?.modelCatalogProtocol ?? _catalogProtocol;
      _reasoningEffort = saved != null && saved.reasoningEffort.isNotEmpty
          ? saved.reasoningEffort
          : _apiEffort;
      _fetchedFingerprint = _models.isNotEmpty ? _connectionFingerprint() : '';
    } else {
      final profile = _cliProfiles[backend.name];
      _models = List.of(profile?.models ?? const <AiModelInfo>[]);
      _executable.text = profile?.executablePath ?? '';
      _arguments.text = jsonEncode(profile?.cliArguments ?? const <String>[]);
      _model.text = profile?.model ?? '';
      _reasoningEffort = profile?.reasoningEffort ?? '';
    }
    _restoringProfile = false;
    _cliStatus = null;
    _status = null;
    _statusError = false;
  }

  void _switchBackend(AiBackend backend) {
    if (backend == _backend || !_backendAvailable(backend)) return;
    if (_api) _rememberProfile();
    setState(() => _applyBackend(backend));
    _scheduleAutoSave();
  }

  Future<void> _detectCli() async {
    if (_locked || _api || !_validateAgentConnection()) return;
    final cancellation = AiChatCancellation();
    _catalogCancellation = cancellation;
    setState(() {
      _detectingCli = true;
      _status = null;
      _statusError = false;
    });
    try {
      final status = await _transport.inspectCli(
        _value(),
        cancellation: cancellation,
      );
      if (!mounted || cancellation.isCancelled) return;
      _updateSettings(() {
        _executable.text = status.executablePath;
        _cliStatus = status;
        _status = status.loggedIn == false
            ? _backend == AiBackend.codex
                  ? '已找到工具，但 Codex 尚未登录。请先运行 codex login。'
                  : '已找到 ${_backend.label}，但尚未登录。请先在工具自身完成登录。'
            : '已检测到 ${_backend.label}，可刷新模型目录后测试连接。';
        _statusError = status.loggedIn == false;
      });
    } catch (error) {
      if (mounted && !cancellation.isCancelled) {
        setState(() {
          _status = '$error';
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _detectingCli = false);
    }
  }

  String _selectionSummary(AiModelInfo? info) {
    final id = _model.text.trim();
    if (id.isEmpty) {
      return '选择或填写模型后，这里会显示它在目录中的新旧、用途和上下文。';
    }
    final catalog = <AiModelInfo>[
      ..._models.map(
        (entry) => _api ? entry.withProviderDefaults(_url.text.trim()) : entry,
      ),
      if (!_models.any((model) => model.id == id)) info ?? AiModelInfo(id: id),
    ];
    AiModelPresentation? presented;
    for (final entry in presentModels(catalog)) {
      if (entry.model.id == id) {
        presented = entry;
        break;
      }
    }
    if (presented == null) {
      return '模型目录未声明窗口限制。请按服务文档填写预算；这不影响手动使用模型。';
    }
    final contextLabel = presented.displayContext == null
        ? '上下文未标明'
        : '${presented.contextIsEstimate ? '上下文约' : '上下文'} ${_tokens(presented.displayContext!)}';
    final output = presented.model.maxOutputTokens == null
        ? ''
        : ' · 最大输出 ${_tokens(presented.model.maxOutputTokens!)}';
    final released = presented.releasedLabel == null
        ? ''
        : ' · ${presented.releasedLabel}';
    final thinking = presented.model.supportsThinking == true ? ' · 可思考' : '';
    // A one-model list would call itself "最新". Only compare inside a real catalog.
    final age = _models.length >= 2 ? '${presented.ageLabel} · ' : '';
    return '$age${presented.headline} · $contextLabel$output$released$thinking';
  }

  String? _urlError(String? value) {
    if (!_api) return null;
    final uri = Uri.tryParse((value ?? '').trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return '请输入完整的 HTTP(S) API 根地址';
    }
    return null;
  }

  void _fitCapabilities() {
    final info = _info;
    var budget = int.tryParse(_budget.text) ?? 64000;
    var output = int.tryParse(_output.text) ?? 8192;
    final oldBudget = budget;
    final oldOutput = output;
    if (info?.contextWindow != null && budget > info!.contextWindow!) {
      budget = info.contextWindow!;
    }
    if (info?.maxOutputTokens != null && output > info!.maxOutputTokens!) {
      output = info.maxOutputTokens!;
    }
    if (output >= budget - 512) {
      output = (budget ~/ 4).clamp(1, info?.maxOutputTokens ?? 524288).toInt();
    }
    _budget.text = budget.toString();
    _output.text = output.toString();
    final efforts = info?.reasoningEfforts ?? const <String>[];
    if (efforts.isNotEmpty && !efforts.contains(_reasoningEffort)) {
      final preferred = info?.defaultReasoningEffort;
      _reasoningEffort = preferred != null && efforts.contains(preferred)
          ? preferred
          : (efforts.contains('high') ? 'high' : efforts.last);
    }
    if (budget != oldBudget || output != oldOutput) {
      _status = '已按模型能力限制调整预算：上下文 ${_tokens(budget)}，单次生成 ${_tokens(output)}。';
      _statusError = false;
    }
  }

  Future<void> _loadModels() async {
    _autoFetchTimer?.cancel();
    if (_loadingModels || !_validateAgentConnection()) return;
    final error = _urlError(_url.text);
    if (error != null) {
      setState(() {
        _status = error;
        _statusError = true;
      });
      return;
    }
    final request = _value();
    final cancellation = AiChatCancellation();
    _catalogCancellation?.cancel();
    _catalogCancellation = cancellation;
    setState(() {
      _loadingModels = true;
      _status = null;
      _statusError = false;
    });
    try {
      final models = await _transport.fetchModels(
        request,
        cancellation: cancellation,
      );
      if (!mounted || cancellation.isCancelled) return;
      _updateSettings(() {
        _models = models;
        if (_api) {
          _apiModels = List.of(models);
          _catalogUrl = request.baseUrl;
          _catalogProtocol = request.apiProtocol;
        } else if (_model.text.trim().isEmpty && models.isNotEmpty) {
          _model.text = models.first.id;
          _reasoningEffort = models.first.defaultReasoningEffort ?? '';
        }
        _status = models.isEmpty
            ? _backend.usesAcp
                  ? 'Agent 未提供模型目录，请使用工具默认模型；也可在工具自身配置后重试。'
                  : '服务返回了空模型目录，仍可手动填写模型 ID。'
            : _api
            ? '已读取 ${models.length} 个可用模型。'
            : '已读取 ${models.length} 个 CLI 模型。目录与当前工具、供应商配置有关，账号实际权限由连接测试验证。';
        _fetchedFingerprint = _connectionFingerprint();
        _fitCapabilities();
        _rememberProfile();
      });
    } catch (error) {
      if (mounted && !cancellation.isCancelled) {
        setState(() {
          _status = _backend.usesAcp
              ? '$error\n可使用工具默认模型，或在工具自身配置后重试。'
              : '$error\n仍可手动填写对应服务或工具支持的模型 ID。';
          _statusError = true;
        });
      }
    } finally {
      if (mounted && identical(_catalogCancellation, cancellation)) {
        setState(() => _loadingModels = false);
      }
    }
  }

  Future<void> _chooseModel() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = await showDialog<AiModelInfo>(
      context: context,
      requestFocus: false,
      builder: (context) => AiModelPickerDialog(
        models: _api
            ? _models
                  .map((model) => model.withProviderDefaults(_url.text.trim()))
                  .toList()
            : _models,
        selectedId: _model.text.trim(),
      ),
    );
    if (selected != null && mounted) {
      FocusManager.instance.primaryFocus?.unfocus();
      _updateSettings(() {
        _model.text = selected.id;
        _fitCapabilities();
      });
    }
  }

  String? _outputError(String? value) {
    final n = int.tryParse(value ?? '');
    final budget = int.tryParse(_budget.text) ?? 0;
    final cap = _info?.maxOutputTokens ?? 524288;
    if (n == null || n < 1 || n > cap) return '请输入 1 到 $cap Token';
    if (n >= budget - 512) return '需为输入保留至少 512 Token，请增加上下文预算';
    return null;
  }

  String? _contextBudgetError(String? value) {
    final n = int.tryParse(value ?? '');
    if (n == null || n < 2048 || n > 2000000) {
      return '请输入 2048 到 2000000 Token';
    }
    final window = _info?.contextWindow;
    if (window != null && n > window) return '超过模型窗口 $window Token';
    return null;
  }

  bool _validateForm() {
    final invalidOutput = _outputError(_output.text) != null;
    if (invalidOutput || _contextBudgetError(_budget.text) != null) {
      _advanced.expand();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final field =
            (invalidOutput ? _outputField : _contextField).currentContext;
        if (field != null) {
          unawaited(
            Scrollable.ensureVisible(
              field,
              duration: const Duration(milliseconds: 250),
              alignment: .1,
            ),
          );
        }
      });
    }
    return _form.currentState!.validate() &&
        !invalidOutput &&
        _contextBudgetError(_budget.text) == null;
  }

  // Include keys only in this in-memory comparison; toJson omits secrets.
  String _settingsFingerprint(AiChatSettings value) => jsonEncode({
    'settings': value.toJson(),
    'apiKey': value.apiKey,
    'profileKeys': {
      for (final entry in value.apiProfiles.entries)
        entry.key: entry.value.apiKey,
    },
  });

  void _updateSettings(VoidCallback update) {
    setState(update);
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    if (!mounted || _restoringProfile || _closing) return;
    _autoSaveTimer?.cancel();
    setState(() {
      _invalidSettings = false;
      _saveError = null;
    });
    _autoSaveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveChanges());
    });
  }

  Future<bool> _saveChanges() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    return _saveOperation ??= _persistChanges().whenComplete(() {
      _saveOperation = null;
    });
  }

  Future<bool> _persistChanges() async {
    try {
      // Serialize writes and coalesce edits made while storage is busy.
      while (mounted) {
        if (!_validateForm()) {
          setState(() => _invalidSettings = true);
          return false;
        }
        final value = _value();
        final fingerprint = _settingsFingerprint(value);
        if (fingerprint == _savedFingerprint) return true;
        setState(() {
          _savingSettings = true;
          _saveError = null;
          _invalidSettings = false;
        });
        await widget.onSave?.call(value);
        if (!mounted) return false;
        _lastSavedSettings = value;
        _savedFingerprint = fingerprint;
        _didAutoSave = true;
      }
      return false;
    } catch (error) {
      if (mounted) {
        setState(() => _saveError = '$error');
      }
      return false;
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  Future<void> _close({bool discardUnsaved = false}) async {
    if (_closing) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _closing = true);
    final saved = discardUnsaved || await _saveChanges();
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context, _lastSavedSettings);
    } else {
      setState(() => _closing = false);
    }
  }

  Future<void> _test() async {
    if (!_validateForm() || !_validateAgentConnection()) return;
    final cancellation = AiChatCancellation();
    _testCancellation?.cancel();
    _testCancellation = cancellation;
    setState(() {
      _testing = true;
      _status = null;
      _statusError = false;
    });
    try {
      if (!_api) {
        final status = await _transport.inspectCli(
          _value(),
          cancellation: cancellation,
        );
        if (!mounted || cancellation.isCancelled) return;
        _updateSettings(() {
          _executable.text = status.executablePath;
          _cliStatus = status;
        });
        if (status.loggedIn == false) {
          throw AiChatException(
            _backend == AiBackend.codex
                ? 'Codex 已安装但尚未登录，请先在终端运行 codex login 后重试。'
                : '工具已安装但尚未登录，请先在工具自身完成登录后重试。',
          );
        }
      }
      final result = await _transport.testConnection(
        _value(),
        cancellation: cancellation,
      );
      if (mounted) setState(() => _status = result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = error.toString();
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _recommended() => _updateSettings(() {
    const defaults = AiChatSettings();
    _contextMode = defaults.contextMode;
    _fastSummaries = defaults.fastSummaries;
    _optimizeTokens = defaults.optimizeTokens;
    _thinking = defaults.thinkingEnabled;
    _reasoningEffort = defaults.reasoningEffort;
    _temperature = defaults.temperature;
    _budget.text = defaults.contextTokens.toString();
    _output.text = defaults.maxOutputTokens.toString();
    _thinkingBudget.text = defaults.thinkingBudget.toString();
    _status = '已恢复推荐响应设置，连接地址、密钥与模型 ID 保留。';
    _fitCapabilities();
    _statusError = false;
  });

  Widget _heading(String title, String description, {Widget? trailing}) =>
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: description,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (trailing != null)
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: trailing),
              ),
          ],
        ),
      );

  Widget _fieldPair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 264 ||
          MediaQuery.textScalerOf(context).scale(12) > 15) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 8), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: first),
          const SizedBox(width: 8),
          Expanded(child: second),
        ],
      );
    },
  );

  Widget _numberField(
    TextEditingController controller,
    String label,
    String? Function(String?) validator,
  ) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.number,
    validator: validator,
    decoration: InputDecoration(
      labelText: label,
      suffixText: 'Token',
      border: const OutlineInputBorder(),
    ),
  );

  Widget _budgetPresets({
    required TextEditingController controller,
    required List<int> values,
    required bool answer,
  }) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final value in values)
        ChoiceChip(
          label: Text(answer ? '${value ~/ 1024}k' : _tokens(value)),
          selected: int.tryParse(controller.text) == value,
          onSelected:
              (answer
                  ? (_info?.maxOutputTokens != null &&
                        value > _info!.maxOutputTokens!)
                  : (_info?.contextWindow != null &&
                        value > _info!.contextWindow!))
              ? null
              : (_) => _updateSettings(() {
                  controller.text = value.toString();
                  if (!answer) _fitCapabilities();
                }),
        ),
      Text(
        '或填写自定义值',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  /// Same capsule as the playback quality button: the closed control shows the
  /// current choice, and tapping it opens the anchored option list.
  Widget _capsuleField<T>({
    Key? key,
    required String label,
    required T value,
    required List<AiCapsuleChoice<T>> choices,
    required ValueChanged<T>? onChanged,
  }) => AiCapsuleSelectField<T>(
    key: key,
    label: label,
    value: value,
    choices: choices,
    onChanged: onChanged,
  );

  Widget _thinkingControls() {
    final info = _info;
    final supports = info?.supportsThinking;
    final mandatoryThinking =
        supports != false && info?.canDisableThinking == false;
    final thinkingOn = supports == false
        ? false
        : mandatoryThinking || _thinking;
    final efforts = info?.reasoningEfforts ?? const <String>[];
    final effortSupported =
        info?.supportsReasoningEffort == true && efforts.isNotEmpty;
    final currentEffort = efforts.contains(_reasoningEffort)
        ? _reasoningEffort
        : efforts.contains(info?.defaultReasoningEffort)
        ? info?.defaultReasoningEffort
        : (efforts.isEmpty ? null : efforts.last);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('深度思考', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            mandatoryThinking
                ? '此模型始终开启思考，不能关闭。'
                : supports == false
                ? '模型目录明确不支持深度思考。'
                : supports == true
                ? '使用该模型支持的思考协议。'
                : '使用服务默认思考策略，目录未声明可调能力。',
            style: const TextStyle(fontSize: 11),
          ),
          value: thinkingOn,
          onChanged: supports != true || mandatoryThinking
              ? null
              : (value) => _updateSettings(() => _thinking = value),
        ),
        if (thinkingOn && supports == true) ...[
          if (effortSupported)
            _capsuleField<String>(
              key: ValueKey('reasoning-${_model.text}'),
              label: '思考等级（模型支持的选项）',
              value: currentEffort ?? efforts.last,
              choices: [
                for (final value in efforts)
                  AiCapsuleChoice(
                    value: value,
                    label: '${_effort(value)} · $value',
                  ),
              ],
              onChanged: (value) =>
                  _updateSettings(() => _reasoningEffort = value),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '该目录未提供可调思考等级。应用不会向不支持的模型强行附加等级参数。',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
          if (info?.supportsThinkingBudget == true) ...[
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('ai-settings-thinking-budget'),
              controller: _thinkingBudget,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '思考长度上限（Token，0 为自动）',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final budget = int.tryParse(value ?? '');
                if (budget == null || budget < 0 || budget > 262144) {
                  return '请输入 0（自动）或 1 到 262144 Token';
                }
                return null;
              },
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '0 使用服务的动态推荐；与回答长度分别设置，最终可用范围和思考用量按服务规则处理。',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
            if (effortSupported &&
                Uri.tryParse(_url.text.trim())?.host == 'openrouter.ai')
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'OpenRouter 的思考预算与等级互斥；填写非零预算后，优先使用预算。',
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _cliThinkingControls() {
    final efforts = _info?.reasoningEfforts ?? const <String>[];
    if (efforts.isEmpty) {
      return const Text(
        '选择模型后显示工具提供的思考选项；未提供的能力使用 CLI 自身配置。',
        style: TextStyle(fontSize: 12, height: 1.5),
      );
    }
    final effort = efforts.contains(_reasoningEffort) ? _reasoningEffort : '';
    return _capsuleField<String>(
      key: ValueKey('cli-reasoning-${_model.text}'),
      label: 'CLI 思考等级',
      value: effort,
      choices: [
        const AiCapsuleChoice(value: '', label: '使用工具默认设置'),
        for (final level in efforts)
          AiCapsuleChoice(value: level, label: '${_effort(level)} · $level'),
      ],
      onChanged: _locked
          ? null
          : (value) => _updateSettings(() => _reasoningEffort = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canDiscard = _saveError != null || _invalidSettings;
    final closeButton = DesktopButtonClickRegion(
      child: TextButton(
        key: const ValueKey('ai-settings-close'),
        onPressed: _closing
            ? null
            : () => unawaited(
                _close(discardUnsaved: _saveError != null || _invalidSettings),
              ),
        child: Text(canDiscard ? '放弃未保存更改并关闭' : '关闭'),
      ),
    );
    final info = _info;
    final temperature = _temperature.clamp(0, _temperatureLimit).toDouble();
    final available =
        (int.tryParse(_budget.text) ?? 0) -
        (int.tryParse(_output.text) ?? 0) -
        512;
    final backendField = _capsuleField<AiBackend>(
      key: const ValueKey('ai-settings-backend'),
      label: '连接方式',
      value: _backend,
      choices: [
        const AiCapsuleChoice(value: AiBackend.api, label: 'API 服务'),
        if (_backendAvailable(AiBackend.codex))
          const AiCapsuleChoice(
            value: AiBackend.codex,
            label: '桌面 · Codex CLI',
          ),
        if (_backendAvailable(AiBackend.opencode))
          const AiCapsuleChoice(
            value: AiBackend.opencode,
            label: '桌面 · OpenCode CLI',
          ),
        for (final preset in aiAgentPresets)
          if (_backendAvailable(preset.backend))
            AiCapsuleChoice(
              value: preset.backend,
              label: '桌面 · ${preset.label}',
            ),
      ],
      onChanged: _locked ? null : _switchBackend,
    );
    final presetField = _capsuleField<String>(
      key: ValueKey('provider-$_profileId'),
      label: '服务预设',
      value: _profileId,
      choices: [
        for (final preset in aiApiPresets)
          AiCapsuleChoice(value: preset.id, label: preset.label),
      ],
      onChanged: _locked ? null : _switchPreset,
    );
    final protocolField = _capsuleField<AiApiProtocol>(
      key: ValueKey('protocol-$_protocol'),
      label: 'API 协议',
      value: _protocol,
      choices: const [
        AiCapsuleChoice(
          value: AiApiProtocol.openAiCompatible,
          label: 'OpenAI 兼容',
        ),
        AiCapsuleChoice(
          value: AiApiProtocol.anthropic,
          label: 'Anthropic / Claude 原生',
        ),
        AiCapsuleChoice(
          value: AiApiProtocol.gemini,
          label: 'Google / Gemini 原生',
        ),
      ],
      onChanged: _locked
          ? null
          : (value) {
              if (value == _protocol) return;
              _updateSettings(() {
                _protocol = value;
                if (_catalogProtocol != _protocol) _clearCatalog();
                _rememberProfile();
              });
              _scheduleAutoFetch();
            },
    );
    final urlField = TextFormField(
      key: const ValueKey('ai-settings-url'),
      controller: _url,
      enabled: !_locked,
      validator: _urlError,
      decoration: const InputDecoration(
        labelText: 'API 根地址',
        border: OutlineInputBorder(),
      ),
    );
    final connection = <Widget>[
      _heading('连接', '每个服务和桌面 Agent 分别记住连接与模型；切换后再回来，仍会看到上次填写的内容。'),
      if (_api) _fieldPair(backendField, presetField) else backendField,
      const SizedBox(height: 8),
      if (_api) ...[
        _fieldPair(protocolField, urlField),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('ai-settings-key'),
          controller: _key,
          enabled: !_locked,
          obscureText: !_reveal,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onEditingComplete: () {
            _autoFetchTimer?.cancel();
            if (_urlError(_url.text) == null &&
                (_key.text.trim().isNotEmpty || _localEndpoint)) {
              unawaited(_loadModels());
            }
          },
          decoration: InputDecoration(
            labelText: 'API 密钥（本地服务可留空）',
            border: const OutlineInputBorder(),
            suffixIcon: DesktopButtonClickRegion(
              child: IconButton(
                tooltip: _reveal ? '隐藏密钥' : '显示密钥',
                onPressed: () => setState(() => _reveal = !_reveal),
                icon: Icon(
                  _reveal
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            '密钥仅保存在系统安全存储，不发送到对话。',
            style: TextStyle(fontSize: 11, height: 1.5),
          ),
        ),
      ] else ...[
        const Text(
          '仅发送所选视频资料节选；每次在独立临时目录运行。',
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('ai-settings-executable'),
          controller: _executable,
          enabled: !_locked,
          onChanged: (_) => _clearCliCatalog(),
          validator: (value) =>
              _backend == AiBackend.acp && (value ?? '').trim().isEmpty
              ? '请选择已安装的 ACP Agent 文件'
              : null,
          decoration: const InputDecoration(
            labelText: '工具文件或安装文件夹（预设可留空自动查找）',
            border: OutlineInputBorder(),
          ),
        ),
        if (_backend == AiBackend.acp) ...[
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('ai-settings-agent-arguments'),
            controller: _arguments,
            enabled: !_locked,
            minLines: 1,
            maxLines: 4,
            validator: _argumentError,
            onChanged: (_) => _clearCliCatalog(),
            decoration: const InputDecoration(
              labelText: '启动参数（JSON 字符串数组）',
              hintText: '["--acp"]',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 8),
        DesktopButtonClickRegion(child: OutlinedButton.icon(
          key: const ValueKey('ai-detect-cli'),
          onPressed: _locked ? null : _detectCli,
          icon: const Icon(Icons.manage_search, size: 18),
          label: Text(_detectingCli ? '正在检测…' : '自动检测安装与登录'),
        )),
        if (_cliStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
              _cliStatus!.description,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _backend.agentPreset?.instructions ??
                '支持直接填写 bin 文件夹、.exe 或 npm 的 .cmd 文件。测试连接复用本机登录；不需要在此填写 CLI 的 API 密钥。',
            style: const TextStyle(fontSize: 11, height: 1.5),
          ),
        ),
        if (_backend.agentPreset case final preset?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(
              preset.documentationUrl,
              style: const TextStyle(fontSize: 11, height: 1.5),
            ),
          ),
      ],
      _heading(
        '模型',
        _api
            ? '密钥填写完成后会自动读取模型，也可以手动刷新。列表按新旧排列，并标出用途和上下文。'
            : _backend.usesAcp
            ? '读取 Agent 提供的模型和思考选项；未提供目录时，可使用工具默认模型。连接测试会验证实际访问。'
            : '从已安装工具刷新模型目录并选择。OpenCode 的 ID 包含供应商前缀；连接测试会验证账号是否支持。',
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            DesktopButtonClickRegion(
              child: OutlinedButton.icon(
                key: const ValueKey('ai-load-models'),
                onPressed: _locked ? null : _loadModels,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: Text(
                  _loadingModels
                      ? '正在读取…'
                      : _api
                      ? '从 API 读取模型'
                      : '刷新 CLI 模型目录',
                ),
              ),
            ),
            DesktopButtonClickRegion(
              child: OutlinedButton.icon(
                key: const ValueKey('ai-select-model'),
                onPressed: _locked || _models.isEmpty ? null : _chooseModel,
                icon: const Icon(Icons.search, size: 18),
                label: Text(
                  '搜索选择${_models.isEmpty ? '' : ' · ${_models.length}'}',
                ),
              ),
            ),
          ],
        ),
      ),
      if (!_api)
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButtonClickRegion(child: TextButton(
            onPressed: _locked
                ? null
                : () {
                    _updateSettings(() {
                      _model.clear();
                      _reasoningEffort = '';
                    });
                  },
            child: const Text('使用工具默认模型'),
          )),
        ),
      TextFormField(
        key: const ValueKey('ai-settings-model'),
        controller: _model,
        enabled: !_locked,
        onFieldSubmitted: (_) {
          FocusManager.instance.primaryFocus?.unfocus();
          unawaited(_saveChanges());
        },
        validator: (value) =>
            _api && (value ?? '').trim().isEmpty ? '请选择或填写模型 ID' : null,
        decoration: InputDecoration(
          labelText: '模型 ID',
          helperText: _backend.usesAcp && _models.isEmpty
              ? '留空使用工具默认模型；Agent 提供目录后可切换模型。'
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          _selectionSummary(info),
          style: TextStyle(
            fontSize: 11,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ];
    final response = <Widget>[
      _heading(
        '对话偏好',
        '按当前问题处理文稿和历史；需要手动调整时再展开高级设置。',
        trailing: Text(
          '文稿处理：${switch (_contextMode) {
            AiContextMode.automatic => '自动（推荐）',
            AiContextMode.full => '全文直读',
            AiContextMode.economical => '相关片段检索',
            AiContextMode.segmented => '分段整理',
          }}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      ),
      if (_api) _thinkingControls() else _cliThinkingControls(),
      if (_optimizeTokens || _fastSummaries)
        Text(
          '已启用：${[if (_optimizeTokens) '智能节省 token', if (_fastSummaries) '快速总结'].join('、')}',
          style: const TextStyle(fontSize: 11),
        ),
      const SizedBox(height: 8),
      ExpansionTile(
        key: const ValueKey('ai-settings-advanced'),
        controller: _advanced,
        maintainState: true,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        tilePadding: EdgeInsets.zero,
        minTileHeight: 32,
        childrenPadding: const EdgeInsets.only(top: 6),
        title: const Text('高级响应设置', style: TextStyle(fontSize: 13)),
        children: [
          KeyedSubtree(
            key: _outputField,
            child: _numberField(
              _output,
              _api ? '单次生成上限' : '回答预算预留（CLI）',
              _outputError,
            ),
          ),
          const SizedBox(height: 8),
          _budgetPresets(
            controller: _output,
            values: const [4096, 8192, 16384, 32768],
            answer: true,
          ),
          if (_api)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '部分服务将思考也计入这个额度。达到上限会自动补写一次，每次均受此上限和剩余窗口约束；仍未完成可点击继续生成。',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
          if (!_api)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '此值用于预留回答空间；CLI 实际生成上限由工具自身配置控制。',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
          const SizedBox(height: 10),
          KeyedSubtree(
            key: _contextField,
            child: _numberField(_budget, '常规上下文预算（含预留回答）', _contextBudgetError),
          ),
          const SizedBox(height: 8),
          _budgetPresets(
            controller: _budget,
            values: const [16000, 64000, 128000],
            answer: false,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '常规请求约 ${_tokens(available.clamp(0, 2000000).toInt())} Token 可用于资料、问题与历史；另预留 ${_tokens(int.tryParse(_output.text) ?? 0)} Token 回答。全文模式的实际请求预算会单独显示。',
              style: const TextStyle(fontSize: 11, height: 1.6),
            ),
          ),
          const SizedBox(height: 8),
          _capsuleField<AiContextMode>(
            key: const ValueKey('ai-settings-context-mode'),
            label: '文稿处理方式',
            value: _contextMode,
            choices: const [
              AiCapsuleChoice(
                value: AiContextMode.automatic,
                label: '自动 · 按问题控制资料量（推荐）',
              ),
              AiCapsuleChoice(
                value: AiContextMode.full,
                label: '全文直读 · 一次发送完整字幕',
              ),
              AiCapsuleChoice(
                value: AiContextMode.economical,
                label: '省 token · 相关片段检索',
              ),
              AiCapsuleChoice(
                value: AiContextMode.segmented,
                label: '分段整理 · 预先生成并复用摘要',
              ),
            ],
            onChanged: _locked
                ? null
                : (mode) => _updateSettings(() => _contextMode = mode),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(switch (_contextMode) {
              AiContextMode.automatic =>
                _optimizeTokens
                    ? '普通问答使用有界原文，保留已发送的请求并追加新资料。全片问题仍覆盖全文：常规预算至少 64k 时，能避免分段请求才临时尝试 96k；更长文稿分段处理。历史达到预算才重整。'
                    : '总结全片时优先发送全文；模型窗口已知时按需尝试 96k、128k，最多 256k 的请求预算；仍放不下再分段。',
              AiContextMode.full =>
                '每次直接发送全部已选文字字幕，使用模型声明的可用窗口；放不下时明确报错。输入更多 token，但通常能省去多次摘要请求。',
              AiContextMode.economical =>
                '最多约 6k token 视频片段，历史也会精简；不生成分段摘要。输入较少，但全片概括和全面枚举可能遗漏，请按需切回全文。',
              AiContextMode.segmented =>
                '全片问题先逐段整理全部文稿，再回答。首次较慢且有额外费用，完成记录可供后续复用；细节问题仍检索原文。',
            }, style: const TextStyle(fontSize: 11, height: 1.5)),
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('ai-settings-optimize-tokens'),
            contentPadding: EdgeInsets.zero,
            title: const Text('智能节省 token', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '开启时，普通 API 问答降低思考并限制为最多 4k 输出，详细问题最多 8k，明确深入时沿用配置上限。关闭后沿用所选思考及输出设置；兼容的 API 对话仍会安全复用已发送资料。',
              style: TextStyle(fontSize: 11),
            ),
            value: _optimizeTokens,
            onChanged: _locked
                ? null
                : (value) => _updateSettings(() => _optimizeTokens = value),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('快速总结', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '基础总结关闭可关闭的思考，必须思考时降低等级；其他问题沿用上面的思考设置。关闭可保留总结时的深度思考。',
              style: TextStyle(fontSize: 11),
            ),
            value: _fastSummaries,
            onChanged: _locked
                ? null
                : (value) => _updateSettings(() => _fastSummaries = value),
          ),
          const SizedBox(height: 8),
          if (_api)
            Text(
              '温度 ${temperature.toStringAsFixed(1)} · 越低越稳定',
              style: const TextStyle(fontSize: 12),
            ),
          if (_api)
            Slider(
              value: temperature,
              min: 0,
              max: _temperatureLimit,
              divisions: (_temperatureLimit * 10).toInt(),
              onChanged: (value) => _updateSettings(() => _temperature = value),
            ),
          const Text(
            '系统提示词、标题概括提示词和完整请求内容可在“开发者模式”查看、编辑。',
            style: TextStyle(fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            '思考模式下，部分模型不采用温度设置；DeepSeek、OpenAI 思考模型及原生 Claude、Gemini 会按各自协议处理。',
            style: TextStyle(fontSize: 11, height: 1.5),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          DesktopButtonClickRegion(child: TextButton.icon(
            key: const ValueKey('ai-recommended-settings'),
            onPressed: _locked ? null : _recommended,
            icon: const Icon(Icons.restart_alt, size: 17),
            label: const Text('恢复推荐响应设置'),
          )),
          DesktopButtonClickRegion(child: OutlinedButton.icon(
            onPressed: _locked ? null : _test,
            icon: const Icon(Icons.network_check, size: 18),
            label: Text(_testing ? '测试中…' : '测试连接'),
          )),
        ],
      ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          '模型目录不发送对话 · 连接测试可能计费',
          style: TextStyle(fontSize: 11, height: 1.5),
        ),
      ),
      if (_saveError != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SelectableText(
            '设置未保存：$_saveError',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_status != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SelectableText(
            _status!,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: _statusError
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
    ];
    Widget group(List<Widget> children) => SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
      },
      child: AiAdaptiveDialog(
        maxWidth: 1100,
        maxHeight: 680,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('AI 设置'),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _saveError != null
                          ? '自动保存失败，请重试。'
                          : _invalidSettings
                          ? '输入有误，尚未保存。'
                          : _savingSettings ||
                                (_autoSaveTimer?.isActive ?? false)
                          ? '正在自动保存…'
                          : _didAutoSave
                          ? '已自动保存'
                          : '更改会自动保存',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.normal,
                        color: _saveError != null || _invalidSettings
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.generationInProgress)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '改动从下一次发送生效，当前回答继续使用原设置。',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
                ),
              ),
          ],
        ),
        trailing: canDiscard ? null : closeButton,
        content: Form(
          key: _form,
          onChanged: _scheduleAutoSave,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 760) {
                return group([...connection, ...response]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: group(connection)),
                  const VerticalDivider(width: 33),
                  Expanded(child: group(response)),
                ],
              );
            },
          ),
        ),
        actions: [
          if (_saveError != null)
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _closing ? null : () => unawaited(_saveChanges()),
                child: const Text('重试'),
              ),
            ),
          if (canDiscard) closeButton,
        ],
      ),
    );
  }
}

class AiModelPickerDialog extends StatefulWidget {
  const AiModelPickerDialog({
    super.key,
    required this.models,
    required this.selectedId,
  });
  final List<AiModelInfo> models;
  final String selectedId;
  @override
  State<AiModelPickerDialog> createState() => _AiModelPickerDialogState();
}

enum _CatalogFilter { all, chat, reasoning, vision, code, special }

class _AiModelPickerDialogState extends State<AiModelPickerDialog> {
  String _query = '';
  _CatalogFilter _filter = _CatalogFilter.all;

  bool _matches(AiModelPresentation item, String query) {
    if (query.isNotEmpty) {
      final haystack = [
        item.model.id,
        item.model.displayName,
        item.model.description,
        item.roleLabel,
        item.headline,
        item.ageLabel,
        item.groupTitle,
      ].join(' ').toLowerCase();
      if (!haystack.contains(query)) return false;
    }
    return switch (_filter) {
      _CatalogFilter.all => true,
      _CatalogFilter.chat => item.role == AiModelRole.chat,
      _CatalogFilter.reasoning => item.role == AiModelRole.reasoning,
      _CatalogFilter.vision => item.role == AiModelRole.vision,
      _CatalogFilter.code => item.role == AiModelRole.code,
      _CatalogFilter.special => item.specialized,
    };
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase().trim();
    final presented = presentModels(widget.models);
    final rows = [
      for (final item in presented)
        if (_matches(item, query)) item,
    ];
    final entries = <Object>[];
    String? group;
    for (final item in rows) {
      if (item.groupTitle != group) {
        group = item.groupTitle;
        entries.add(group);
      }
      entries.add(item);
    }
    final scheme = Theme.of(context).colorScheme;
    return AiAdaptiveDialog(
      title: const Text('选择模型'),
      content: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .42,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      key: const ValueKey('ai-model-search'),
                      decoration: const InputDecoration(
                        hintText: '搜索名称、ID、用途，例如 推理 或 嵌入',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final filter in _CatalogFilter.values)
                          ChoiceChip(
                            label: Text(_filterLabel(filter)),
                            visualDensity: VisualDensity.compact,
                            selected: _filter == filter,
                            onSelected: (_) => setState(() => _filter = filter),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${rows.length} 个模型 · 新的在前，专用模型在后',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '上下文来自服务目录。标「约」的是常见公开值，只作参考，不会拿来限制请求。',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('没有匹配的模型，可返回手动填写 ID'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        if (entry is String) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 10, bottom: 4),
                            child: Text(
                              entry,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                              ),
                            ),
                          );
                        }
                        final item = entry as AiModelPresentation;
                        return _ModelRow(
                          item: item,
                          selected: item.model.id == widget.selectedId,
                          onTap: () => Navigator.pop(context, item.model),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        DesktopButtonClickRegion(child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        )),
      ],
    );
  }
}

String _filterLabel(_CatalogFilter filter) => switch (filter) {
  _CatalogFilter.all => '全部',
  _CatalogFilter.chat => '对话',
  _CatalogFilter.reasoning => '推理',
  _CatalogFilter.vision => '视觉',
  _CatalogFilter.code => '代码',
  _CatalogFilter.special => '专用',
};

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AiModelPresentation item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = item.model;
    final contextLabel = item.displayContext == null
        ? null
        : '${item.contextIsEstimate ? '约 ' : ''}${_tokens(item.displayContext!)} 上下文';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? scheme.primary : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      _ModelBadge(
                        item.ageLabel,
                        accent: item.age == AiModelAge.latest,
                      ),
                      _ModelBadge(item.headline),
                      if (contextLabel != null) _ModelBadge(contextLabel),
                      if (model.supportsThinking == true)
                        const _ModelBadge('可思考'),
                    ],
                  ),
                  if (model.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      model.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (model.displayName != model.id ||
                      item.releasedLabel != null ||
                      model.maxOutputTokens != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (model.displayName != model.id) model.id,
                        if (item.releasedLabel != null) item.releasedLabel!,
                        if (model.maxOutputTokens != null)
                          '输出 ${_tokens(model.maxOutputTokens!)}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Icon(Icons.check, size: 18, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelBadge extends StatelessWidget {
  const _ModelBadge(this.text, {this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: accent ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
