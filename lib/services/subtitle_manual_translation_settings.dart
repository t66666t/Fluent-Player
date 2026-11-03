/// Shared defaults for the translation panel and the initial-settings export.
abstract final class SubtitleManualTranslationSettings {
  static const enabledKey = 'subtitle_translate_manual_mode_enabled';
  static const subtitleFirstKey = 'subtitle_translate_manual_prompt_first';
  static const promptKey = 'subtitle_translate_manual_prompt_editable';
  static const defaultPrompt =
      '你是一名专业字幕翻译与本地化编辑。\n'
      '严格要求：\n'
      '1) 保持原有序号、时间轴行、空行结构完全一致。千万不要删除原文本中的空白行。保留原有格式。\n'
      '2) 仅翻译字幕文本行；不要改动时间戳格式与顺序。\n'
      '3) 不要输出解释、注释、前言、后记、Markdown、代码块标记。\n'
      '4) 仅输出“可直接保存为字幕文件”的纯文本内容。\n'
      '5) 保留专有名词可读性；必要时采用约定术语。\n'
      '6) 如遇无语义内容（如音乐提示），按目标语言自然表达。';
}
