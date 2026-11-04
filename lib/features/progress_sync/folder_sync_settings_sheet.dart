import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'folder_sync_models.dart';
import 'folder_transfer_card.dart' show formatFolderTransferBytes;
import 'progress_sync_components.dart';
import 'progress_sync_service.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<bool?> showSyncedItemRemoval(
  BuildContext context, {
  required String name,
  required bool isRoot,
  bool allowEverywhere = true,
}) => showSyncSheet<bool>(
  context: context,
  title: '移除「$name」',
  child: Builder(
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.remove_circle_outline),
          title: const Text('仅从本机移除'),
          subtitle: Text(
            isRoot ? '其他设备保留，暂停内容同步。' : '其他设备保留，不会自动补回本机。',
            style: const TextStyle(
              fontSize: 12,
              color: AppTokens.text2,
              height: 1.5,
            ),
          ),
          onTap: () => Navigator.pop(sheetContext, false),
        ),
        if (!isRoot && allowEverywhere)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline, color: AppTokens.danger),
            title: const Text('从所有设备移除'),
            subtitle: const Text(
              '对应项目移到各设备回收站。',
              style: TextStyle(
                fontSize: 12,
                color: AppTokens.text2,
                height: 1.5,
              ),
            ),
            onTap: () => Navigator.pop(sheetContext, true),
          ),
        const SizedBox(height: 12),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('取消'),
          ),
        ),
      ],
    ),
  ),
);

