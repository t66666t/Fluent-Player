import 'package:flutter/material.dart';
import '../../services/bilibili/bilibili_api_service.dart';

/// Old routes fail closed without loading a browser or contacting the platform.
class BilibiliWebLoginScreen extends StatelessWidget {
  const BilibiliWebLoginScreen({super.key, required this.api});
  final BilibiliApiService api;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('功能已移除')),
    body: const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('本地版不提供平台登录或在线播放，请导入本地媒体文件。'),
      ),
    ),
  );
}
