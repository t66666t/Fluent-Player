import '../../services/subtitle_translation_languages.dart';
import 'asr_enhancement_processing.dart';
import 'model_adapters.dart';
import 'model_catalog.dart';

/// Recognition capabilities belong to the selected export/service, not to a
/// generic translation-language list. Frozen jobs keep their original codes.
class AsrLanguageOptions {
  const AsrLanguageOptions({
    this.languages = const [],
    this.fixedLanguage,
    this.hintSupported = false,
    this.description = '',
    this.automaticLabel = '自动识别',
    this.preserveCodes = false,
  });
  final List<String> languages;
  final String? fixedLanguage;
  final bool hintSupported;
  final bool preserveCodes;
  final String description, automaticLabel;
  List<String> get codes => fixedLanguage != null
      ? [fixedLanguage!]
      : ['auto', ...languages.where((l) => l != 'auto').toSet()];
  bool get editable => fixedLanguage == null && languages.isNotEmpty;

  String normalize(String value) {
    if (preserveCodes) {
      if (value == 'auto') return value;
      return languages.where((code) => code.toLowerCase() == value.toLowerCase()).firstOrNull ?? value;
    }
    var code = normalizeAsrLanguage(value);
    if (code.isEmpty || code == 'auto-detect' || code == 'und') code = 'auto';
    if (code == 'tl' && languages.contains('fil')) code = 'fil';
    if (code == 'fil' && languages.contains('tl')) code = 'tl';
    if (code == 'nb' && languages.contains('no')) code = 'no';
    return code;
  }

  String resolve(String preference) {
    if (fixedLanguage != null) return fixedLanguage!;
    final code = normalize(preference);
    return codes.contains(code) ? code : 'auto';
  }

  String label(String code) =>
      code == 'auto' ? automaticLabel : preserveCodes ? cloudAsrLanguageLabel(code) : asrLanguageLabel(code);
}

String asrLanguagePreferenceKey(ModelServiceProfile profile) => profile.local
    ? 'local:${profile.model}'
    : profile.cloudProvider != null ? '${profile.kind.name}:${profile.id}:${profile.model}'
    : '${profile.kind.name}:${profile.model}';

String cloudAsrLanguageLabel(String code) {
  final base = code.toLowerCase() == 'zh-hk' ? 'yue' : code.split('-').first;
  final name = asrLanguageLabel(switch (base) { 'cmn' => 'zh', 'nb' => 'no', _ => base });
  return name == code ? code : '$name（$code）';
}

const _common = [
  'zh', 'yue', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru', 'it', 'pt',
  'ar', 'hi', 'id', 'th', 'vi', 'tr', 'uk', 'nl', 'pl', 'sv', 'da', 'fi',
  'cs', 'el', 'hu', 'ro',
];
const _funAsr = [
  'zh',
  'en',
  'ja',
  'ko',
  'vi',
  'th',
  'id',
  'ms',
  'tl',
  'hi',
  'ar',
  'fr',
  'de',
  'es',
  'pt',
  'ru',
  'it',
  'nl',
  'sv',
  'da',
  'fi',
  'no',
  'el',
  'pl',
  'cs',
  'hu',
  'ro',
  'bg',
  'hr',
  'sk',
];