Future<void> showFolderSyncActions(
  BuildContext context,
  ProgressSyncService service,
  String collectionId, {
  String? name,
}) async {
  final action = await showSyncSheet<String>(
    context: context,
    title: name ?? '文件夹同步',
    child: Builder(
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sync_outlined, color: AppTokens.accent),
            title: const Text('立即同步'),
            subtitle: const Text(
              '检查文件变化和观看进度',
              style: TextStyle(fontSize: 12, color: AppTokens.text2),
            ),
            onTap: () => Navigator.pop(sheetContext, 'sync'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tune_outlined, color: AppTokens.text2),
            title: const Text('同步设置'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.pop(sheetContext, 'settings'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == 'settings') {
    await showFolderSyncSettings(context, service, collectionId, name: name);
  } else if (action == 'sync') {
    try {
      await service.syncFolderNow(collectionId);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂未完成，本机内容已保留，可稍后重试')));
      }
    }
  }
}

Future<void> showFolderSyncSettings(
  BuildContext context,
  ProgressSyncService service,
  String collectionId, {
  String? name,
}) => showSyncSheet<void>(
  context: context,
  title: '同步设置',
  child: FolderSyncSettingsForm(
    initial: service.folderSettings(collectionId),
    devices: service.folderDevices(collectionId),
    localDeviceId: service.deviceId,
    folderName: name,
    onRestore: () => service.restoreLocallyRemovedItems(collectionId),
    onSave: (settings) => service.updateFolderSettings(collectionId, settings),
  ),
);

class FolderSyncSettingsForm extends StatefulWidget {
  const FolderSyncSettingsForm({
    super.key,
    required this.initial,
    required this.devices,
    required this.localDeviceId,
    required this.onSave,
    this.folderName,
    this.onRestore,
  });

  final FolderSyncSettings initial;
  final Map<String, String> devices;
  final String localDeviceId;
  final String? folderName;
  final Future<void> Function()? onRestore;
  final Future<void> Function(FolderSyncSettings) onSave;

  @override
  State<FolderSyncSettingsForm> createState() => _FolderSyncSettingsFormState();
}

class _FolderSyncSettingsFormState extends State<FolderSyncSettingsForm> {
  final _form = GlobalKey<FormState>();
  late FolderSyncSettings _settings = widget.initial;
  late String? _source = _availableSource(widget.initial.sourceDeviceId);
  late final _extensions = TextEditingController(
    text: widget.initial.excludedExtensions.join(', '),
  );
  late final _patterns = TextEditingController(
    text: widget.initial.excludedPatterns.join(', '),
  );
  bool _advanced = false;
  bool _saving = false;
  String? _error;

  String? _availableSource(String? preferred) {
    if (widget.devices.containsKey(preferred)) return preferred;
    // A vanished saved authority requires an explicit replacement choice.
    if (preferred != null) return null;
    if (widget.devices.containsKey(widget.localDeviceId)) {
      return widget.localDeviceId;
    }
    return widget.devices.keys.firstOrNull;
  }

  @override
  void didUpdateWidget(covariant FolderSyncSettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_source != null && !widget.devices.containsKey(_source)) _source = null;
  }

  @override
  void dispose() {
    _extensions.dispose();
    _patterns.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        _settings.copyWith(
          sourceDeviceId: _settings.mode == FolderSyncMode.oneWay
              ? _source
              : null,
          excludedExtensions: _extensions.text
              .split(RegExp(r'[\s,，;；]+'))
              .map(
                (value) =>
                    value.replaceFirst(RegExp(r'^\.+'), '').toLowerCase(),
              )
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList(),
          excludedPatterns: _patterns.text
              .split(RegExp(r'[,，;；\n]+'))
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList(),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is FormatException ? error.message : '设置暂未保存，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.folderName != null) ...[
          Text(
            widget.folderName!,
            style: const TextStyle(color: AppTokens.text2, fontSize: 12),
          ),
          const SizedBox(height: 14),
        ],
        CapsuleDropdownButtonFormField<FolderSyncMode>(
          key: const ValueKey('folder-sync-mode'),
          initialValue: _settings.mode,
          decoration: const InputDecoration(labelText: '同步方式'),
          items: [
            for (final mode in FolderSyncMode.values)
              DropdownMenuItem(
                value: mode,
                child: Text(folderSyncModeLabel(mode)),
              ),
          ],
          onChanged: _saving
              ? null
              : (mode) {
                  if (mode != null) {
                    setState(() => _settings = _settings.copyWith(mode: mode));
                  }
                },
        ),
        const SizedBox(height: 10),
        Text(
          switch (_settings.mode) {
            FolderSyncMode.smart => '两端新增和修改自动互通，观看进度一起同步。',
            FolderSyncMode.progressOnly => '只同步观看进度，文件各自保留。',
            FolderSyncMode.oneWay => '以选定设备为准，其他设备接收内容变化。',
          },
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            color: AppTokens.text2,
          ),
        ),
        if (_settings.mode == FolderSyncMode.oneWay) ...[
          const SizedBox(height: 16),
          CapsuleDropdownButtonFormField<String>(
            key: const ValueKey('folder-sync-source'),
            initialValue: widget.devices.containsKey(_source) ? _source : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '内容来自'),
            items: [
              for (final device in widget.devices.entries)
                DropdownMenuItem(
                  value: device.key,
                  child: Text(
                    device.key == widget.localDeviceId
                        ? '${device.value} · 本机'
                        : device.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _saving
                ? null
                : (source) => setState(() => _source = source),
            validator: (source) => source == null ? '请选择内容来源设备' : null,
          ),
        ],
        const SizedBox(height: 16),
        ListTile(
          key: const ValueKey('folder-sync-advanced'),
          contentPadding: EdgeInsets.zero,
          title: const Text('高级设置', style: TextStyle(fontSize: 14)),
          trailing: Icon(_advanced ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _advanced = !_advanced),
        ),
        if (_advanced) ...[
          if (_settings.mode != FolderSyncMode.progressOnly) ...[
            _switch(
              '同步删除',
              '开启后，删除会同步到其他设备的回收站。',
              _settings.syncDeletes,
              (value) => _settings = _settings.copyWith(syncDeletes: value),
              key: const ValueKey('folder-sync-deletes'),
            ),
            _switch(
              '同步字幕与附带文件',
              null,
              _settings.includeSidecars,
              (value) => _settings = _settings.copyWith(includeSidecars: value),
            ),
            const SizedBox(height: 14),
            _byteChoice(
              '自动接收上限',
              _settings.maxAutoTransferBytes,
              [0, 100 << 20, 500 << 20, 1 << 30, 5 << 30],
              (value) =>
                  _settings = _settings.copyWith(maxAutoTransferBytes: value),
            ),
            const SizedBox(height: 6),
            const Text(
              '超过上限后手动继续；不限制时自动接收。',
              style: TextStyle(
                fontSize: 11,
                color: AppTokens.text3,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            _byteChoice(
              '接收后至少保留',
              _settings.minFreeBytes,
              [0, 256 << 20, 512 << 20, 1 << 30, 2 << 30, 5 << 30],
              (value) => _settings = _settings.copyWith(minFreeBytes: value),
              unlimited: '不预留',
            ),
            const SizedBox(height: 12),
            _byteChoice(
              '单任务速度上限',
              _settings.bytesPerSecondLimit,
              [0, 1 << 20, 5 << 20, 10 << 20, 20 << 20, 50 << 20],
              (value) =>
                  _settings = _settings.copyWith(bytesPerSecondLimit: value),
              speed: true,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _extensions,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: '忽略的文件格式',
                hintText: 'tmp, log, bak',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _patterns,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: '忽略的名称',
                hintText: '*.tmp, .DS_Store',
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '相对于此文件夹：* 匹配当前层，** 跨文件夹，? 匹配一个字符。多个规则用逗号或换行分隔。',
              style: TextStyle(
                fontSize: 11,
                color: AppTokens.text3,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
          ],
          _switch(
            '相同内容共用观看进度',
            '默认按文件分别记录，开启后相同内容可共用进度。',
            _settings.shareProgressForSameContent,
            (value) => _settings = _settings.copyWith(
              shareProgressForSameContent: value,
            ),
          ),
          if (widget.onRestore != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopButtonClickRegion(
                child: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () async {
                          setState(() {
                            _saving = true;
                            _error = null;
                          });
                          try {
                            await widget.onRestore!();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已恢复，正在补齐缺失项目')),
                              );
                            }
                          } catch (_) {
                            if (mounted) setState(() => _error = '暂未恢复，请稍后重试');
                          } finally {
                            if (mounted) setState(() => _saving = false);
                          }
                        },
                  icon: const Icon(Icons.restore_outlined, size: 17),
                  label: const Text(
                    '恢复本机移除的项目',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppTokens.danger, fontSize: 12),
          ),
        ],
        const SizedBox(height: 20),
        DesktopButtonClickRegion(
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存'),
          ),
        ),
      ],
    ),
  );

  Widget _switch(
    String title,
    String? subtitle,
    bool value,
    void Function(bool) update, {
    Key? key,
  }) => SwitchListTile.adaptive(
    key: key,
    contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle,
            style: const TextStyle(
              fontSize: 11,
              height: 1.5,
              color: AppTokens.text2,
            ),
          ),
    value: value,
    activeThumbColor: AppTokens.text1,
    activeTrackColor: AppTokens.accent,
    onChanged: _saving ? null : (value) => setState(() => update(value)),
  );

  Widget _byteChoice(
    String label,
    int value,
    List<int> options,
    void Function(int) update, {
    String unlimited = '不限制',
    bool speed = false,
  }) => CapsuleDropdownButtonFormField<int>(
    key: ValueKey('folder-sync-$label-$value'),
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final option in {...options, value}.toList()..sort())
        DropdownMenuItem(
          value: option,
          child: Text(
            option == 0
                ? unlimited
                : '${formatFolderTransferBytes(option)}${speed ? '/s' : ''}',
          ),
        ),
    ],
    onChanged: _saving
        ? null
        : (value) {
            if (value != null) setState(() => update(value));
          },
  );
}

String folderSyncModeLabel(FolderSyncMode mode) => switch (mode) {
  FolderSyncMode.smart => '智能双向',
  FolderSyncMode.progressOnly => '仅观看进度',
  FolderSyncMode.oneWay => '单向跟随',
};
