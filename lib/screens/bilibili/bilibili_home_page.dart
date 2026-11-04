import 'package:flutter/material.dart';
import '../../services/bilibili/bilibili_public_api_service.dart';
import 'bilibili_card_actions.dart';
import 'bilibili_import_buttons.dart';

Future<void> openBilibiliSearch(
  BuildContext context, {
  required String keyword,
}) async {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(const SnackBar(content: Text('社区版仅支持本地媒体，不提供在线媒体搜索')));
}

class BilibiliHomePage extends StatelessWidget {
  const BilibiliHomePage({
    super.key,
    required this.isActive,
    this.api,
    this.bottomPadding = 0,
    this.onWatch,
    this.onImport,
    this.initialKeyword,
    this.showAppBar = false,
  });
  final bool isActive;
  final BilibiliPublicApiService? api;
  final double bottomPadding;
  final BilibiliVideoWatcher? onWatch;
  final BilibiliQuickImporter? onImport;
  final String? initialKeyword;
  final bool showAppBar;

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('社区版专注本地媒体，请导入本地视频、音频或字幕。'));
}
