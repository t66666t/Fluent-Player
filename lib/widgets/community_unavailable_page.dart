import 'package:flutter/material.dart';
class CommunityUnavailablePage extends StatelessWidget {
  const CommunityUnavailablePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('开源版')),
    body: const Center(child: Text('此版本不提供网站媒体提取、下载或离线缓存。请导入本地媒体。')),
  );
}
