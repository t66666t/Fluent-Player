import 'package:flutter/material.dart';
import '../../theme/app_page_transitions.dart';

/// Preserves an old route signature but never opens online content.
class WebMediaBrowserRoute extends AppMaterialPageRoute<void> {
  WebMediaBrowserRoute({
    Uri? initialUrl,
    String? targetFolderId,
    Object? preferences,
    Object? session,
  }) : super(
         settings: const RouteSettings(name: '/removed-online-feature'),
         builder: (_) => Scaffold(
           appBar: AppBar(title: const Text('功能已移除')),
           body: const Center(child: Text('本地版不提供浏览器或在线播放，请导入本地文件。')),
         ),
       );
}
