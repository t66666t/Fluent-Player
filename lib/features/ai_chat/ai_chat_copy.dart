import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';

/// Words the conversation UI uses for the open media.
///
/// A podcast episode stays「播客」even when the file itself is video.
/// Other audio is「音频」. Everything else stays「视频」.
class AiChatMediaCopy {
  const AiChatMediaCopy(this.noun);

  factory AiChatMediaCopy.of(VideoItem item) {
    final source = item.sourceRef;
    if (source?.podcast != null ||
        source?.kind == MediaSourceKind.podcastEpisode) {
      return const AiChatMediaCopy('播客');
    }
    if (item.type == MediaType.audio) return const AiChatMediaCopy('音频');
    return const AiChatMediaCopy('视频');
  }

  final String noun;

  String get askTitle => '询问$noun内容';
  String get hint => '询问这个$noun…';
  String get summarize => '总结这个$noun的核心内容和结论';
  String get hardConcept => '挑出$noun中最难理解的一个概念，用例子讲清楚';
  String get timestamps => '整理重点概念，并标注对应时间戳';
  String get completeNotes => '整理这个$noun从头到尾的完整笔记';
  String get completeNotesPrompt =>
      '请根据当前可用的完整文稿和资料，为这个$noun整理一份从头到尾、详尽且可独立阅读的完整笔记，'
      '目标是让我只读笔记就能理解主要内容、重要细节和完整脉络。\n\n'
      '1. 先简要说明主题、核心问题与主要结论。\n'
      '2. 按内容出现的先后顺序分章节整理，覆盖开头、中间和结尾，为各章节标注资料中可核实的时间戳；'
      '没有时间信息时不要编造。\n'
      '3. 各章节详细保留重要观点、概念定义、论证过程、原因与结果、关键事实和数据、案例、'
      '方法步骤及适用条件；原文涉及公式或操作细节时也要解释清楚。'
      '如有多位发言者，区分各自观点、共识和分歧。根据实际内容组织，不强行套用不存在的项目。\n'
      '4. 交代章节之间的逻辑联系，合并重复和口头赘述，但不要把重要内容压缩成几句概括，'
      '也不要只列标题或只整理开头的内容。篇幅以充分覆盖内容为准。\n'
      '5. 最后归纳核心要点，以及原文提出的建议、行动步骤或尚未解决的问题（如有）。\n\n'
      '忠实于来源，区分原文观点与必要的解释，不添加原文没有的事实。'
      '若文稿缺失、仅有节选或存在无法确认的内容，先说明覆盖范围和局限；'
      '不要推测未提供的画面、声音或段落，也不要声称已完整覆盖。';
  String get previewQuestion => '总结这个$noun的核心内容';
  String get sources => '$noun资料';
  String get info => '$noun信息';
  String get infoOnly => '仅使用$info';
  String get noTranscript => '没有可用文稿，可先根据$info提问。';
  String get sourcesFailed => '$sources加载失败，仍可进行普通 AI 对话。';
  String get chapters => '$noun章节';
  String get exportHeading => '$noun：';

  /// Shown as the usage line「资料方式」. Not sent to the model.
  String get metadataMode => '$noun元信息';
}
