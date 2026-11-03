import 'model_catalog.dart';

const _languageNames = {
  'language-independent': '无需指定语言的声音处理',
  'zh': '普通话',
  'yue': '粤语',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
  'ru': '俄语',
  'pt': '葡萄牙语',
  'ar': '阿拉伯语',
  'hi': '印地语',
  'it': '意大利语',
  'vi': '越南语',
  'th': '泰语',
  'id': '印度尼西亚语',
  'ur': '乌尔都语',
  'ms': '马来语',
  'uz': '乌兹别克语',
  'fa': '波斯语',
  'bn': '孟加拉语',
  'ta': '泰米尔语',
  'te': '泰卢固语',
  'ug': '维吾尔语',
  'gu': '古吉拉特语',
  'my': '缅甸语',
  'tl': '他加禄语',
  'kk': '哈萨克语',
  'or': '奥里亚语',
  'ne': '尼泊尔语',
  'mn': '蒙古语',
  'km': '高棉语',
  'jv': '爪哇语',
  'lo': '老挝语',
  'si': '僧伽罗语',
  'fil': '菲律宾语',
  'ps': '普什图语',
  'pa': '旁遮普语',
  'kab': '卡比尔语',
  'ba': '巴什基尔语',
  'ks': '克什米尔语',
  'tg': '塔吉克语',
  'su': '巽他语',
  'mr': '马拉地语',
  'ky': '吉尔吉斯语',
  'az': '阿塞拜疆语',
  'bg': '保加利亚语',
  'hr': '克罗地亚语',
  'cs': '捷克语',
  'da': '丹麦语',
  'nl': '荷兰语',
  'et': '爱沙尼亚语',
  'fi': '芬兰语',
  'el': '希腊语',
  'hu': '匈牙利语',
  'lv': '拉脱维亚语',
  'lt': '立陶宛语',
  'mt': '马耳他语',
  'pl': '波兰语',
  'ro': '罗马尼亚语',
  'sk': '斯洛伐克语',
  'sl': '斯洛文尼亚语',
  'sv': '瑞典语',
  'uk': '乌克兰语',
  'tr': '土耳其语',
  'he': '希伯来语',
  'bo': '藏语',
};

/// The catalog lists representative tags for some general-purpose models;
/// avoid presenting their tag count as exhaustive language coverage.
String modelLanguageSummary(
  ModelArtifact model, {
  bool full = false,
  bool compact = false,
}) {
  final tags = <String>{
    for (final tag in ['zh', 'yue', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru'])
      if (model.languages.contains(tag)) tag,
    ...model.languages,
  };
  String name(String tag) =>
      tag == 'zh' && model.purpose == ModelPurpose.translation
      ? '中文'
      : _languageNames[tag] ?? tag;
  final names = tags.map(name).toList();
  const shortNames = {
    'zh': '中',
    'yue': '粤',
    'en': '英',
    'ja': '日',
    'ko': '韩',
    'fr': '法',
    'de': '德',
    'es': '西',
    'ru': '俄',
  };
  final shown = compact
      ? tags.take(5).map((tag) => shortNames[tag] ?? name(tag))
      : full
      ? names
      : names.take(5);
  final suffix = !full && names.length > 5 ? '等多种语言' : '';
  final scope = model.engine == 'qwen3' ? '常用语言：' : '支持：';
  final note = model.id.startsWith('dolphin')
      ? '；不支持英语'
      : !compact && model.id.startsWith('qwen')
      ? '；完整范围见模型说明'
      : '';
  return '$scope${shown.join('、')}$suffix$note';
}
