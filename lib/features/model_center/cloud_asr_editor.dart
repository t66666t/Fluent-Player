import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../screens/network_settings_screen.dart';
import '../../widgets/capsule_selector.dart';
import 'asr_language_options.dart';
import 'model_catalog.dart';
import 'model_center_service.dart';
import 'cloud_asr_catalog.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class CloudAsrEditor extends StatefulWidget {
  const CloudAsrEditor({
    super.key,
    required this.center,
    required this.provider,
    this.profile,
    this.secret = '',
    this.catalog,
  });
  final ModelCenterService center;
  final CloudAsrProvider provider;
  final ModelServiceProfile? profile;
  final String secret;
  final CloudAsrCatalogStore? catalog;
  @override
  State<CloudAsrEditor> createState() => _CloudAsrEditorState();
}

class _CloudAsrEditorState extends State<CloudAsrEditor> {
  final _form = GlobalKey<FormState>();
  late final _key = TextEditingController(text: widget.secret);
  late final _endpoint = TextEditingController(
    text: widget.profile?.endpoint.isNotEmpty == true
        ? widget.profile!.endpoint
        : widget.provider.endpoint,
  );
  late final _model = TextEditingController(
    text: widget.profile?.model ?? widget.provider.defaultModel,
  );
  late final _hotwords = TextEditingController(
    text: widget.profile?.cloudOptions?.hotwords.join('\n') ?? '',
  );
  late final _name = TextEditingController(
    text: widget.profile?.name ?? widget.provider.label,
  );
  late final _catalog =
      widget.catalog ?? CloudAsrCatalogStore(widget.center.storage);
  CloudAsrCatalog? _models;
  CancelToken? _refreshToken;
  Timer? _keyTimer;
  String? _error, _notice;
  late String _language = widget.profile == null
      ? 'auto'
      : widget.center.languageForProfile(widget.profile!);
  late bool _diarize = widget.profile?.cloudOptions?.diarize ?? false;
  late bool _characters =
      widget.profile?.cloudOptions?.characterTiming ?? false;
  bool _refreshing = false, _showKey = false;

  CloudAsrCapabilities get _capabilities {
    final selected = _models?.models
        .where((m) => m.id == _model.text)
        .firstOrNull;
    return selected?.capabilities ??
        (_model.text == widget.profile?.model
            ? widget.profile?.cloudCapabilities
            : null) ??
        cloudAsrCapabilities(widget.provider, _model.text);
  }

  CloudAsrConnection get _connection => CloudAsrConnection(
    provider: widget.provider,
    endpoint: _endpoint.text.trim(),
    model: _model.text.trim(),
    apiKey: _key.text.trim(),
    capabilities: _capabilities,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final connection = _connection;
    final value = await _catalog.load(connection);
    if (!mounted ||
        connection.endpoint != _endpoint.text.trim() ||
        connection.apiKey != _key.text.trim()) {
      return;
    }
    setState(() => _models = value);
    if (value.stale && _key.text.trim().isNotEmpty) await _refresh();
  }

