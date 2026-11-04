import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/library_service.dart';
import '../../theme/app_interaction_theme.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/desktop_button_click_region.dart';
import '../../widgets/capsule_selector.dart';
import '../../utils/app_data_paths.dart';
import 'external_ai_clients.dart';
import 'external_ai_controller.dart';
import 'external_ai_connection_status.dart';
import 'external_ai_preferences.dart';

class ExternalAiScreen extends StatefulWidget {
  const ExternalAiScreen({super.key, this.controller});
  final ExternalAiController? controller;
  @override
  State<ExternalAiScreen> createState() => _ExternalAiScreenState();
}

class _ExternalAiScreenState extends State<ExternalAiScreen> {
  late final controller = widget.controller ?? ExternalAiController.instance;
  final _scroll = ScrollController();
  ExternalAiClient? _client;
  String? _prompt, _previewError, _message;
  Object? _previewIdentity;
  int _previewGeneration = 0;
  bool _preparing = false, _copying = false, _installing = false;
  bool _expanded = false, _messageError = false;
  bool get _working => controller.busy || _copying || _installing;
  bool get _canCopy =>
      controller.running && !_working && !_preparing && _prompt != null;
  String get _serverName => kAppDataFolderName.endsWith('Community')
      ? 'fluent_player_community'
      : 'fluent_player';
  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);
  static const _curve = Cubic(.2, .8, .2, 1);

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    LibraryService().addListener(_libraryChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await controller.initialize(LibraryService());
    if (mounted) {
      _client ??= ExternalAiClient.values
          .where(
            (c) =>
                c.name == controller.preferences?.preferredClient &&
                c != ExternalAiClient.claudeDesktop,
          )
          .firstOrNull;
      _changed();
    }
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (!controller.busy) _refreshPreview();
  }

  void _refreshPreview({bool force = false}) {
    final p = controller.preferences;
    final identity = (
      _client,
      controller.running,
      controller.endpoint?.toString(),
      p?.token,
      p?.scopeFolderId,
      p?.includeConversations,
      p?.allowTaskControl,
      p?.allowSubtitleWrite,
      p?.autoTaskDecisions,
      p?.autoModelDownloads,
      p?.autoRemoteProcessing,
    );
    if (!force && identity == _previewIdentity) return;
    _previewIdentity = identity;
    final generation = ++_previewGeneration;
    setState(() {
      _prompt = null;
      _previewError = null;
      _preparing = controller.running && _client != null;
    });
    final client = _client;
    if (!controller.running || client == null) return;
    unawaited(_prepare(generation, client));
  }

  Future<void> _prepare(int generation, ExternalAiClient client) async {
    try {
      final prompt = await controller.connectionPrompt(client);
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _prompt = prompt;
        _preparing = false;
      });
    } catch (_) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _preparing = false;
        _previewError = '提示词暂时无法生成，请检查连接和存储位置后重试。';
      });
    }
  }

  @override
  void dispose() {
    ++_previewGeneration;
    controller.removeListener(_changed);
    LibraryService().removeListener(_libraryChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _notice(String message, {bool error = false}) {
    if (mounted) {
      setState(() {
        _message = message;
        _messageError = error;
      });
    }
  }

  Future<void> _copyPrompt() async {
    if (!_canCopy) return;
    // Copy exactly what is previewed; never regenerate a different document.
    final prompt = _prompt!;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(ClipboardData(text: prompt));
      _notice(
        '已复制给 ${externalAiClientInfo(_client!).label} 的完整提示词。请按下方步骤完成信任、启用和验证。',
      );
    } catch (_) {
      _notice('复制失败，请重试。你也可以展开全文后手动选取。', error: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _copyConfig() async {
    final client = _client;
    if (client == null) return;
    try {
      final config = externalAiClientConfiguration(
        client,
        endpoint: controller.endpoint!,
        token: controller.preferences!.token,
        serverName: _serverName,
      );
      await Clipboard.setData(ClipboardData(text: config));
      _notice('已复制连接配置。按下方提示在 Agent 中添加。');
    } catch (_) {
      _notice('复制配置失败，请重试。', error: true);
    }
  }

  Future<void> _install() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _installing = true;
      _message = null;
    });
    try {
      final result = await installExternalAiClient(
        client,
        endpoint: controller.endpoint!,
        token: controller.preferences!.token,
        serverName: _serverName,
      );
      _notice(
        result.changed
            ? '配置已保存，原文件已备份。尚未验证连接，请继续完成下方的客户端步骤。'
            : '配置已存在，尚未验证连接。请继续完成下方的客户端步骤。',
      );
    } on FormatException catch (e) {
      _notice(
        e.source == null ? e.message : '客户端配置格式有误，原文件已保留。请在客户端检查配置。',
        error: true,
      );
    } catch (_) {
      _notice('未能自动添加，已有配置已保留。可以改用“复制配置”。', error: true);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = appInteractionTheme(
      base.copyWith(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppTokens.bgBase,
        colorScheme: const ColorScheme.dark(
          primary: AppTokens.accent,
          onPrimary: Colors.white,
          surface: AppTokens.bgRaised,
          onSurface: AppTokens.text1,
          secondary: AppTokens.accent,
          outline: Color(0x26FFFFFF),
          outlineVariant: AppTokens.lineSubtle,
          error: AppTokens.danger,
        ),
        textTheme: base.textTheme.apply(
          bodyColor: AppTokens.text1,
          displayColor: AppTokens.text1,
        ),
        dividerColor: AppTokens.lineSubtle,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppTokens.bgBase,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          labelStyle: const TextStyle(fontSize: 12, color: AppTokens.text2),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.text1,
            textStyle: base.textTheme.labelLarge!.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF303030),
            disabledForegroundColor: AppTokens.text2,
            minimumSize: const Size(0, 42),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: base.textTheme.labelLarge!.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            foregroundColor: AppTokens.text1,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            elevation: 0,
            toolbarHeight: 48,
            title: const Text(
              '连接外部 AI',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final padding = constraints.maxWidth < 600 ? 12.0 : 20.0;
                final contentWidth = (constraints.maxWidth - padding * 2).clamp(
                  0.0,
                  1120.0,
                );
                final wide =
                    constraints.maxWidth >= 1000 && contentWidth / scale >= 760;
                return Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(padding, 8, padding, 20),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _connectionStatus(),
                            const SizedBox(height: 14),
                            if (controller.error != null) ...[
                              _Notice(controller.error!, error: true),
                              const SizedBox(height: 16),
                            ],
                            if (wide)
                              Row(
                                key: const ValueKey('external-ai-wide-layout'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: 320, child: _permissions()),
                                  const SizedBox(width: 16),
                                  Expanded(child: _connection()),
                                ],
                              )
                            else
                              Column(
                                key: const ValueKey(
                                  'external-ai-stacked-layout',
                                ),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _permissions(),
                                  const SizedBox(height: 12),
                                  _connection(),
                                ],
                              ),
                            const SizedBox(height: 12),
                            _advanced(context),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionStatus() => Wrap(
    spacing: 16,
    runSpacing: 8,
    children: [
      _Status(
        label: controller.running ? '播放器服务已开启' : '播放器服务未开启',
        active: controller.running,
      ),
      ExternalAiConnectionStatus(controller: controller),
      const _Status(label: '仅本机 · 不提供媒体文件', icon: Icons.shield_outlined),
    ],
  );

  Widget _permissions() {
    final prefs = controller.preferences;
    final folders = LibraryService().storageCollections
        .where((f) => !f.isRecycled && !f.isHiddenFromFolders)
        .toList();
    return _Panel(
      title: '连接权限',
      icon: Icons.tune_rounded,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('允许外部 AI 读取资料', style: TextStyle(fontSize: 14)),
          key: const ValueKey('external-ai-read-access'),
          subtitle: const Text(
            '使用时保持播放器运行',
            style: TextStyle(fontSize: 12, color: AppTokens.text2, height: 1.5),
          ),
          value: prefs?.enabled ?? false,
          onChanged: prefs == null || _working
              ? null
              : (value) => controller.update(prefs.copyWith(enabled: value)),
        ),
        if (prefs != null) ...[
          const SizedBox(height: 18),
          const _Label('允许读取的范围'),
          const SizedBox(height: 8),
          CapsuleDropdownButtonFormField<String>(
            key: ValueKey('external-ai-scope-${prefs.scopeFolderId ?? 'all'}'),
            initialValue: prefs.scopeFolderId ?? '',
            isExpanded: true,
            itemHeight: null,
            dropdownColor: AppTokens.bgOverlay,
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              fontSize: 13,
              color: AppTokens.text1,
            ),
            selectedItemBuilder: (_) => [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '整个媒体库',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (prefs.scopeFolderId != null &&
                  !folders.any((f) => f.id == prefs.scopeFolderId))
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '原授权文件夹不可用（访问仍受限制）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              for (final folder in folders)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            items: [
              const DropdownMenuItem(value: '', child: Text('整个媒体库')),
              if (prefs.scopeFolderId != null &&
                  !folders.any((f) => f.id == prefs.scopeFolderId))
                DropdownMenuItem(
                  value: prefs.scopeFolderId,
                  enabled: false,
                  child: const Text('原授权文件夹不可用（访问仍受限制）'),
                ),
              for (final folder in folders)
                DropdownMenuItem(value: folder.id, child: Text(folder.name)),
            ],
            onChanged: _working
                ? null
                : (value) => controller.update(
                    prefs.copyWith(
                      scopeFolderId: value,
                      clearScopeFolderId: value == '',
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text(
              '同时允许读取已保存的 AI 对话',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            value: prefs.includeConversations,
            onChanged: _working
                ? null
                : (value) => controller.update(
                    prefs.copyWith(includeConversations: value),
                  ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('允许管理转录任务', style: TextStyle(fontSize: 13)),
            key: const ValueKey('external-ai-task-access'),
            subtitle: const Text(
              '仅控制 Agent 新建的任务，沿用当前本地/公益/云端服务；可在批量转录页查看和暂停',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            value: prefs.allowTaskControl,
            onChanged: _working
                ? null
                : (value) => controller.update(
                    prefs.copyWith(allowTaskControl: value),
                  ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('允许回传译文和加载副字幕', style: TextStyle(fontSize: 13)),
            key: const ValueKey('external-ai-subtitle-access'),
            subtitle: const Text(
              '译文新增到字幕管理区，保留原字幕；加载副字幕由你向 Agent 指定',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            value: prefs.allowSubtitleWrite,
            onChanged: _working
                ? null
                : (value) => controller.update(
                    prefs.copyWith(allowSubtitleWrite: value),
                  ),
          ),
        ],
        if (prefs?.enabled == true && prefs?.allowTaskControl == true) ...[
          _delegation(prefs!),
          _approvalControls(),
        ],
        const Divider(height: 28),
        const Text(
          '更改权限后，请让 Agent 刷新工具列表或重新连接。外部 Agent 可能把取得的资料发给它使用的模型服务。你可以随时关闭读取，或缩小授权范围。',
          style: TextStyle(fontSize: 12, height: 1.65, color: AppTokens.text2),
        ),
      ],
    );
  }

  Widget _delegation(ExternalAiPreferences prefs) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('自动代办授权', style: TextStyle(fontSize: 13)),
    subtitle: const Text(
      '默认逐批确认；按需开启后无需反复确认。全局设置始终确认。',
      style: TextStyle(fontSize: 12),
    ),
    children: [
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('自动决定并执行本批转录', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
          '仅本连接创建的任务；不接管已有任务',
          style: TextStyle(fontSize: 12),
        ),
        value: prefs.autoTaskDecisions,
        onChanged: _working
            ? null
            : (v) => controller.update(prefs.copyWith(autoTaskDecisions: v)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('允许自动下载所需模型', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
          '可能占用数 GB 空间和网络流量；可在模型中心暂停',
          style: TextStyle(fontSize: 12),
        ),
        value: prefs.autoModelDownloads,
        onChanged: _working
            ? null
            : (v) => controller.update(prefs.copyWith(autoModelDownloads: v)),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('允许自动使用已配置的在线服务', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
          '播放器会向所选公益/云端转录服务上传音频，向在线翻译服务发送文字，可能产生费用；Agent 无法取得媒体文件',
          style: TextStyle(fontSize: 12),
        ),
        value: prefs.autoRemoteProcessing,
        onChanged: _working
            ? null
            : (v) => controller.update(prefs.copyWith(autoRemoteProcessing: v)),
      ),
    ],
  );

  Widget _approvalControls() {
    final requests =
        controller.approvals?.requests
            .where((r) => r['status'] == 'approval_required')
            .toList() ??
        [];
    if (requests.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          '待确认（${requests.length}）',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        for (final request in requests.take(20))
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    _approvalPreview(request['preview'] as Map),
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => _resolveApproval(
                          request['approvalId'] as String,
                          true,
                        ),
                        child: const Text('允许这次'),
                      ),
                      TextButton(
                        onPressed: () => _resolveApproval(
                          request['approvalId'] as String,
                          false,
                        ),
                        child: const Text('拒绝'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String _approvalPreview(Map preview) {
    final b = StringBuffer(preview['operation'] ?? 'Agent 请求操作');
    if (preview['mediaCount'] != null) {
      b.write(' · ${preview['mediaCount']} 个媒体');
    }
    if (preview['media'] is List) {
      b.write('\n${(preview['media'] as List).join('、')}');
    }
    final settings = preview['settings'] ?? preview['changes'];
    if (settings is Map) {
      const labels = {
        'service': '转录服务',
        'sourceLanguage': '媒体语言',
        'mode': '模式',
        'translation': '翻译服务',
        'targetLanguage': '翻译语言',
        'serviceId': '服务/模型',
        'translationModelId': '翻译模型',
        'uploadsAudio': '上传音频',
        'uploadsText': '发送字幕文字',
      };
      for (final e in settings.entries) {
        if (e.value != null) b.write('\n${labels[e.key] ?? e.key}：${e.value}');
      }
    }
    if (preview['modelIds'] is List &&
        (preview['modelIds'] as List).isNotEmpty) {
      b.write('\n所需模型：${(preview['modelIds'] as List).join('、')}');
    }
    if ((preview['downloadBytes'] as num? ?? 0) > 0) {
      b.write(
        '\n下载约 ${((preview['downloadBytes'] as num) / 1073741824).toStringAsFixed(2)} GB',
      );
    }
    if (preview['note'] != null) b.write('\n${preview['note']}');
    return b.toString();
  }

  Future<void> _resolveApproval(String id, bool approve) async {
    try {
      await controller.approvals!.resolve(id, approve: approve);
      _notice(approve ? '已允许这次操作，请让 Agent 重试原请求。' : '已拒绝，未执行操作。');
    } catch (_) {
      _notice('确认未保存或已失效，请重试。', error: true);
    }
  }

  Widget _connection() {
    final client = _client;
    final info = externalAiClientInfo(client ?? ExternalAiClient.generic);
    final clients = ExternalAiClient.values
        .where((c) => c != ExternalAiClient.claudeDesktop)
        .toList();
    return _Panel(
      title: '连接助手',
      icon: Icons.hub_outlined,
      children: [
        const _Label('选择你使用的 Agent'),
        const SizedBox(height: 8),
        CapsuleDropdownButtonFormField<ExternalAiClient>(
          key: const ValueKey('external-ai-agent-selector'),
          initialValue: _client,
          hint: const Text('请选择接收提示词的 Agent'),
          isExpanded: true,
          itemHeight: null,
          dropdownColor: AppTokens.bgOverlay,
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
            fontSize: 14,
            color: AppTokens.text1,
          ),
          selectedItemBuilder: (_) => [
            for (final c in clients)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  externalAiClientInfo(c).label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          items: [
            for (final c in clients)
              DropdownMenuItem(
                value: c,
                child: Text(externalAiClientInfo(c).label),
              ),
          ],
          onChanged: _working
              ? null
              : (value) {
                  setState(() {
                    _client = value!;
                    _expanded = false;
                    _message = null;
                  });
                  unawaited(controller.rememberClient(value!));
                  _refreshPreview(force: true);
                },
        ),
        if (client == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              '选择后会显示该助手的连接步骤；请把提示词发给同一个助手。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppTokens.text2,
              ),
            ),
          ),
        if (client != null) ...[
          const SizedBox(height: 16),
          Material(
            color: AppTokens.bgBase,
            borderRadius: BorderRadius.circular(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      const Text(
                        '连接提示词',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppTokens.text1,
                        ),
                      ),
                      Text(
                        _prompt == null
                            ? '发送前先看一眼'
                            : '${_expanded ? '完整内容 · ' : '开头预览 · '}${_prompt!.runes.length} 字',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTokens.text2,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: _Reveal(child: _previewBody()),
                ),
                if (_prompt != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopButtonClickRegion(
                      child: TextButton.icon(
                        key: const ValueKey('external-ai-preview-toggle'),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: AnimatedRotation(
                          turns: _expanded ? .5 : 0,
                          duration: _motion,
                          curve: _curve,
                          child: const Icon(Icons.expand_more, size: 18),
                        ),
                        label: Text(_expanded ? '收起' : '展开全文'),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DesktopButtonClickRegion(
                child: FilledButton.icon(
                  key: const ValueKey('external-ai-copy-prompt'),
                  onPressed: _canCopy ? _copyPrompt : null,
                  icon: _copying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.copy_rounded, size: 17),
                  label: Text('复制给 ${info.label} 的提示词'),
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton.icon(
                  onPressed: !controller.running || _working
                      ? null
                      : controller.checkConnection,
                  icon: const Icon(Icons.sync_rounded, size: 17),
                  label: const Text('检测播放器连接'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '只发给 ${info.label}。提示词可以帮助写配置，信任、启用和客户端加载仍需按下方步骤完成。',
            style: TextStyle(fontSize: 12, color: AppTokens.text2, height: 1.6),
          ),
          const SizedBox(height: 18),
          _Notice(
            externalAiClientActivationNotice(client),
            icon: Icons.touch_app_outlined,
          ),
          const SizedBox(height: 16),
          _ConnectionSection(
            title: '2. 在 ${info.label} 中完成连接',
            icon: Icons.checklist_rounded,
            children: [
              SelectableText(
                info.steps,
                key: const ValueKey('external-ai-client-steps'),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: AppTokens.text2,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    try {
                      final opened = await launchUrl(
                        Uri.parse(info.documentationUrl),
                        mode: LaunchMode.externalApplication,
                      );
                      if (!opened) _notice('未能打开官方指南，请检查浏览器设置。', error: true);
                    } catch (_) {
                      _notice('未能打开官方指南，请检查浏览器设置。', error: true);
                    }
                  },
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: Text('${info.label} 官方指南'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_client == ExternalAiClient.qwenWork) ...[
            const SizedBox(height: 10),
            const Text(
              '这里连接的是“千问办公”。普通“千问”客户端请以实际支持的能力为准。',
              style: TextStyle(
                fontSize: 12,
                color: AppTokens.text2,
                height: 1.6,
              ),
            ),
          ],
          _Reveal(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _Notice(_message!, error: _messageError),
                  ),
                if (controller.diagnostic != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _Notice(controller.diagnostic!),
                  ),
              ],
            ),
          ),
          const Divider(height: 20),
          _ConnectionSection(
            title: '其他连接方式',
            icon: Icons.settings_ethernet,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if ([
                    ExternalAiClient.codex,
                    ExternalAiClient.workBuddy,
                    ExternalAiClient.workBuddyAi,
                    ExternalAiClient.cursor,
                  ].contains(_client))
                    DesktopButtonClickRegion(
                      child: OutlinedButton.icon(
                        onPressed: !controller.running || _working
                            ? null
                            : _install,
                        icon: const Icon(Icons.add_link, size: 17),
                        label: const Text('添加连接'),
                      ),
                    ),
                  DesktopButtonClickRegion(
                    child: OutlinedButton.icon(
                      onPressed: !controller.running || _working
                          ? null
                          : _copyConfig,
                      icon: const Icon(Icons.code, size: 17),
                      label: const Text('复制配置'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 20),
          _Label('3. 在助手中验证'),
          const SizedBox(height: 8),
          SelectableText(
            externalAiVerificationPrompt(serverName: _serverName),
            style: const TextStyle(
              fontSize: 13,
              height: 1.65,
              color: AppTokens.text2,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('external-ai-copy-verification'),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: externalAiVerificationPrompt(
                        serverName: _serverName,
                      ),
                    ),
                  );
                  _notice('已复制验证问题。请在选中的助手中发送，查看真实工具调用结果。');
                },
                child: const Text('复制验证问题'),
              ),
            ),
          ),
          const Text(
            '本页的“检测播放器连接”只检查播放器自身，不能代替助手中的真实工具调用。',
            style: TextStyle(fontSize: 12, height: 1.6, color: AppTokens.text2),
          ),
        ],
      ],
    );
  }

  Widget _previewBody() {
    final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.7,
      color: AppTokens.text2,
    );
    if (_preparing) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Expanded(child: Text('正在准备连接提示词…', style: style)),
          ],
        ),
      );
    }
    if (_previewError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_previewError!, style: style),
          TextButton(
            onPressed: () => _refreshPreview(force: true),
            child: const Text('重新生成'),
          ),
        ],
      );
    }
    if (_prompt == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text('开启读取后，这里会显示给 Agent 的连接提示词。', style: style),
      );
    }
    if (_expanded) {
      return SelectableText(
        _prompt!,
        key: const ValueKey('external-ai-connection-preview'),
        style: style.copyWith(color: AppTokens.text1),
      );
    }
    return Text(
      _prompt!,
      key: const ValueKey('external-ai-connection-excerpt'),
      maxLines: 5,
      overflow: TextOverflow.fade,
      softWrap: true,
      style: style,
    );
  }

  Widget _advanced(BuildContext themedContext) {
    final prefs = controller.preferences;
    return _Disclosure(
      title: '高级设置',
      icon: Icons.more_horiz,
      children: [
        Text(
          '已收到 ${controller.server?.requestCount ?? 0} 次本机请求（含连接检测）。',
          style: const TextStyle(fontSize: 12, color: AppTokens.text2),
        ),
        if (prefs != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('更换连接端口', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              prefs.port.toString(),
              style: const TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            enabled: !_working,
            onTap: () async {
              final port = await showDialog<int>(
                context: themedContext,
                builder: (_) => _PortDialog(port: prefs.port),
              );
              if (mounted && port != null) {
                await controller.update(prefs.copyWith(port: port));
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('撤销已有连接', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              '更换访问令牌，所有 Agent 需要重新添加连接',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            enabled: !_working,
            onTap: () => controller.update(
              prefs.copyWith(token: ExternalAiPreferences.generateToken()),
            ),
          ),
        ],
      ],
    );
  }
}

/// Render directly with reduced motion. A zero-duration AnimatedSize can
/// restart its controller from performLayout when text changes height.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? child
      : AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: const Cubic(.2, .8, .2, 1),
          alignment: Alignment.topLeft,
          child: child,
        );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Material(
    color: AppTokens.bgRaised,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppTokens.text2),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppTokens.text1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12, color: AppTokens.text2));
}

