import 'package:flutter/material.dart';

import '../../services/library_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/library_folder_picker.dart';

/// Opens a full page for sending a folder or linking an incoming sync request.
Future<String?> showSyncFolderPicker(
  BuildContext context, {
  required LibraryService library,
  String title = '选择本机文件夹',
  String description = '包含子文件夹，新增内容和观看进度会持续同步。',
}) async {
  final result = await Navigator.of(context, rootNavigator: true)
      .push<LibraryFolderPick>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            key: const ValueKey('sync-folder-picker-page'),
            backgroundColor: AppTokens.bgRaised,
            appBar: AppBar(
              backgroundColor: AppTokens.bgRaised,
              foregroundColor: AppTokens.text1,
              surfaceTintColor: Colors.transparent,
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            body: SafeArea(
              top: false,
              bottom: false,
              child: LibraryFolderPicker(
                library: library,
                mode: LibraryFolderPickerMode.singleFolder,
                showTitleBar: false,
                confirmLabel: '确认选择',
                offerSetAsDefault: false,
                header: (_) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '点文件夹进入下一级，点圆圈单选。',
                      style: TextStyle(color: AppTokens.text2, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
  return result?.folderId;
}
