import '../../models/video_item.dart';
import 'external_ai_actions.dart';
import 'external_ai_library_source.dart';

Map<String, dynamic> externalAiSubtitlePresentation({
  required bool optimize,
  required bool translate,
  bool loadSubtitles = true,
}) => {
  'mode': loadSubtitles ? 'apply_when_complete' : 'save_only',
  'primary': optimize ? 'optimized' : 'source',
  'secondary': translate ? 'translation' : 'keep_existing',
  'selectionTool': 'subtitle_select',
  'note': !loadSubtitles
      ? '本批只保存新稿，不改变主副字幕。完成后告知名称及可选方案；用户要求时可再选。'
      : optimize && translate
      ? '完成后主字幕用精校稿、副字幕用基于精校稿的译稿，原稿保留。'
      : optimize
      ? '完成后主字幕用精校稿，保留原副字幕，原稿保留。'
      : '完成后主字幕用本次源稿、副字幕用译稿，原稿保留。',
  'userIntent':
      '用户明确只保存、要译稿做主字幕、交换主副或关闭副字幕时优先按要求；默认方案无需反复询问。处理期间用户换过字幕则保留其选择，说明新稿位置，不静默覆盖。',
  'reportResult':
      '完成后说明新稿名称、实际主字幕/副字幕及是否已保存选择；未播放的媒体也可保存选择，loadedForCurrentMedia=false不等于选择失败。',
};

/// Stable application boundary: MCP does not implement batching, inference,
/// optimizers, provider protocols or the application's internal progress steps.
abstract class ExternalAiSubtitleBackend {
  String mediaIdentity(VideoItem item);
  Future<Map<String, dynamic>> subtitleOptions();
  Future<Map<String, dynamic>> captureSubtitlePlan(
    Map<String, dynamic> request,
  );
  Future<void> startSubtitleRecognition(
    VideoItem media,
    String taskId,
    Map<String, dynamic> plan,
    void Function() guard,
  );
  Future<void> pauseSubtitleRecognition(VideoItem media, String taskId);
  Future<void> cancelSubtitleRecognition(VideoItem media, String taskId);
  Future<String?> recognitionAssetId(VideoItem media, String taskId);
  List<ExternalAiNativeTask> tasks();
  void addTaskListener(void Function() listener);
  void removeTaskListener(void Function() listener);
  Future<ExternalAiSubtitleOutput> runSubtitleWorkflow(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required bool optimize,
    required bool translate,
    bool completedOnly = false,
    required Map<String, dynamic> plan,
    required Future<void> cancelSignal,
    required void Function(double, Map<String, dynamic>) onProgress,
    required void Function() guard,
  });
  Future<Map<String, dynamic>> publishProcessedSubtitle(
    ExternalAiSubtitleDocument source, {
    required String workId,
    required String operation,
    required String executor,
    required String language,
    required List<String> texts,
    required void Function() guard,
  });
  Future<Map<String, dynamic>> selectProcessedSubtitles(
    ExternalAiSubtitleDocument source, {
    String? primaryAssetId,
    String? secondaryAssetId,
    required Map<String, dynamic> plan,
    required void Function() guard,
  });
}

class ExternalAiSubtitleOutput {
  const ExternalAiSubtitleOutput({
    this.optimized,
    this.translated,
    this.warning,
  });
  final List<String>? optimized, translated;
  final String? warning;
}

/// Only errors with an app-authored safe recovery contract reach MCP status.
/// Provider and OS exceptions are deliberately not converted to this type.
class ExternalAiSubtitleWorkflowError extends ExternalAiActionError {
  ExternalAiSubtitleWorkflowError(this.code, String message, this.nextTool)
    : super(message);
  final String code, nextTool;
}