class _Status extends StatelessWidget {
  const _Status({required this.label, this.active = false, this.icon});
  final String label;
  final bool active;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null)
        Icon(icon, size: 14, color: AppTokens.text2)
      else
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? AppTokens.accent : AppTokens.text2,
            shape: BoxShape.circle,
          ),
        ),
      const SizedBox(width: 7),
      Flexible(
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppTokens.text2),
        ),
      ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.error = false, this.icon});
  final String text;
  final bool error;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: error
            ? AppTokens.danger.withValues(alpha: .08)
            : AppTokens.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon ?? (error ? Icons.info_outline : Icons.check_circle_outline),
            size: 16,
            color: error ? AppTokens.danger : AppTokens.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppTokens.text1,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Keep connection instructions and alternatives visible without extra clicks.
class _ConnectionSection extends StatelessWidget {
  const _ConnectionSection({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(icon, size: 17, color: AppTokens.text2),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTokens.text1,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      ...children,
    ],
  );
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 8, bottom: 4),
      iconColor: AppTokens.text2,
      collapsedIconColor: AppTokens.text2,
      expansionAnimationStyle: AnimationStyle(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: const Cubic(.2, .8, .2, 1),
      ),
      title: Row(
        children: [
          Icon(icon, size: 17, color: AppTokens.text2),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTokens.text2,
              ),
            ),
          ),
        ],
      ),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ],
    ),
  );
}

class _PortDialog extends StatefulWidget {
  const _PortDialog({required this.port});
  final int port;
  @override
  State<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends State<_PortDialog> {
  late final input = TextEditingController(text: widget.port.toString());
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void save() {
    final port = int.tryParse(input.text);
    if (port == null || port < 1024 || port > 65535) {
      setState(() => error = '请输入 1024–65535 之间的端口');
      return;
    }
    Navigator.pop(context, port);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppTokens.bgRaised,
    title: const Text('连接端口'),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: input,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          helperText: '更改后需重新复制提示词，更新 Agent 连接。',
          helperMaxLines: 3,
          errorText: error,
          errorMaxLines: 2,
        ),
        onSubmitted: (_) => save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: save, child: const Text('保存')),
    ],
  );
}
