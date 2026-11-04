import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'desktop_button_click_region.dart';
import 'stable_width_label.dart';

class BilibiliFavoritesImportButtons extends StatelessWidget {
  const BilibiliFavoritesImportButtons({
    super.key,
    required this.folderId,
    required this.onImport,
    this.enabled = true,
    this.busy = false,
  });
  final int folderId;
  final Future<void> Function(bool pickPlace) onImport;
  final bool enabled;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DesktopButtonClickRegion(
        child: TextButton(
          key: ValueKey('bilibili-favorite-import-$folderId'),
          onPressed: enabled && !busy ? () => unawaited(onImport(false)) : null,
          style: TextButton.styleFrom(
            foregroundColor: AppTokens.brandBilibili,
            minimumSize: const Size(48, 44),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            textStyle: DefaultTextStyle.of(context).style.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          child: StableWidthLabel(
            busy ? '导入中' : '导入',
            variants: const ['导入', '导入中'],
          ),
        ),
      ),
      DesktopButtonClickRegion(
        child: IconButton(
          key: ValueKey('bilibili-favorite-import-pick-$folderId'),
          tooltip: '选择导入位置',
          onPressed: enabled && !busy ? () => unawaited(onImport(true)) : null,
          icon: const Icon(Icons.drive_folder_upload_outlined, size: 17),
          color: AppTokens.text3,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
        ),
      ),
    ],
  );
}
