import 'package:flutter/material.dart';

enum HomeSearchScope {
  library('媒体库', Icons.video_library_outlined, '输入文件夹或媒体名称'),
  podcasts('播客页', Icons.podcasts_rounded, '搜索已订阅的频道或节目'),
  podcastSearch('播客搜索页', Icons.travel_explore_rounded, '搜索在线播客、作者'),
  bilibili('哔哩哔哩搜索页', Icons.live_tv_rounded, '搜索视频、UP 主'),
  baidu('百度网盘', Icons.cloud_outlined, '搜索百度网盘根目录'),
  quark('夸克网盘', Icons.cloud_outlined, '搜索夸克网盘根目录'),
  uc('UC网盘', Icons.cloud_outlined, '搜索 UC 网盘根目录'),
  aliyun('阿里云盘', Icons.cloud_outlined, '搜索阿里云盘根目录');

  const HomeSearchScope(this.label, this.icon, this.hint);
  final String label;
  final IconData icon;
  final String hint;
  bool get isCloud => index >= baidu.index;
}

class HomeSearchRequest {
  const HomeSearchRequest({required this.scope, required this.query});
  final HomeSearchScope scope;
  final String query;
}
