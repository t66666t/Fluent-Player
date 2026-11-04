import 'dart:convert';
import 'processing_screen_protection_timing.dart';

import 'package:flutter/widgets.dart';

import '../features/ai_chat/ai_chat_settings.dart';
import '../features/media_cache/media_cache_models.dart';
import '../features/model_center/asr_enhancement_options.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/subtitle_segmentation.dart';
import '../features/podcasts/podcast_settings.dart';
import '../features/portable_transfer/portable_export_settings_memory.dart';
import '../features/web_media/web_media_queue_settings.dart';
import '../features/youtube_download/models/youtube_download_models.dart';
import '../services/ai_subtitle_translator.dart';
import '../services/subtitle_manual_translation_settings.dart';
import '../services/subtitle_translate_settings.dart';
import 'danmaku_style.dart';

/// A profile describes the device, never a fixed screen-specific layout.
class DefaultSettingsDevice {
  const DefaultSettingsDevice(this.platform, this.size);
  final TargetPlatform platform;
  final Size size;
  bool get mobile =>
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  bool get tablet => mobile && size.shortestSide >= 600;
  bool get phone => mobile && !tablet;
  String get label => phone
      ? '手机'
      : tablet
      ? '平板'
      : '电脑';
  int get parallelDownloads => phone ? 1 : 2;
}

abstract final class RecommendedAppDefaults {
  static const version = 2;
  // Respect each downloader's own scheduling and shared connection budget.
  // Screen size is not a measure of network throughput.
  static const bilibiliConnections = 2;
  static const webMediaConnections = 32;
  static const ytDlpConcurrentFragments = 16;
  static const cacheConnections = 4;
  static const cacheConnectionBudget = 8;

  /// A shared logical-pixel velocity needs no device-size compensation.
  static double danmakuSpeed(DefaultSettingsDevice device) => 1.0;

  static const localRuleExclusions = <String, String>{
    'importPlacementRules':
        'Contains local folder identities; keep source-specific routing',
    'importSourceFolderNames': 'User-owned folder naming rules',
  };

  static Map<String, Object?> coreOverrides(DefaultSettingsDevice device) => {
    'playbackSpeed': 1.0,
    'isPlaybackSpeedLocked': false,
    'globalMute': false,
    'longPressSpeed': 2.0,
    'doubleTapSeekSeconds': 5,
    'autoPauseOnExit': device.mobile,
    'pausePlaybackWhenAppBackgrounded': device.mobile,
    'skipPortraitPlayer': !device.phone,
    'allowConcurrentPlayback': false,
    'useHardwareVideoDecoding': true,
    'autoPlayOnPageEntry': true,
    'autoPlayNextVideo': true,
    'enableVideoPreload': !device.mobile,
    'autoPlayOnCompletion': false,
    'autoPlayOnCompletionFromStart': false,
    'playlistWrapToFirst': false,
    'enableHapticFeedback': device.mobile,
    'showSystemMediaNotification': device.mobile,
    'showMiniPlaybackCard': true,
    'isLeftHandedMode': false,
    'isMirroredH': false,
    'isMirroredV': false,
    'autoLoadEmbeddedSubtitles': true,
    'showBilibiliDanmaku': true,
    'bilibiliDanmakuOnlyInVideoArea': false,
    'bilibiliDanmakuDisplayArea': .25,
    'bilibiliDanmakuOpacity': .95,
    'bilibiliDanmakuFontScale': 1.0,
    'bilibiliDanmakuReadableFontDefaults': true,
    'bilibiliDanmakuSpeed': danmakuSpeed(device),
    'bilibiliDanmakuDensity': 1.0,
    'bilibiliDanmakuPortraitDisplayArea': kDanmakuPortraitDisplayArea,
    'bilibiliDanmakuPortraitFontScale': kDanmakuPortraitFontScale,
    'bilibiliDanmakuPortraitSpeed': kDanmakuPortraitSpeed,
    'bilibiliDanmakuPortraitDensity': kDanmakuPortraitDensity,
    'bilibiliDanmakuFontFamily': kDanmakuDefaultFontFamily,
    'bilibiliDanmakuFontWeight': kDanmakuDefaultFontWeight,
    'bilibiliDanmakuUseLockedSpeedAsBaseline': true,
    'bilibiliDanmakuAutoUpdate': true,
    'copyImportedMediaToPrivateStorage': device.mobile,
    'videoComposeResolutionHeight': 1080,
    'videoComposeDeleteOutputOnTaskDelete': false,
    'batchSubtitleAutoDelete': false,
    'processingScreenProtection': true,
    'processingScreenProtectionWaitSeconds':
        ProcessingScreenProtectionTiming.defaultSeconds,
    'batchSubtitleKeepScreenAwake': false,
    'batchSubtitleEmbedSoftDeleteOriginal': false,
    'batchSubtitleEmbedAutoDeleteSrt': false,
    'batchSubtitleTranslateEnabled': false,
    'mediaLibraryRestoreLastPage': false,
    'mediaLibraryReadableCardDefaults': true,
    'mediaLibraryStartupEntry': 'folders',
    'portraitSidebarShowTimestamps': !device.phone,
    'landscapeSidebarShowTimestamps': true,
    'portraitSidebarTimeColumnRatio': .12,
    'landscapeSidebarTimeColumnRatio': .16,
    'userSubtitleSidebarWidth': device.phone ? 262.4 : 320.0,
    'userAiSidebarWidth': 0.0,
    'bilibiliCacheLimitBytes': (device.mobile ? 1024 : 2048) * 1024 * 1024,
  };