  Future<void> _refresh() async {
    if (_key.text.trim().isEmpty) {
      setState(() => _error = '填写 API Key 后可查询厂商模型列表');
      return;
    }
    _refreshToken?.cancel();
    final token = _refreshToken = CancelToken();
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final result = await _catalog.refresh(_connection, token);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _models = result;
        _notice = result.remote
            ? '模型列表已更新，当前选择保持不变；这不是音频转录测试。'
            : '厂家未提供完整转录模型枚举，保留官方清单；新模型可在高级设置填写 ID。';
      });
    } catch (_) {
      if (mounted && !token.isCancelled) {
        setState(() => _error = '模型列表更新失败，已有列表和当前选择保留。请检查密钥或云端转录网络设置。');
      }
    } finally {
      if (mounted && identical(token, _refreshToken)) {
        setState(() => _refreshing = false);
      }
    }
  }

  void _modelChanged(String id) {
    setState(() {
      if (_model.text != id) _model.text = id;
      final capabilities = _capabilities;
      if (!capabilities.languages.contains(_language)) _language = 'auto';
      if (!capabilities.speakers) _diarize = false;
      if (!capabilities.characters) _characters = false;
      if (capabilities.maxHotwords == 0) _hotwords.clear();
    });
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    try {
      if (_model.text.trim().isEmpty || _model.text.contains(RegExp(r'\s'))) {
        throw StateError('请填写有效模型 ID');
      }
      _connection.url('/');
      final words = _hotwords.text
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      final options = CloudAsrOptions(
        diarize: _diarize,
        characterTiming: _characters,
        hotwords: words,
      );
      options.validate(widget.provider, _capabilities);
      final language = _capabilities.languages.contains(_language)
          ? _language
          : 'auto';
      Navigator.pop(context, (
        ModelServiceProfile(
          id:
              widget.profile?.id ??
              'service-${DateTime.now().microsecondsSinceEpoch}',
          name: _name.text.trim().isEmpty
              ? widget.provider.label
              : _name.text.trim(),
          kind: TranscriptionServiceKind.values.byName(widget.provider.name),
          endpoint: _endpoint.text.trim(),
          model: _model.text.trim(),
          language: language,
          cloudOptions: options,
          cloudCapabilities: _capabilities,
        ),
        _key.text.trim(),
      ));
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _keyTimer?.cancel();
    _refreshToken?.cancel();
    for (final controller in [_key, _model, _endpoint, _hotwords, _name]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caps = _capabilities;
    final ids = <String>{
      _model.text,
      ...(_models?.models ?? builtinCloudAsrModels(widget.provider))
          .where((m) => m.available)
          .map((m) => m.id),
    }.where((id) => id.isNotEmpty).toList();
    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 8),
          DesktopButtonClickRegion(
            child: FilledButton(
              key: const ValueKey('cloud-asr-save'),
              onPressed: _save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
    final body = Form(
      key: _form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.provider.label} · 云端转录',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('音频由软件直接上传，无需准备存储或链接。使用你自己的账号，按厂家规则计费。'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                suffixIcon: DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                    onPressed: () => setState(() => _showKey = !_showKey),
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              validator: (s) =>
                  s == null || s.trim().isEmpty ? '请填写 API Key' : null,
              onChanged: (_) {
                _refreshToken?.cancel();
                setState(() {
                  _models = null;
                  _refreshing = false;
                });
                _keyTimer?.cancel();
                _keyTimer = Timer(const Duration(milliseconds: 900), () {
                  if (mounted && _key.text.trim().isNotEmpty) {
                    unawaited(_load());
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            CapsuleDropdownButtonFormField<String>(
              key: ValueKey('cloud-model-${_model.text}'),
              initialValue: ids.contains(_model.text) ? _model.text : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '转录模型'),
              items: [
                for (final id in ids)
                  DropdownMenuItem(
                    value: id,
                    child: Text(id, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) {
                if (id != null) _modelChanged(id);
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButtonClickRegion(
                child: TextButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(_refreshing ? '正在更新模型…' : '刷新模型列表'),
                ),
              ),
            ),
            if (!caps.documented) const Text('新模型能力尚未确认：基础转录沿用厂家协议，附加功能默认关闭。'),
            CapsuleDropdownButtonFormField<String>(
              key: ValueKey('cloud-language-${_model.text}-$_language'),
              initialValue: caps.languages.contains(_language)
                  ? _language
                  : 'auto',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '识别语言'),
              items: [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text(
                    widget.provider == CloudAsrProvider.deepgram &&
                            !caps.automaticLanguage
                        ? '模型默认语言'
                        : '自动识别',
                  ),
                ),
                for (final code in caps.languages)
                  DropdownMenuItem(
                    value: code,
                    child: Text(
                      cloudAsrLanguageLabel(code),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _language = value ?? 'auto'),
            ),
            const SizedBox(height: 12),
            Text(
              caps.wordTimestamps
                  ? '默认保留词级时间轴，用于字幕分句和逐词显示。'
                  : '会请求词级时间轴；新模型须返回有效时间信息才能生成字幕。',
            ),
            ExpansionTile(
              title: const Text('高级设置'),
              tilePadding: EdgeInsets.zero,
              children: [
                if (caps.characters)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('字符级时间轴'),
                    value: _characters,
                    onChanged: (value) => setState(() => _characters = value),
                  ),
                if (caps.speakers)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('区分说话人'),
                    subtitle: const Text('部分厂家另行收费，默认关闭'),
                    value: _diarize,
                    onChanged: (value) => setState(() => _diarize = value),
                  ),
                TextFormField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '模型 ID',
                    helperText: '可填写尚未收录的新模型；不会自动更换已选模型',
                  ),
                  validator: (s) =>
                      s == null || s.trim().isEmpty || s.contains(RegExp(r'\s'))
                      ? '请填写有效模型 ID'
                      : null,
                  onChanged: _modelChanged,
                ),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: '服务名称'),
                ),
                TextFormField(
                  controller: _endpoint,
                  decoration: const InputDecoration(labelText: '服务根地址'),
                  onChanged: (_) {
                    _refreshToken?.cancel();
                    setState(() {
                      _models = null;
                      _notice = null;
                      _refreshing = false;
                    });
                  },
                ),
                if (caps.maxHotwords > 0)
                  TextFormField(
                    controller: _hotwords,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: '热词／术语（每行一条）',
                      helperText: '最多 ${caps.maxHotwords} 条，部分厂家额外收费；默认不填写',
                    ),
                  ),
                if (widget.provider == CloudAsrProvider.gemini)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('字幕使用词级时间戳，因此不启用与其互斥的热词或 Smart 整理。'),
                  ),
              ],
            ),
            DesktopButtonClickRegion(
              child: TextButton.icon(
                onPressed: () => openNetworkSettings(context),
                icon: const Icon(Icons.public),
                label: const Text('云端转录网络设置 · 默认跟随设备网络'),
              ),
            ),
            if (_notice != null)
              Text(_notice!, style: Theme.of(context).textTheme.bodySmall),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    return MediaQuery.sizeOf(context).width < 600
        ? Scaffold(
            appBar: AppBar(title: const Text('云端转录接口')),
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(child: body),
                  actions,
                ],
              ),
            ),
          )
        : Dialog(
            child: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: body),
                  actions,
                ],
              ),
            ),
          );
  }
}
