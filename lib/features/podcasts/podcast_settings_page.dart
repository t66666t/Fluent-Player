import 'package:permission_handler/permission_handler.dart' as permissions;
import '../../widgets/operation_status.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../widgets/dialog_keyboard_viewport.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/effective_media_playback_preferences.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/media_library_safe_area.dart';
import 'podcast_runtime.dart';
import 'podcast_settings.dart';
import 'podcast_widgets.dart';
import 'podcast_menu.dart';
import 'podcast_typography.dart';
import 'podcast_page_shortcuts.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

part 'podcast_settings_view.dart';

Future<void> savePodcastFile(String name, List<int> bytes) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '保存文件',
    fileName: name,
    bytes: Uint8List.fromList(bytes),
  );
  if (path != null && !Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
}

Future<void> savePodcastMediaFile(File file, String name) async {
  if (Platform.isAndroid || Platform.isIOS) {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], fileNameOverrides: [name]),
    );
    return;
  }
  final destination = await FilePicker.platform.saveFile(
    dialogTitle: '导出节目文件',
    fileName: name,
  );
  if (destination != null) await file.copy(destination);
}

class PodcastSettingsPage extends StatefulWidget {
  const PodcastSettingsPage({super.key, this.channelId});
  final String? channelId;
  @override
  State<PodcastSettingsPage> createState() => _PodcastSettingsPageState();
}