  /// These old fixed slots must be absent so the current responsive layout
  /// can select columns, readable titles and spacing for every window size.
  static const responsiveLegacyKeys = <String>{
    'homeGridCrossAxisCount',
    'homeCardTitleFontSize',
    'homeCardAspectRatio',
    'videoCardCrossAxisCount',
    'videoCardTitleFontSize',
    'videoCardAspectRatio',
    'mediaListCrossAxisCount',
    'mediaListTitleScale',
    'mediaListItemHeightScale',
    'mediaListMainSpacingScale',
    'mediaListCrossSpacingScale',
  };

  static const aiFields = <String>{
    'contextTokens',
    'contextMode',
    'fastSummaries',
    'maxOutputTokens',
    'optimizeTokens',
    'autoCompact',
    'temperature',
    'systemPrompt',
    'titlePrompt',
    'cliPrompt',
    'transcriptPrompt',
    'thinkingEnabled',
    'reasoningEffort',
    'thinkingBudget',
  };
  static const sessionFields = <String>{
    'singleVideo',
    'useCustomUserAgent',
    'userAgent',
    'socketTimeoutSeconds',
    'retries',
    'fragmentRetries',
    'concurrentFragments',
    'rateLimit',
    'forceIpv4',
    'enabledPlayerClients',
  };
  static const mixedPreferenceFields = <String, Set<String>>{
    'ai_chat_settings_v1': aiFields,
    'yt_dlp_session_config_v1': sessionFields,
    'web_media_browser_home_v1': {'desktopMode'},
  };

  static Map<String, Map<String, dynamic>> mixedValues(
    DefaultSettingsDevice device,
  ) {
    final ai = const AiChatSettings().toJson();
    final session = DownloadSessionConfig.defaults().toJson();
    return {
      'ai_chat_settings_v1': {
        for (final key in aiFields) key: ai[key],
        'optimizeTokens': false,
        'fastSummaries': false,
      },
      'yt_dlp_session_config_v1': {
        for (final key in sessionFields) key: session[key],
        'singleVideo': true,
        'socketTimeoutSeconds': 30,
        'retries': 3,
        'fragmentRetries': 3,
        'concurrentFragments': ytDlpConcurrentFragments,
        'rateLimit': null,
        'forceIpv4': false,
        'useCustomUserAgent': false,
      },
      'web_media_browser_home_v1': {'desktopMode': true},
    };
  }

