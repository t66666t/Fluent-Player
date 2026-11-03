enum PodcastSettingGroup {
  updates,
  notifications,
  playback,
  cache,
  downloads,
  display,
}

class PodcastSetting {
  const PodcastSetting(
    this.key,
    this.label,
    this.group,
    this.defaultValue, {
    this.options,
    this.min,
    this.max,
    this.deviceOnly = false,
    this.description = '',
  });
  final String key, label, description;
  final PodcastSettingGroup group;
  final Object defaultValue;
  final Map<Object, String>? options;
  final num? min, max;
  final bool deviceOnly;
  Object normalize(Object? value) {
    if (value == null) return defaultValue;
    if (options != null) {
      return options!.containsKey(value) ? value : defaultValue;
    }
    if (defaultValue is bool) return value is bool ? value : defaultValue;
    if (defaultValue is num) {
      if (value is! num || !value.isFinite) return defaultValue;
      final result = value.clamp(min ?? 0, max ?? 1 << 40);
      return defaultValue is int ? result.toInt() : result.toDouble();
    }
    return value is String ? value : defaultValue;
  }
}

const podcastSettings = <PodcastSetting>[
  PodcastSetting(
    'pauseAllUpdates',
    '暂停所有自动更新',
    PodcastSettingGroup.updates,
    false,
    deviceOnly: true,
  ),
  PodcastSetting('autoRefresh', '自动检查更新', PodcastSettingGroup.updates, true),
  PodcastSetting('onLaunch', '启动时检查', PodcastSettingGroup.updates, true),
  PodcastSetting('onResume', '回到前台时检查', PodcastSettingGroup.updates, true),
  PodcastSetting('onReconnect', '恢复联网时检查', PodcastSettingGroup.updates, true),
  PodcastSetting(
    'backgroundRefresh',
    '允许后台检查',
    PodcastSettingGroup.updates,
    true,
    deviceOnly: true,
  ),
  PodcastSetting(
    'refreshMinutes',
    '检查间隔',
    PodcastSettingGroup.updates,
    60,
    options: {
      15: '15 分钟',
      30: '30 分钟',
      60: '1 小时',
      180: '3 小时',
      360: '6 小时',
      720: '12 小时',
      1440: '每天',
    },
  ),
  PodcastSetting('badges', '显示新节目数量', PodcastSettingGroup.notifications, true),
  PodcastSetting('notify', '系统更新通知', PodcastSettingGroup.notifications, false),
  PodcastSetting(
    'notificationSound',
    '通知声音',
    PodcastSettingGroup.notifications,
    false,
  ),
  PodcastSetting(
    'quietHours',
    '启用免打扰时段',
    PodcastSettingGroup.notifications,
    false,
  ),
  PodcastSetting(
    'quietStart',
    '免打扰开始（小时）',
    PodcastSettingGroup.notifications,
    22,
    min: 0,
    max: 23,
  ),
  PodcastSetting(
    'quietEnd',
    '免打扰结束（小时）',
    PodcastSettingGroup.notifications,
    8,
    min: 0,
    max: 23,
  ),
  PodcastSetting(
    'speed',
    '默认倍速',
    PodcastSettingGroup.playback,
    1.0,
    min: 0.5,
    max: 3.0,
  ),
  PodcastSetting(
    'rewindSeconds',
    '后退秒数',
    PodcastSettingGroup.playback,
    15,
    min: 5,
    max: 120,
  ),
  PodcastSetting(
    'forwardSeconds',
    '前进秒数',
    PodcastSettingGroup.playback,
    30,
    min: 5,
    max: 120,
  ),
  PodcastSetting(
    'skipIntro',
    '跳过片头（秒）',
    PodcastSettingGroup.playback,
    0,
    min: 0,
    max: 600,
  ),
  PodcastSetting(
    'skipOutro',
    '跳过片尾（秒）',
    PodcastSettingGroup.playback,
    0,
    min: 0,
    max: 600,
  ),
  PodcastSetting(
    'continuous',
    '连续播放',
    PodcastSettingGroup.playback,
    true,
    description: '播完后播放当前队列中的下一集。',
  ),
  PodcastSetting('skipPlayed', '队列跳过已听节目', PodcastSettingGroup.playback, true),
  PodcastSetting(
    'mediaPreference',
    '优先媒体版本',
    PodcastSettingGroup.playback,
    'video',
    options: {'original': '来源默认版本', 'audio': '优先音频版', 'video': '优先视频版'},
  ),
  PodcastSetting(
    'cacheEnabled',
    '缓存在线播放内容',
    PodcastSettingGroup.cache,
    true,
    description: '只保存已请求的数据，部分缓存不代表完整离线下载。',
  ),
  PodcastSetting(
    'cacheLimitMb',
    '播放缓存总上限（MB）',
    PodcastSettingGroup.cache,
    1024,
    min: 64,
    max: 65536,
    deviceOnly: true,
  ),
  PodcastSetting(
    'channelCacheMb',
    '单频道缓存预算（MB）',
    PodcastSettingGroup.cache,
    1024,
    min: 32,
    max: 65536,
  ),
  PodcastSetting(
    'cacheDays',
    '临时缓存保留天数',
    PodcastSettingGroup.cache,
    7,
    min: 1,
    max: 90,
  ),
  PodcastSetting(
    'autoDownload',
    '自动下载新节目',
    PodcastSettingGroup.downloads,
    false,
  ),
  PodcastSetting(
    'pauseAllDownloads',
    '暂停所有下载任务',
    PodcastSettingGroup.downloads,
    false,
    deviceOnly: true,
  ),
  PodcastSetting(
    'keepLatest',
    '自动下载保留最新集数',
    PodcastSettingGroup.downloads,
    3,
    min: 1,
    max: 100,
  ),
  PodcastSetting(
    'downloadConcurrency',
    '下载并发数',
    PodcastSettingGroup.downloads,
    2,
    min: 1,
    max: 4,
    deviceOnly: true,
  ),
  PodcastSetting(
    'downloadLimitMb',
    '离线下载总上限（MB）',
    PodcastSettingGroup.downloads,
    5120,
    min: 128,
    max: 1048576,
    deviceOnly: true,
  ),
  PodcastSetting(
    'deletePlayedDays',
    '已听下载延迟删除（天，0 为保留）',
    PodcastSettingGroup.downloads,
    0,
    min: 0,
    max: 90,
  ),
  PodcastSetting(
    'includeDownloadsInExport',
    '打包时包含完整下载',
    PodcastSettingGroup.downloads,
    false,
    deviceOnly: true,
  ),
  PodcastSetting(
    'density',
    '节目列表密度',
    PodcastSettingGroup.display,
    'comfortable',
    options: {'comfortable': '舒适', 'compact': '紧凑'},
  ),
  PodcastSetting(
    'sort',
    '节目排序',
    PodcastSettingGroup.display,
    'newest',
    options: {'newest': '最新优先', 'oldest': '最早优先', 'manual': '手动顺序'},
  ),
  PodcastSetting('groupSeasons', '按季分组', PodcastSettingGroup.display, false),
  PodcastSetting('hidePlayed', '隐藏已听节目', PodcastSettingGroup.display, false),
  PodcastSetting('summaries', '显示节目摘要', PodcastSettingGroup.display, true),
  PodcastSetting(
    'tint',
    '封面渐变强度',
    PodcastSettingGroup.display,
    0.18,
    min: 0.0,
    max: 0.30,
  ),
];

class PodcastPreferences {
  PodcastPreferences([Map<String, dynamic> values = const {}])
    : values = {
        for (final definition in podcastSettings)
          definition.key: definition.normalize(values[definition.key]),
      };
  final Map<String, dynamic> values;
  bool flag(String key) => values[key] == true;
  int integer(String key) => (values[key] as num).toInt();
  double number(String key) => (values[key] as num).toDouble();
  String text(String key) => values[key] as String;
  PodcastPreferences overlay(Map<String, dynamic> overrides) =>
      PodcastPreferences({...values, ...overrides});
  bool quietAt(DateTime time) {
    if (!flag('quietHours')) return false;
    final start = integer('quietStart'), end = integer('quietEnd');
    if (start == end) return true;
    return start < end
        ? time.hour >= start && time.hour < end
        : time.hour >= start || time.hour < end;
  }
}