AsrLanguageOptions asrLanguageOptions(
  ModelServiceProfile profile, {
  ModelArtifact? model,
}) {
  if (profile.cloudProvider case final provider?) {
    final capabilities = profile.cloudCapabilities ?? cloudAsrCapabilities(provider, profile.model);
    return AsrLanguageOptions(languages: capabilities.languages, hintSupported: true,
      automaticLabel: provider == CloudAsrProvider.deepgram && !capabilities.automaticLanguage
        ? '模型默认语言' : '自动识别',
      preserveCodes: true, description: capabilities.documented
        ? '自动识别或按当前模型的官方语言列表指定。'
        : '此新模型的完整能力尚未确认；使用默认语言方式，附加功能关闭。');
  }
  if (profile.local) {
    if (model == null) {
      return const AsrLanguageOptions(description: '请先选择可用的本地转录模型');
    }
    final fixed = localAsrAdapters[model.engine]?.fixedLanguage;
    final languages = <String>{
      for (final code in model.languages)
        if (code != 'auto')
          if (code == 'tl' && model.languages.contains('fil')) 'fil' else code,
    };
    final preferred = ['zh', 'yue', 'en', 'ja', 'ko'];
    final ordered = [
      ...preferred.where(languages.contains),
      ...languages.where((l) => !preferred.contains(l)),
    ];
    final hint = const {
      'sensevoice',
      'qwen3-asr',
      'whisper',
    }.contains(model.engine);
    return AsrLanguageOptions(
      languages: ordered,
      fixedLanguage: fixed ?? (ordered.length == 1 ? ordered.single : null),
      hintSupported: hint,
      description: fixed != null || ordered.length == 1
          ? '此模型仅用于${asrLanguageLabel(fixed ?? ordered.single)}，无需选择其他语言。'
          : hint
          ? '只列出此模型支持的语言；选择会用于识别及后续字幕处理。'
          : '此模型自行识别语音语言；指定语言用于字幕分词、时间精校和翻译，不强制改变模型输出。',
    );
  }
  if (profile.kind == TranscriptionServiceKind.openai) {
    final official = Uri.tryParse(profile.endpoint)?.host == 'api.openai.com';
    return AsrLanguageOptions(
      languages: [for (final code in _common) if (!official || code != 'yue') code],
      hintSupported: true,
      description: '语言提示随请求发送；自定义接口的实际支持范围以所配置的服务模型为准。',
    );
  }
  if (profile.kind == TranscriptionServiceKind.aliyun) {
    // These are the file-transcription APIs used by the existing adapter.
    // Unknown/realtime models must not receive guessed language parameters.
    final languages = switch (profile.model) {
      'fun-asr' => _funAsr,
      'paraformer-v1' => const ['zh', 'en'],
      'paraformer-v2' => const [
        'zh',
        'en',
        'ja',
        'yue',
        'ko',
        'de',
        'fr',
        'ru',
      ],
      'paraformer-mtl-v1' => const [
        'zh',
        'en',
        'ja',
        'ko',
        'es',
        'id',
        'fr',
        'de',
        'it',
        'ms',
      ],
      'paraformer-8k-v1' || 'paraformer-8k-v2' => const ['zh'],
      _ => const <String>[],
    };
    return AsrLanguageOptions(
      languages: languages,
      hintSupported:
          profile.model.startsWith('fun-asr') ||
          profile.model == 'paraformer-v2',
      fixedLanguage: languages.length == 1 ? languages.single : null,
      description: languages.isEmpty
          ? '当前接口模型的语言范围尚未核实，沿用服务端自动识别。'
          : '按所选百炼录音转录模型提供语言选项；支持提示的模型会发送语言提示。',
    );
  }
  if (profile.kind == TranscriptionServiceKind.tencent) {
    final suffix = profile.model.replaceFirst(RegExp(r'^\d+k_'), '');
    final languages = switch (suffix) {
      'zh_en' => const ['zh', 'en'],
      'zh-PY' => const ['zh', 'en', 'yue'],
      'zh' ||
      'zh-TW' ||
      'zh_video' ||
      'zh_dialect' ||
      'zh_medical' => const ['zh'],
      'ca' || 'yue' => const ['yue'],
      _ =>
        const {
              'en',
              'ja',
              'ko',
              'vi',
              'ms',
              'id',
              'fil',
              'th',
              'pt',
              'tr',
              'ar',
              'es',
              'hi',
              'fr',
              'de',
            }.contains(suffix)
            ? [suffix]
            : const <String>[],
    };
    return AsrLanguageOptions(
      languages: languages,
      fixedLanguage: languages.length == 1 ? languages.single : null,
      description: '识别语种由腾讯云引擎模型决定；多语种模型的语言选择用于后续字幕处理，不切换付费引擎。',
    );
  }
  return AsrLanguageOptions(
    automaticLabel: profile.kind == TranscriptionServiceKind.gongyi
        ? '服务自动识别'
        : '由服务模型决定',
    description: profile.kind == TranscriptionServiceKind.gongyi
        ? '当前公益接口自动识别语言，不接受手动语言提示。'
        : '当前接口未提供已适配的语言选择。',
  );
}

/// Only verified file-transcription hint contracts are sent to paid services.
List<String>? aliyunAsrLanguageHints(ModelServiceProfile profile) {
  final options = asrLanguageOptions(profile);
  final code = options.normalize(profile.language);
  return options.hintSupported && code != 'auto' && options.codes.contains(code)
      ? [code]
      : null;
}

String asrLanguageLabel(String code) =>
    const {
      'auto': '自动识别',
      'zh': '普通话',
      'yue': '粤语',
      'tl': '菲律宾语',
      'fil': '菲律宾语',
      'no': '挪威语',
      'ba': '巴什基尔语',
      'kab': '卡拜尔语',
      'ks': '克什米尔语',
      'tg': '塔吉克语',
      'su': '巽他语',
      'or': '奥里亚语',
      'jv': '爪哇语',
      'jw': '爪哇语',
      'ne': '尼泊尔语',
      'ps': '普什图语',
      'pa': '旁遮普语',
      'mr': '马拉地语',
      'ky': '吉尔吉斯语',
      'az': '阿塞拜疆语',
    }[code] ??
    subtitleLanguageLabel(code);