  static Map<String, Object?> preferences(DefaultSettingsDevice device) => {
    'bilibili_max_concurrent': device.parallelDownloads,
    'bilibili_connections_per_video': bilibiliConnections,
    'bilibili_preferred_quality': 80,
    'bilibili_stream_preferred_quality': 80,
    'bilibili_preferred_subtitle_lang': 'zh',
    'bilibili_prefer_ai_subtitles': false,
    'bilibili_download_danmaku': true,
    'bilibili_auto_delete_import': false,
    'bilibili_online_auto_delete_import': false,
    'douyin_auto_remove_after_import': false,
    'bilibili_keep_screen_awake_during_processing': false,
    'yt_dlp_download_preferences_v1': jsonEncode(
      YtDlpDownloadPreferences(
        preferredQuality: '1080p',
        preferredSubtitleLanguages: const ['zh-Hans', 'zh', 'en'],
        autoDeleteTaskAfterImport: false,
        autoExpandTaskOptions: false,
      ).toJson(),
    ),
    'yt_dlp_speed_and_retry_defaults_v2': true,
    'yt_dlp_parallel_download_defaults_v3': true,
    'yt_dlp_keep_screen_awake_during_processing': false,
    'yt_dlp_last_output_container': 'mp4',
    'yt_dlp_last_audio_only': false,
    'web_media_queue_settings_v2': jsonEncode(
      WebMediaQueueSettings(
        parallelTasks: device.parallelDownloads,
        connections: webMediaConnections,
        retryLimit: 3,
        resumeOnStartup: false,
      ).toJson(),
    ),
    'web_media_connections': webMediaConnections,
    'douyin_manual_capture_mode': false,
    'cloudDrive.lastProvider': 'baidu',
    for (final provider in ['baidu', 'quark', 'uc', 'aliyun'])
      'cloudDrive.$provider.view': jsonEncode({
        'sort': 'naturalName',
        'descending': false,
        'foldersFirst': true,
        'filter': 'all',
      }),
    SubtitleTranslateSettings.directionKey: 'auto',
    SubtitleTranslateSettings.languageProfilesKey: jsonEncode({
      'bing': const SubtitleTranslationPair().toJson(),
    }),
    AiSubtitleTranslationSettings.preferencesKey: jsonEncode(
      AiSubtitleTranslationSettings(
        batchSize: 10,
        threadNum: device.phone ? 2 : 3,
      ).toJson(),
    ),
    SubtitleManualTranslationSettings.enabledKey: false,
    SubtitleManualTranslationSettings.subtitleFirstKey: true,
    SubtitleManualTranslationSettings.promptKey:
        SubtitleManualTranslationSettings.defaultPrompt,
    'ai_chat_reading_scale_v1': 1.0,
    for (final key in [
      PortableExportSettingsMemory.fluentPackKey,
      PortableExportSettingsMemory.zipKey,
    ])
      key: jsonEncode(
        const PortableExportRememberedSettings(
          includeSidecars: true,
          verifyChecksums: false,
          zipEmbedSubtitles: true,
          zipExternalSubtitles: true,
          includeDanmaku: true,
        ).toJson(),
      ),
    'sleepTimer.countOnlyWhilePlaying': true,
    'sleepTimer.customMinutes': 30,
    'sleepTimer.customItemCount': 3,
  };

  static const modelFields = <String>{
    'sourcePreference',
    'ocrSourcePreference',
    'language',
    'asrLanguagePreferences',
    'threads',
    'asrCpuThreads',
    'asrExecution',
    'asrEnhancements',
    'subtitlePunctuation',
    'asrAccelerationOptions',
    'translationOptions',
    'translationModelOptions',
    'subtitleSegmentation',
  };
  static Map<String, dynamic> modelValues(DefaultSettingsDevice device) => {
    'sourcePreference': 'auto',
    'ocrSourcePreference': 'auto',
    'language': 'auto',
    'asrLanguagePreferences': <String, String>{},
    'threads': device.phone ? 2 : 4,
    'asrCpuThreads': 0,
    'asrExecution': 'auto',
    'asrEnhancements': AsrEnhancementOptions.recommended.toJson(),
    'subtitlePunctuation': 'removeTrailingFullStopsAndCommas',
    'asrAccelerationOptions': <String, dynamic>{},
    'translationOptions': const LocalTranslationOptions().toJson(),
    'translationModelOptions': <String, dynamic>{},
    'subtitleSegmentation': SubtitleSegmentationOptions.natural.toJson(),
  };
  static Map<String, dynamic> cacheValues(DefaultSettingsDevice device) =>
      MediaCachePreferences(
        limits: {
          'bilibili': 80,
          'baidu': 1080,
          'quark': 1080,
          'uc': 1080,
          'aliyun': 1080,
        },
        pruneLower: false,
        parallelTasks: device.parallelDownloads,
        connectionsPerTask: cacheConnections,
        connectionBudget: cacheConnectionBudget,
      ).toJson();
  static const podcastOperationalExclusions = {
    'pauseAllUpdates': 'An active operational pause, preserved during a trial',
    'pauseAllDownloads': 'An active queue pause, preserved during a trial',
  };
  static Set<String> get podcastFields =>
      podcastSettings.map((e) => e.key).toSet()
        ..removeAll(podcastOperationalExclusions.keys);
  static Map<String, dynamic> podcastValues(DefaultSettingsDevice device) => {
    for (final definition in podcastSettings)
      if (definition.key != 'speed' &&
          definition.key != 'continuous' &&
          !podcastOperationalExclusions.containsKey(definition.key))
        definition.key: definition.defaultValue,
    'speed': null,
    'continuous': null,
    'backgroundRefresh': false,
    'notify': false,
    'autoDownload': false,
    'mediaPreference': device.mobile ? 'audio' : 'original',
    'downloadConcurrency': device.parallelDownloads,
    'cacheLimitMb': device.mobile ? 512 : 2048,
    'channelCacheMb': device.mobile ? 256 : 512,
    'downloadLimitMb': device.mobile ? 2048 : 10240,
    'cacheDays': 7,
    'deletePlayedDays': 0,
  };

