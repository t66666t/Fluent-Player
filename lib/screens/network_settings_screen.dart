import 'dart:async';

import 'package:flutter/material.dart';

import '../services/network/network_models.dart';
import '../services/network/network_settings_service.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> openNetworkSettings(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const NetworkSettingsScreen()));

class NetworkSettingsScreen extends StatefulWidget {
  final NetworkSettingsService? service;
  const NetworkSettingsScreen({super.key, this.service});
  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  late final NetworkSettingsService _service =
      widget.service ?? NetworkSettingsService.instance;
  final _form = GlobalKey<FormState>();
  final _proxyCard = GlobalKey();
  final _scroll = ScrollController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final Map<NetworkScope, NetworkMode> _pending = {};
  final Map<NetworkScope, int> _sequences = {};
  ProxyProtocol _protocol = ProxyProtocol.http;
  NetworkScope? _applyTo;
  bool _applyGlobally = false;
  bool _expanded = false;
  bool _keepPassword = false;
  bool _editing = false;
  bool _savingProxy = false;
  int _unifiedSequence = 0;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _service.ready;
    } catch (_) {
      /* The page shows the load error. */
    }
    if (mounted) {
      _fillForm();
      setState(() {});
    }
  }

  void _fillForm() {
    if (_editing) return;
    final proxy = _service.configuration.proxy;
    _protocol = proxy?.protocol ?? ProxyProtocol.http;
    _host.text = proxy?.host ?? '';
    _port.text = '${proxy?.port ?? 7890}';
    _username.text = proxy?.username ?? '';
    _keepPassword = proxy?.credentialKey != null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _select(NetworkScope scope, NetworkMode mode) async {
    if (mode == NetworkMode.custom && _service.configuration.proxy == null) {
      setState(() {
        _expanded = true;
        _applyTo = scope;
        _applyGlobally = false;
      });
      _revealProxy();
      return;
    }
    final sequence = (_sequences[scope] ?? 0) + 1;
    setState(() {
      _sequences[scope] = sequence;
      _pending[scope] = mode;
    });
    try {
      await _service.setMode(scope, mode);
    } catch (_) {
      if (mounted) _showError();
    } finally {
      if (mounted && _sequences[scope] == sequence) {
        setState(() => _pending.remove(scope));
      }
    }
  }

  void _revealProxy() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final target = _proxyCard.currentContext;
    if (target != null) {
      unawaited(Scrollable.ensureVisible(target));
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _proxyCard.currentContext;
        if (mounted && target != null) {
          unawaited(Scrollable.ensureVisible(target));
        }
      });
    }
  });

  Future<void> _selectUnified(String value) async {
    setState(() => _unifiedSequence++);
    final mode = value == 'features' ? null : NetworkMode.values.byName(value);
    if (mode == NetworkMode.custom && _service.configuration.proxy == null) {
      setState(() {
        _expanded = true;
        _applyTo = null;
        _applyGlobally = true;
      });
      _revealProxy();
      return;
    }
    setState(() {
      _applyTo = null;
      _applyGlobally = false;
    });
    try {
      await _service.setUnifiedMode(mode);
    } catch (_) {
      if (mounted) _showError();
    }
  }

  void _showError() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(_service.error ?? '保存失败，请重试')));

  Future<void> _saveProxy() async {
    if (!_form.currentState!.validate() || _savingProxy) return;
    setState(() => _savingProxy = true);
    try {
      await _service.saveProxy(
        profile: ProxyProfile(
          protocol: _protocol,
          host: _host.text.trim(),
          port: int.parse(_port.text),
          username: _username.text.trim().isEmpty
              ? null
              : _username.text.trim(),
        ),
        password: _password.text,
        keepExistingPassword: _keepPassword && _password.text.isEmpty,
        applyTo: _applyTo,
        applyGlobally: _applyGlobally,
      );
      if (mounted) {
        setState(() {
          _password.clear();
          _editing = false;
          _applyTo = null;
          _applyGlobally = false;
          _expanded = false;
          _fillForm();
        });
      }
    } catch (_) {
      if (mounted) _showError();
    } finally {
      if (mounted) setState(() => _savingProxy = false);
    }
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    _scroll.dispose();
    for (final controller in [_host, _port, _username, _password]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loading = _service.state == NetworkSaveState.loading;
    final saving = _service.state == NetworkSaveState.saving;
    final unified = _service.configuration.unifiedMode;
    final loadFailed =
        _service.state == NetworkSaveState.failed && !_service.isLoaded;
    return Scaffold(
      appBar: AppBar(title: const Text('网络设置')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(20),
              children: [
                const Text('可统一设置网络方式，也可按功能分别设置。保存后，新建连接使用新设置，正在进行的传输会尽量继续完成。'),
                const SizedBox(height: 8),
                Text(
                  switch (_service.state) {
                    NetworkSaveState.loading => '正在加载…',
                    NetworkSaveState.saving => '正在保存…',
                    NetworkSaveState.applied => '已应用',
                    NetworkSaveState.failed => _service.error ?? '保存失败',
                  },
                  key: const ValueKey('network-save-state'),
                  style: TextStyle(
                    color: _service.state == NetworkSaveState.failed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (loadFailed)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () async {
                        try {
                          await _service.retryLoad();
                          if (mounted) {
                            _fillForm();
                            setState(() {});
                          }
                        } catch (_) {}
                      },
                      child: const Text('重新加载'),
                    ),
                  ),
                const SizedBox(height: 16),
                CapsuleDropdownButtonFormField<String>(
                  key: ValueKey(
                    'network-unified-${unified?.name ?? 'features'}-$_unifiedSequence',
                  ),
                  initialValue: unified?.name ?? 'features',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '整体网络方式',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'features',
                      child: Text('按功能分别设置（默认）'),
                    ),
                    for (final mode in NetworkMode.values)
                      DropdownMenuItem(
                        value: mode.name,
                        child: Text(
                          '统一${mode == NetworkMode.custom ? '使用' : ''}${mode.label}',
                        ),
                      ),
                  ],
                  onChanged: loading || loadFailed || saving
                      ? null
                      : (value) {
                          if (value != null) unawaited(_selectUnified(value));
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  unified == null
                      ? '国内服务默认不使用系统代理，国外及其他服务默认跟随设备网络。'
                      : '学习服务和播客统一${unified == NetworkMode.custom ? '使用' : ''}${unified.label}。切回按功能分别设置后，恢复原有分项选择。',
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(unified == null ? '播客 · 自动连接' : '播客 · 使用统一设置'),
                  subtitle: Text(
                    unified == null
                        ? '国内来源优先直连，海外来源优先跟随设备网络；连接故障时有限尝试备用线路。也可在上方选择统一网络方式。'
                        : '播客订阅、搜索、封面、播放和下载均使用统一网络方式。',
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  key: _proxyCard,
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('自定义代理'),
                        subtitle: Text(
                          _applyGlobally
                              ? '保存后，所有功能统一使用此代理'
                              : _applyTo == null
                              ? '所有选择自定义代理的功能共用这一配置'
                              : '保存后应用于${_applyTo!.label}',
                        ),
                        trailing: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                        ),
                        onTap:
                            loading ||
                                (loadFailed && !_service.canReplaceCredentials)
                            ? null
                            : () => setState(() => _expanded = !_expanded),
                      ),
                      if (_expanded)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Form(
                            key: _form,
                            onChanged: () => _editing = true,
                            child: Column(
                              children: [
                                CapsuleDropdownButtonFormField<ProxyProtocol>(
                                  initialValue: _protocol,
                                  decoration: const InputDecoration(
                                    labelText: '类型',
                                  ),
                                  items: [
                                    for (final value in ProxyProtocol.values)
                                      DropdownMenuItem(
                                        value: value,
                                        child: Text(value.name.toUpperCase()),
                                      ),
                                  ],
                                  onChanged: _savingProxy
                                      ? null
                                      : (value) =>
                                            setState(() => _protocol = value!),
                                ),
                                TextFormField(
                                  controller: _host,
                                  decoration: const InputDecoration(
                                    labelText: '代理主机',
                                    hintText:
                                        '例如 127.0.0.1 或 proxy.example.com',
                                  ),
                                  autocorrect: false,
                                  validator: (value) {
                                    try {
                                      ProxyProfile(
                                        protocol: _protocol,
                                        host: value!.trim(),
                                        port: 1,
                                      ).validate();
                                      return null;
                                    } catch (_) {
                                      return '请输入主机名或 IP 地址，地址不含类型和端口';
                                    }
                                  },
                                ),
                                TextFormField(
                                  controller: _port,
                                  decoration: const InputDecoration(
                                    labelText: '端口',
                                  ),
                                  keyboardType: TextInputType.number,
                                  validator: (value) {
                                    final port = int.tryParse(value ?? '');
                                    return port == null ||
                                            port < 1 ||
                                            port > 65535
                                        ? '端口须在 1 至 65535 之间'
                                        : null;
                                  },
                                ),
                                TextFormField(
                                  controller: _username,
                                  decoration: const InputDecoration(
                                    labelText: '账号（可选）',
                                  ),
                                  autocorrect: false,
                                  enableSuggestions: false,
                                ),
                                TextFormField(
                                  controller: _password,
                                  decoration: const InputDecoration(
                                    labelText: '密码（可选）',
                                  ),
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                ),
                                if (_service
                                        .configuration
                                        .proxy
                                        ?.credentialKey !=
                                    null)
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('留空时使用已保存的密码'),
                                    value: _keepPassword,
                                    onChanged: (value) =>
                                        setState(() => _keepPassword = value!),
                                  ),
                                const SizedBox(height: 12),
                                DesktopButtonClickRegion(
                                  child: FilledButton(
                                    onPressed: _savingProxy ? null : _saveProxy,
                                    child: Text(
                                      _savingProxy ? '正在保存…' : '保存代理配置',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (unified == null) ...[
                  for (final scope in const [
                    NetworkScope.speechRecognition,
                    NetworkScope.cloudTranscription,
                    NetworkScope.translation,
                    NetworkScope.updates,
                    NetworkScope.modelDownloads,
                    NetworkScope.other,
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            scope.label,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          CapsuleDropdownButtonFormField<NetworkMode>(
                            key: ValueKey(
                              'network-mode-${scope.name}-${_pending[scope] ?? _service.configuration.modes[scope]}-${_applyTo?.name ?? ''}',
                            ),
                            initialValue:
                                _pending[scope] ??
                                _service.configuration.modes[scope],
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: [
                              for (final mode in NetworkMode.values)
                                DropdownMenuItem(
                                  value: mode,
                                  child: Text(mode.label),
                                ),
                            ],
                            onChanged: loading || loadFailed || saving
                                ? null
                                : (value) {
                                    if (value != null) {
                                      unawaited(_select(scope, value));
                                    }
                                  },
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                const Text(
                  '语音识别遇到连接或上传授权异常时，会有限重试，并在需要时为当前转录临时尝试不使用系统代理。'
                  '这不会更改整体网络设置或字幕翻译的线路。',
                ),
                const SizedBox(height: 8),
                const Text(
                  '“不使用系统代理”仍使用设备的网络路由。接管全部流量的 VPN 可能继续影响连接。'
                  '访问局域网代理时，设备可能请求本地网络权限。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
