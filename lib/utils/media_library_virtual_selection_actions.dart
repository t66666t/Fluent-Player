import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Bottom-bar actions for virtual library pages (继续学习 / 最近添加).
enum MediaLibraryVirtualSelectionActionKind {
  recycle,
  export,
  rename,
  pin,
  unpin,
  hideContinue,
  dismissRecent,
}

class MediaLibraryVirtualSelectionAction {
  const MediaLibraryVirtualSelectionAction({
    required this.kind,
    required this.label,
    required this.icon,
    required this.color,
    this.tooltip,
  });

  final MediaLibraryVirtualSelectionActionKind kind;
  final String label;
  final IconData icon;
  final Color color;
  final String? tooltip;
}

/// Builds the action list that applies to every currently selected card.
class MediaLibraryVirtualSelectionActions {
  const MediaLibraryVirtualSelectionActions._();

  /// Continue-learning: pins vs records decide hide/pin; mixed keeps only
  /// export and recycle so one button never means two different things.
  static List<MediaLibraryVirtualSelectionAction> forContinueLearning({
    required Set<String> selectedIds,
    required Set<String> pinnedIds,
  }) {
    if (selectedIds.isEmpty) {
      return const <MediaLibraryVirtualSelectionAction>[];
    }
    final allPinned = selectedIds.every(pinnedIds.contains);
    final nonePinned = selectedIds.every((id) => !pinnedIds.contains(id));
    final actions = <MediaLibraryVirtualSelectionAction>[];
    if (allPinned) {
      actions.add(_unpin);
    } else if (nonePinned) {
      actions
        ..add(_hideContinue)
        ..add(_pin);
    }
    actions
      ..add(_export)
      ..add(_recycle);
    if (selectedIds.length == 1) {
      actions.add(_rename);
    }
    return List<MediaLibraryVirtualSelectionAction>.unmodifiable(actions);
  }

  /// Recent-added: dismiss is always valid; pin only when the set agrees.
  static List<MediaLibraryVirtualSelectionAction> forRecentAdded({
    required Set<String> selectedIds,
    required Set<String> pinnedIds,
  }) {
    if (selectedIds.isEmpty) {
      return const <MediaLibraryVirtualSelectionAction>[];
    }
    final allPinned = selectedIds.every(pinnedIds.contains);
    final nonePinned = selectedIds.every((id) => !pinnedIds.contains(id));
    final actions = <MediaLibraryVirtualSelectionAction>[_dismissRecent];
    if (allPinned) {
      actions.add(_unpin);
    } else if (nonePinned) {
      actions.add(_pin);
    }
    actions
      ..add(_export)
      ..add(_recycle);
    if (selectedIds.length == 1) {
      actions.add(_rename);
    }
    return List<MediaLibraryVirtualSelectionAction>.unmodifiable(actions);
  }

  /// Folder root keeps the classic three actions.
  static List<MediaLibraryVirtualSelectionAction> forFolders({
    required Set<String> selectedIds,
  }) {
    if (selectedIds.isEmpty) {
      return const <MediaLibraryVirtualSelectionAction>[];
    }
    final actions = <MediaLibraryVirtualSelectionAction>[_recycle, _export];
    if (selectedIds.length == 1) {
      actions.add(_rename);
    }
    return List<MediaLibraryVirtualSelectionAction>.unmodifiable(actions);
  }

  static const _recycle = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.recycle,
    label: '移入回收站',
    icon: Icons.delete,
    color: AppTokens.danger,
  );

  static const _export = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.export,
    label: '导出',
    icon: Icons.unarchive_outlined,
    color: AppTokens.text1,
    tooltip: '导出为 Fluent Pack 或 Zip',
  );

  static const _rename = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.rename,
    label: '重命名',
    icon: Icons.edit,
    color: AppTokens.text1,
  );

  static const _pin = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.pin,
    label: '置顶',
    icon: Icons.push_pin_outlined,
    color: AppTokens.text1,
  );

  static const _unpin = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.unpin,
    label: '取消置顶',
    icon: Icons.push_pin,
    color: AppTokens.text1,
  );

  static const _hideContinue = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.hideContinue,
    label: '从本页移除',
    icon: Icons.visibility_off_outlined,
    color: AppTokens.text1,
  );

  static const _dismissRecent = MediaLibraryVirtualSelectionAction(
    kind: MediaLibraryVirtualSelectionActionKind.dismissRecent,
    label: '从本页移除',
    icon: Icons.visibility_off_outlined,
    color: AppTokens.text1,
  );
}