  static Map<String, String> summary(DefaultSettingsDevice device) => {
    '适用设备': '${device.label}，布局继续随窗口和横竖屏适配',
    '播放': '1 倍速、不锁速、不静音；长按 2 倍速；双击前后跳 5 秒；硬件解码、预览、耳机控制开启；单播放器',
    '平台行为': device.phone
        ? '保留竖屏播放入口；离开和后台暂停；震动与系统媒体通知开启'
        : device.tablet
        ? '优先横屏播放；离开和后台暂停；震动与系统媒体通知开启'
        : '优先横屏布局；离开页面和切到后台继续播放；关闭触觉和手机通知选项',
    '连续播放':
        '自动播放下一项；列表尾部停止；关闭单项重复和从头重复；${device.mobile ? '关闭视频预加载' : '开启视频预加载'}',
    '画质': 'B 站在线播放、下载及网盘缓存以 1080p 为上限偏好；YTDLP 1080p；合成输出 1080p；不默认追求 4K',
    '下载':
        '${device.parallelDownloads} 个并行任务；B 站每视频上限 $bilibiliConnections 连接；网页每任务上限 $webMediaConnections、队列共享 32 连接；YTDLP 分片并发 $ytDlpConcurrentFragments；缓存每任务 $cacheConnections、共享预算 $cacheConnectionBudget；重试 3 次，重启不自动恢复网页下载',
    '文件保护':
        '保留原视频、外挂字幕和合成输出；导入完成后不自动删除任务；${device.mobile ? '移动端导入复制到私有存储' : '电脑端导入引用源文件'}',
    '启动页面': '关闭“打开时回到上次离开的页面”；每次打开固定进入“文件夹”主页，不自动打开上次浏览的子文件夹',
    '媒体库':
        '卡片视图；手机竖屏 3 列/横屏 6 列，平板竖屏 6 列/横屏 9 列，电脑竖屏 8 列/横屏 12 列，侧栏不改变列数；所有端共用宽 150、标题 12.5 的基准卡片，字号、封面、图标、间距、圆角和高度随卡宽严格等比例缩放；标题保留两行，默认高度按字体和辅助信息测量，不再强制宽度的 1.08 倍；系统文字放大时增加基准高度；手动设置优先；保留用户文件夹组织',
    '悬浮字幕':
        '所有语言狮尾圆体；描边 4.0；阴影模糊 3.5、距离 2.5；黑底 90%；主副字号比 100:85；普通字幕按实际视频画面等比例缩放，横竖屏共用字号与相对位置；幽灵字幕保留独立屏幕阅读尺寸，参考主字号手机 16–17、平板 22–26、电脑不超过 26 逻辑像素；手动主副字号与整体倍率继续生效',
    '字幕与弹幕':
        '自动缓存/跟随字幕、加载内嵌字幕；连续字幕关闭；弹幕显示与下载开启，关闭“弹幕仅在视频区域内展示”，不透明度 95%；思源黑体、700 字重；横竖屏分别保存字号、显示区域、速度和密度，源轨道重排到可用行，滚动/置顶/置底允许叠加，同类型只做短时入场防挤；竖屏默认手机字号约 14–16、上方 1/4 区域、50% 密度、1.0 倍（每秒 60 逻辑像素）；横屏默认字号随逻辑窗口温和变化、大小滑块 100%、上方 1/4 区域、100% 密度，初始速度 1.0 倍（每秒 60 逻辑像素），横竖屏同速；开启“以锁定倍速为弹幕速度基准”和“自动更新弹幕”；两套设置均可继续手动调整',
    '翻译与模型处理':
        '自动识别语言；自动→简体中文；AI 翻译每批 10 行、${device.phone ? 2 : 3} 并发、不反思；自动硬件加速和线程；保留当前模型与接口',
    'AI 对话':
        '与 AI 页共用推荐配置：自动文稿处理、64k 常规上下文预算、8k 单次输出、温度 0.3；开启思考，高强度及自动思考预算，按模型能力处理；关闭“智能节省 token”和“快速总结”；安全请求复用独立工作，自动压缩历史；阅读字号自适应；AI 精修标题保留',
    '音乐与播客': '歌词主副轨、逐字显示、自动定位；播客倍速/连续播放跟随软件；移动端优先音频、使用当前可用网络下载；关闭自动下载和通知',
    '缓存与打包':
        '缓存限制与并发按设备；不自动删低画质或已听下载；Fluent Pack / Zip 快速压缩、关闭校验、包含已有字幕和弹幕；Zip 同时内嵌和外挂字幕',
    '网络与同步': '国内功能直连，其他跟随设备网络；保存代理信息和配对；不自动开启跨设备同步',
    '睡眠定时': '常用值 30 分钟 / 3 项，仅播放时计时；不改正在运行的定时器',
  };
}
