import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../features/ai_chat/ai_chat_transport.dart';
import '../services/ai_subtitle_api_settings.dart';
import '../services/ai_api_connection_sync.dart';
import '../services/network/network_http.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Compact endpoint editor shared by subtitle optimization and translation.
///
/// The fields stay short on purpose: provider, address, key, then the model
/// list filled by a connection check. Chat settings are a different window.
class AiSubtitleApiDialog extends StatelessWidget {
  const AiSubtitleApiDialog({
    super.key,
    required this.settings,
    this.transport,
    this.title = '优化/翻译接口',
  });
  final AiSubtitleApiSettings settings;
  final AiChatTransport? transport;
  final String title;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return DialogKeyboardViewport(
      child: Dialog(
        insetAnimationDuration: Duration.zero,
        backgroundColor: const Color(0xFF2C2C2C),
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(340, size.width - 32),
            maxHeight: math.min(420, size.height - 48),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: AiSubtitleApiEditor(
              settings: settings,
              transport: transport,
              title: title,
              onSaved: (value) => Navigator.pop(context, value),
              onCancel: () => Navigator.pop(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// The same endpoint form can be embedded in optimization model settings.
class AiSubtitleApiEditor extends StatefulWidget {
  const AiSubtitleApiEditor({
    super.key,
    required this.settings,
    required this.onSaved,
    this.onCancel,
    this.transport,
    this.title = '优化/翻译接口',
    this.saveLabel = '保存',
  });
  final AiSubtitleApiSettings settings;
  final ValueChanged<AiSubtitleApiSettings> onSaved;
  final VoidCallback? onCancel;
  final AiChatTransport? transport;
  final String title, saveLabel;
  @override
  State<AiSubtitleApiEditor> createState() => _AiSubtitleApiEditorState();
}

class _AiSubtitleApiEditorState extends State<AiSubtitleApiEditor> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late String _providerId;
  late List<String> _models;
  late Map<String, AiSubtitleApiProfile> _profiles;
  late final AiChatTransport _transport;
  final _keyFocus = FocusNode();
  late String _lastKeyText, _lastUrlText;
  bool _keyEdited = false;
  int _sharedFillEpoch = 0;
  String? _automaticKey, _automaticIdentity;
  ({String url, String key})? _lastCheck;
  bool _reveal = false;
  bool _checking = false;
  bool _applyingPreset = false;
  String? _status;
  bool _statusError = false;
  AiChatCancellation? _checkCancellation;

  @override
  void initState() {
    super.initState();
    final settings = widget.settings.normalized();
    _providerId = settings.providerId;
    _profiles = <String, AiSubtitleApiProfile>{
      for (final entry in settings.profiles.entries) entry.key: entry.value,
    };
    _url = TextEditingController(text: settings.baseUrl);
    _key = TextEditingController(text: settings.apiKey);
    _lastKeyText = _key.text;
    _lastUrlText = _url.text;
    _model = TextEditingController(text: settings.model);
    _models = List.of(settings.models);
    _transport =
        widget.transport ??
        AiChatTransport(
          httpClientFactory: () => NetworkHttp.instance.createClient(
            scope: NetworkScope.translation,
            cancelOnChange: false,
          ),
        );
    _url.addListener(_onUrlEdited);
    _key.addListener(_onKeyEdited);
    _keyFocus.addListener(_onKeyFocusChanged);
    unawaited(_fillSharedConnection());
  }

  @override
  void dispose() {
    _checkCancellation?.cancel();
    _url.removeListener(_onUrlEdited);
    _key.removeListener(_onKeyEdited);
    _keyFocus.removeListener(_onKeyFocusChanged);
    _keyFocus.dispose();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  AiSubtitleApiSettings get _draft => AiSubtitleApiSettings(
    connectionId: widget.settings.connectionId,
    providerId: _providerId,
    baseUrl: _url.text,
    apiKey: _key.text,
    model: _model.text,
    models: _models,
    profiles: _profiles,
  ).normalized();

  /// Keeps the fields on screen under the service they belong to, so switching
  /// away and back restores that service instead of the one currently visible.
  void _rememberActive() {
    _profiles[_providerId] = AiSubtitleApiProfile(
      baseUrl: _url.text,
      apiKey: _key.text,
      model: _model.text,
      models: List<String>.of(_models),
    );
  }

  void _onUrlEdited() {
    if (_url.text == _lastUrlText) return;
    _lastUrlText = _url.text;
    if (_applyingPreset) return;
    _invalidateCheck();
    final identity = aiApiConnectionIdentity(
      _draft.baseUrl,
      _draft.protocol.name,
    );
    if (_automaticIdentity != null &&
        identity != _automaticIdentity &&
        _key.text == _automaticKey) {
      _applyingPreset = true;
      _key.clear();
      _keyEdited = false;
      _applyingPreset = false;
      _automaticKey = null;
      _automaticIdentity = null;
    }
    unawaited(_fillSharedConnection());
    final matched = _draft.providerId;
    if (matched == _providerId) return;
    _rememberActive();
    setState(() => _providerId = matched);
  }

  Future<void> _fillSharedConnection() async {
    final epoch = ++_sharedFillEpoch;
    if (_key.text.isNotEmpty) return;
    final draft = _draft;
    final identity = aiApiConnectionIdentity(
      draft.baseUrl,
      draft.protocol.name,
    );
    if (identity == null) return;
    try {
      final shared = await AiSubtitleApiSettingsStore().sharedConnectionFor(
        draft,
      );
      if (!mounted ||
          epoch != _sharedFillEpoch ||
          shared == null ||
          _key.text.isNotEmpty ||
          identity !=
              aiApiConnectionIdentity(_draft.baseUrl, _draft.protocol.name)) {
        return;
      }
      setState(() {
        _applyingPreset = true;
        _key.text = shared.apiKey;
        if (_model.text.isEmpty) _model.text = shared.model;
        if (_models.isEmpty) _models = List.of(shared.models);
        _automaticKey = shared.apiKey;
        _automaticIdentity = identity;
        _keyEdited = false;
        _applyingPreset = false;
      });
    } catch (_) {
      // A failed optional autofill never replaces the user's explicit input.
    }
  }

  void _invalidateCheck() {
    _checkCancellation?.cancel();
    _lastCheck = null;
    setState(() {
      _checking = false;
      _status = null;
    });
  }

  void _onKeyEdited() {
    if (_key.text == _lastKeyText) return;
    _lastKeyText = _key.text;
    if (_applyingPreset) return;
    _sharedFillEpoch++;
    _automaticKey = null;
    _automaticIdentity = null;
    _keyEdited = true;
    _invalidateCheck();
  }

  void _onKeyFocusChanged() {
    if (!_keyFocus.hasFocus &&
        _keyEdited &&
        _key.text.trim().isNotEmpty &&
        (Uri.tryParse(_draft.baseUrl)?.host.isNotEmpty ?? false)) {
      unawaited(_checkConnection());
    }
  }

  void _selectProvider(String? id) {
    if (id == null || id == _providerId) return;
    _invalidateCheck();
    _keyEdited = false;
    _rememberActive();
    final remembered = _profiles[id];
    final preset = AiSubtitleApiPreset.byId(id);
    setState(() {
      _applyingPreset = true;
      _providerId = id;
      if (remembered != null) {
        _url.text = remembered.baseUrl;
        _key.text = remembered.apiKey;
        _model.text = remembered.model;
        _models = List<String>.of(remembered.models);
      } else if (preset.id == AiSubtitleApiPreset.custom.id) {
        _url.clear();
        _key.clear();
        _model.clear();
        _models = <String>[];
      } else {
        _url.text = preset.baseUrl;
        _key.clear();
        _model.clear();
        _models = <String>[];
      }
      _status = null;
      _applyingPreset = false;
    });
    unawaited(_fillSharedConnection());
  }

  Future<void> _checkConnection() async {
    final draft = _draft;
    final identity = (url: draft.baseUrl, key: draft.apiKey);
    if (_checking && _lastCheck == identity) return;
    final host = Uri.tryParse(draft.baseUrl)?.host ?? '';
    if (host.isEmpty) {
      setState(() {
        _status = '请先填写接口地址。';
        _statusError = true;
      });
      return;
    }
    _checkCancellation?.cancel();
    _lastCheck = identity;
    _keyEdited = false;
    final cancellation = AiChatCancellation();
    _checkCancellation = cancellation;
    setState(() {
      _checking = true;
      _status = '正在检查连接…';
      _statusError = false;
    });
    try {
      final found = await _transport.fetchModels(
        draft.toChatSettings(),
        cancellation: cancellation,
      );
      if (!mounted || cancellation.isCancelled) return;
      final ids = <String>[
        for (final info in found)
          if (info.id.trim().isNotEmpty) info.id.trim(),
      ];
      setState(() {
        _models = ids;
        if (ids.isNotEmpty && !ids.contains(_model.text.trim())) {
          _model.text = ids.first;
        }
        _status = ids.isEmpty ? '已连通，但没有返回模型，请直接填写模型名。' : '已连通，可以选择模型。';
        _statusError = false;
        _checking = false;
      });
    } catch (error) {
      if (!mounted || cancellation.isCancelled) return;
      final message = error is AiChatException ? error.message : '$error';
      setState(() {
        _status = message;
        _statusError = true;
        _checking = false;
      });
    }
  }

  void _save() {
    _rememberActive();
    final draft = _draft;
    if (!draft.ready) {
      setState(() {
        _status = '请填写接口地址和模型。';
        _statusError = true;
      });
      return;
    }
    widget.onSaved(draft);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        widget.title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 2),
      const Text(
        '优化和翻译可共用此接口，也可分别选择。',
        style: TextStyle(color: Colors.white54, fontSize: 11),
      ),
      const SizedBox(height: 10),
      CapsuleDropdownButtonFormField<String>(
        key: ValueKey('subtitle-api-provider-$_providerId'),
        initialValue: _providerId,
        isDense: true,
        decoration: _decoration('服务商'),
        dropdownColor: const Color(0xFF2A2A2A),
        style: _fieldText,
        items: [
          for (final preset in AiSubtitleApiPreset.all)
            DropdownMenuItem(
              value: preset.id,
              child: Text(preset.label, style: const TextStyle(fontSize: 13)),
            ),
        ],
        onChanged: _selectProvider,
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('subtitle-api-url'),
        controller: _url,
        style: _fieldText,
        decoration: _decoration('接口地址'),
      ),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('subtitle-api-key'),
        controller: _key,
        focusNode: _keyFocus,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => unawaited(_checkConnection()),
        obscureText: !_reveal,
        style: _fieldText,
        decoration: _decoration('API Key').copyWith(
          suffixIcon: DesktopButtonClickRegion(
            child: IconButton(
              tooltip: _reveal ? '隐藏密钥' : '显示密钥',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _reveal = !_reveal),
              icon: Icon(
                _reveal
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16,
                color: Colors.white54,
              ),
            ),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 2, bottom: 8),
        child: Text(
          '输入密钥后移出输入框或按 Enter 自动检查。本地服务可不填密钥。',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ),
      TextField(
        key: const ValueKey('subtitle-api-model'),
        controller: _model,
        enabled: !_checking,
        style: _fieldText,
        decoration: _decoration('模型').copyWith(
          suffixIcon: _models.length < 2
              ? null
              : CapsulePopupMenuButton<String>(
                  tooltip: '选择模型',
                  enabled: !_checking,
                  color: const Color(0xFF2A2A2A),
                  onSelected: (value) => setState(() => _model.text = value),
                  itemBuilder: (context) => [
                    for (final id in _models)
                      PopupMenuItem(
                        value: id,
                        child: Text(
                          id,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                  icon: const Icon(
                    Icons.arrow_drop_down,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
        ),
      ),
      if (_status != null) ...[
        const SizedBox(height: 8),
        Text(
          _status!,
          style: TextStyle(
            color: _statusError ? Colors.orange : Colors.white60,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ],
      const SizedBox(height: 10),
      DesktopButtonClickRegion(
        child: FilledButton.icon(
          key: const ValueKey('subtitle-api-check'),
          onPressed: _checking ? null : _checkConnection,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(40),
            backgroundColor: const Color(0xFFFA586A),
            foregroundColor: Colors.black,
          ),
          icon: _checking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check_rounded, size: 18),
          label: Text(_checking ? '检查中…' : '检查连接'),
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          const Spacer(),
          if (widget.onCancel != null)
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: widget.onCancel,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.white54,
                ),
                child: const Text('取消', style: TextStyle(fontSize: 12)),
              ),
            ),
          const SizedBox(width: 4),
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: _checking ? null : _save,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFFFA586A),
              ),
              child: Text(
                widget.saveLabel,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

const _fieldText = TextStyle(color: Colors.white, fontSize: 13);

InputDecoration _decoration(String label) => InputDecoration(
  labelText: label,
  isDense: true,
  labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  border: const OutlineInputBorder(),
  enabledBorder: OutlineInputBorder(
    borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
  ),
);
