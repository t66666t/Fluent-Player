import 'dart:convert';
import '../../models/subtitle_model.dart';

enum CloudAsrProvider { elevenlabs, soniox, assemblyai, deepgram, gemini }

extension CloudAsrProviderInfo on CloudAsrProvider {
  String get label => switch (this) {
    CloudAsrProvider.elevenlabs => 'ElevenLabs',
    CloudAsrProvider.soniox => 'Soniox',
    CloudAsrProvider.assemblyai => 'AssemblyAI',
    CloudAsrProvider.deepgram => 'Deepgram',
    CloudAsrProvider.gemini => 'Google Gemini',
  };
  String get endpoint => switch (this) {
    CloudAsrProvider.elevenlabs => 'https://api.elevenlabs.io',
    CloudAsrProvider.soniox => 'https://api.soniox.com',
    CloudAsrProvider.assemblyai => 'https://api.assemblyai.com',
    CloudAsrProvider.deepgram => 'https://api.deepgram.com',
    CloudAsrProvider.gemini => 'https://generativelanguage.googleapis.com',
  };
  String get defaultModel => switch (this) {
    CloudAsrProvider.elevenlabs => 'scribe_v2',
    CloudAsrProvider.soniox => 'stt-async-v5',
    CloudAsrProvider.assemblyai => 'universal-3-5-pro',
    CloudAsrProvider.deepgram => 'nova-3',
    CloudAsrProvider.gemini => 'gemini-3.5-transcribe',
  };
}

/// Public capabilities, never a claim that an account or model was tested.
class CloudAsrCapabilities {
  const CloudAsrCapabilities({
    this.languages = const [],
    this.documented = false,
    this.wordTimestamps = false,
    this.automaticLanguage = false,
    this.incompatibleOptions = const [],
    this.speakers = false,
    this.characters = false,
    this.maxHotwords = 0,
    this.maxBytes = 20000000,
    this.maxSeconds = 600,
    this.minMilliseconds = 1,
  });
  final List<String> languages;
  final bool documented,
      wordTimestamps,
      automaticLanguage,
      speakers,
      characters;
  final List<String> incompatibleOptions;
  final int maxHotwords, maxBytes, maxSeconds, minMilliseconds;
  Map<String, dynamic> toJson() => {
    'languages': languages,
    'documented': documented,
    'wordTimestamps': wordTimestamps,
    'automaticLanguage': automaticLanguage,
    'incompatibleOptions': incompatibleOptions,
    'speakers': speakers,
    'characters': characters,
    'maxHotwords': maxHotwords,
    'maxBytes': maxBytes,
    'maxSeconds': maxSeconds,
    'minMilliseconds': minMilliseconds,
  };
  factory CloudAsrCapabilities.fromJson(Map<String, dynamic> value) =>
      CloudAsrCapabilities(
        languages: (value['languages'] as List? ?? [])
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty && s != 'auto')
            .toSet()
            .toList(),
        documented: value['documented'] == true,
        wordTimestamps: value['wordTimestamps'] == true,
        automaticLanguage: value['automaticLanguage'] == true,
        incompatibleOptions: (value['incompatibleOptions'] as List? ?? [])
            .whereType<String>()
            .toList(),
        speakers: value['speakers'] == true,
        characters: value['characters'] == true,
        maxHotwords: (value['maxHotwords'] as num?)?.toInt() ?? 0,
        maxBytes: (value['maxBytes'] as num?)?.toInt() ?? 20000000,
        maxSeconds: (value['maxSeconds'] as num?)?.toInt() ?? 600,
        minMilliseconds: (value['minMilliseconds'] as num?)?.toInt() ?? 1,
      );
}

class CloudAsrOptions {
  const CloudAsrOptions({
    this.diarize = false,
    this.characterTiming = false,
    this.hotwords = const [],
    this.contractVersion = 1,
  });
  final bool diarize, characterTiming;
  final List<String> hotwords;
  final int contractVersion;
  Map<String, dynamic> toJson() => {
    'contractVersion': contractVersion,
    'diarize': diarize,
    'characterTiming': characterTiming,
    'hotwords': hotwords,
  };
  factory CloudAsrOptions.fromJson(Map<String, dynamic> value) =>
      CloudAsrOptions(
        contractVersion: (value['contractVersion'] as num?)?.toInt() ?? 1,
        diarize: value['diarize'] == true,
        characterTiming: value['characterTiming'] == true,
        hotwords: (value['hotwords'] as List? ?? [])
            .whereType<String>()
            .toList(),
      );
  void validate(CloudAsrProvider provider, CloudAsrCapabilities capabilities) {
    if (contractVersion != 1) throw StateError('此云端转录协议需要更新软件后使用');
    if (diarize && !capabilities.speakers ||
        characterTiming && !capabilities.characters) {
      throw StateError('所选模型未确认支持此时间轴或说话人选项');
    }
    if (hotwords.length > capabilities.maxHotwords) {
      throw StateError('当前模型最多支持 ${capabilities.maxHotwords} 个热词');
    }
    // These vendors do not expose their tokenizers. Byte ceilings are an
    // intentionally conservative app budget, not a claimed exact token count.
    if (provider == CloudAsrProvider.soniox &&
        utf8.encode(jsonEncode({'terms': hotwords})).length > 7500) {
      throw StateError('Soniox 术语过长，请精简后保存（已预留厂商上下文限制）');
    }
    if (provider == CloudAsrProvider.deepgram &&
        utf8.encode(hotwords.join(' ')).length > 450) {
      throw StateError('Deepgram 术语过长，请精简后保存（已预留厂商 500-token 限制）');
    }
    for (final word in hotwords) {
      if (word.trim().isEmpty || word.contains(RegExp(r'[\r\n]'))) {
        throw StateError('热词不能为空或包含换行');
      }
      if (provider == CloudAsrProvider.elevenlabs &&
          (word.length >= 50 ||
              word.split(RegExp(r'\s+')).length > 5 ||
              word.contains(RegExp(r'[<>{}\[\]\\]')))) {
        throw StateError('ElevenLabs 热词须少于 50 字符、最多 5 个单词，且不含括号等特殊字符');
      }
      if (provider == CloudAsrProvider.assemblyai &&
          word.split(RegExp(r'\s+')).length > 6) {
        throw StateError('AssemblyAI 每条热词最多 6 个单词');
      }
    }
  }
}

class CloudAsrModelInfo {
  const CloudAsrModelInfo({
    required this.id,
    required this.capabilities,
    this.name = '',
    this.source = '内置官方文档',
    this.available = true,
  });
  final String id, name, source;
  final bool available;
  final CloudAsrCapabilities capabilities;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'available': available,
    'capabilities': capabilities.toJson(),
  };
  factory CloudAsrModelInfo.fromJson(Map<String, dynamic> value) =>
      CloudAsrModelInfo(
        id: value['id'] as String,
        name: value['name'] as String? ?? '',
        source: value['source'] as String? ?? '缓存',
        available: value['available'] != false,
        capabilities: CloudAsrCapabilities.fromJson(
          Map<String, dynamic>.from(value['capabilities'] as Map? ?? {}),
        ),
      );
}

const _sonioxLanguages = [
  'zh',
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
  'ru',
  'it',
  'pt',
  'ar',
  'hi',
  'id',
  'th',
  'vi',
  'tr',
  'uk',
  'nl',
  'pl',
  'sv',
  'da',
  'fi',
  'cs',
  'el',
  'hu',
  'ro',
  'af',
  'sq',
  'az',
  'eu',
  'be',
  'bn',
  'bs',
  'bg',
  'ca',
  'hr',
  'et',
  'gl',
  'gu',
  'he',
  'kn',
  'kk',
  'lv',
  'lt',
  'mk',
  'ms',
  'ml',
  'mr',
  'no',
  'fa',
  'pa',
  'sr',
  'sk',
  'sl',
  'sw',
  'tl',
  'ta',
  'te',
  'ur',
  'cy',
];
// Scribe v2's own language list; deliberately independent of other providers.
const _elevenLabsLanguages = [
  'zh',
  'yue',
  'en',
  'ja',
  'ko',
  'af',
  'am',
  'ar',
  'hy',
  'as',
  'ast',
  'az',
  'be',
  'bn',
  'bs',
  'bg',
  'my',
  'ca',
  'ceb',
  'ny',
  'hr',
  'cs',
  'da',
  'nl',
  'et',
  'fil',
  'fi',
  'fr',
  'ff',
  'gl',
  'lg',
  'ka',
  'de',
  'el',
  'gu',
  'ha',
  'he',
  'hi',
  'hu',
  'is',
  'ig',
  'id',
  'ga',
  'it',
  'jv',
  'kea',
  'kn',
  'kk',
  'km',
  'ku',
  'ky',
  'lo',
  'lv',
  'ln',
  'lt',
  'luo',
  'lb',
  'mk',
  'ms',
  'ml',
  'mt',
  'mi',
  'mr',
  'mn',
  'ne',
  'nso',
  'no',
  'oc',
  'or',
  'ps',
  'fa',
  'pl',
  'pt',
  'pa',
  'ro',
  'ru',
  'sr',
  'sn',
  'sd',
  'si',
  'sk',
  'sl',
  'so',
  'es',
  'sw',
  'sv',
  'ta',
  'tg',
  'te',
  'th',
  'tr',
  'uk',
  'umb',
  'ur',
  'uz',
  'vi',
  'cy',
  'wo',
  'xh',
  'zu',
  'yo',
];
const _assemblyProLanguages = [
  'en',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ar',
  'da',
  'nl',
  'fi',
  'he',
  'hi',
  'ja',
  'zh',
  'no',
  'sv',
  'tr',
  'vi',
];
const _deepgramMultiLanguages = [
  'af',
  'ar',
  'be',
  'bn',
  'bs',
  'bg',
  'ca',
  'zh-HK',
  'zh',
  'hr',
  'cs',
  'da',
  'nl',
  'en',
  'et',
  'fi',
  'nl-BE',
  'fr',
  'gl',
  'de',
  'el',
  'gu',
  'he',
  'hi',
  'hu',
  'id',
  'it',
  'ja',
  'kn',
  'ko',
  'lv',
  'lt',
  'mk',
  'ms',
  'mr',
  'no',
  'fa',
  'pl',
  'pt',
  'ro',
  'ru',
  'sr',
  'sk',
  'sl',
  'es',
  'sv',
  'tl',
  'ta',
  'te',
  'th',
  'tr',
  'uk',
  'vi',
  'xh',
  'zu',
];
const _geminiLanguages = [
  'af-ZA',
  'am-ET',
  'ar-EG',
  'hy-AM',
  'as-IN',
  'az-AZ',
  'be-BY',
  'bn-BD',
  'bn-IN',
  'bs-BA',
  'bg-BG',
  'rup-BG',
  'my-MM',
  'yue-Hant-HK',
  'ca-ES',
  'ceb',
  'km-KH',
  'hr-HR',
  'cs-CZ',
  'da-DK',
  'nl-NL',
  'en-GB',
  'en-IN',
  'en-US',
  'et-EE',
  'fa-IR',
  'fil-PH',
  'fi-FI',
  'fr-FR',
  'gl-ES',
  'ka-GE',
  'de-DE',
  'el-GR',
  'gu-IN',
  'ha-NG',
  'he-IL',
  'hi-IN',
  'hu-HU',
  'is-IS',
  'id-ID',
  'it-IT',
  'ja-JP',
  'jv-ID',
  'kea-CV',
  'kn-IN',
  'kk-KZ',
  'ko-KR',
  'ky-KG',
  'lv-LV',
  'ln-CD',
  'lt-LT',
  'mk-MK',
  'ms-MY',
  'ml-IN',
  'mt-MT',
  'cmn-Hans-CN',
  'mr-IN',
  'mn-MN',
  'ne-NP',
  'nb-NO',
  'or-IN',
  'pl-PL',
  'pt-BR',
  'pt-PT',
  'pa-IN',
  'pa-Guru-IN',
  'ro-RO',
  'ru-RU',
  'sr-RS',
  'sd-Arab-IN',
  'sk-SK',
  'sl-SI',
  'es-419',
  'es-US',
  'sw-KE',
  'sv-SE',
  'tg-TJ',
  'te-IN',
  'th-TH',
  'tr-TR',
  'uk-UA',
  'uz-UZ',
  'vi-VN',
];

CloudAsrCapabilities cloudAsrCapabilities(
  CloudAsrProvider provider,
  String model,
) {
  final known = model == provider.defaultModel;
  if (!known) return const CloudAsrCapabilities();
  return CloudAsrCapabilities(
    documented: true,
    wordTimestamps: true,
    automaticLanguage: true,
    incompatibleOptions: provider == CloudAsrProvider.gemini
        ? const ['wordTimestamps:hotwords', 'wordTimestamps:smart']
        : const [],
    minMilliseconds: provider == CloudAsrProvider.elevenlabs ? 100 : 1,
    speakers: true,
    characters: provider == CloudAsrProvider.elevenlabs,
    languages: switch (provider) {
      CloudAsrProvider.gemini => _geminiLanguages,
      CloudAsrProvider.deepgram => _deepgramMultiLanguages,
      CloudAsrProvider.assemblyai => _assemblyProLanguages,
      CloudAsrProvider.elevenlabs => _elevenLabsLanguages,
      CloudAsrProvider.soniox => _sonioxLanguages,
    },
    maxHotwords: switch (provider) {
      CloudAsrProvider.gemini => 0, // Word timestamps exclude vocabulary hints.
      CloudAsrProvider.deepgram => 100,
      _ => 1000,
    },
    maxBytes: switch (provider) {
      CloudAsrProvider.elevenlabs =>
        2999999999, // Stricter of conflicting docs.
      CloudAsrProvider.assemblyai =>
        2199999999, // Upload, not URL import limit.
      CloudAsrProvider.deepgram || CloudAsrProvider.gemini => 1999999999,
      CloudAsrProvider.soniox =>
        20000000, // No published per-file byte ceiling.
    },
    maxSeconds: switch (provider) {
      CloudAsrProvider.elevenlabs || CloudAsrProvider.assemblyai => 36000,
      CloudAsrProvider.soniox => 18000,
      CloudAsrProvider.gemini => 1800,
      CloudAsrProvider.deepgram => 600,
    },
  );
}

List<CloudAsrModelInfo> builtinCloudAsrModels(CloudAsrProvider provider) => [
  for (final id in [provider.defaultModel])
    CloudAsrModelInfo(id: id, capabilities: cloudAsrCapabilities(provider, id)),
];

class CloudAsrConnection {
  const CloudAsrConnection({
    required this.provider,
    required this.endpoint,
    required this.model,
    required this.apiKey,
    this.language = 'auto',
    this.options = const CloudAsrOptions(),
    required this.capabilities,
  });
  final CloudAsrProvider provider;
  final String endpoint, model, apiKey, language;
  final CloudAsrOptions options;
  final CloudAsrCapabilities capabilities;
  Uri url(String path) {
    final root = Uri.parse(endpoint);
    if (root.scheme != 'https' &&
        !(root.scheme == 'http' &&
            ['localhost', '127.0.0.1', '::1'].contains(root.host))) {
      throw StateError('云端转录地址须使用 HTTPS');
    }
    if (!root.hasAuthority || root.userInfo.isNotEmpty) {
      throw StateError('服务地址无效');
    }
    return root.resolve(path);
  }

  Map<String, String> get headers => switch (provider) {
    CloudAsrProvider.elevenlabs => {'xi-api-key': apiKey},
    CloudAsrProvider.deepgram => {'Authorization': 'Token $apiKey'},
    CloudAsrProvider.gemini => {'x-goog-api-key': apiKey},
    CloudAsrProvider.assemblyai => {'Authorization': apiKey},
    CloudAsrProvider.soniox => {'Authorization': 'Bearer $apiKey'},
  };
}

class CloudAsrResult {
  const CloudAsrResult(this.cues, {this.model = '', this.languages = const []});
  final List<SubtitleItem> cues;
  final String model;
  final List<String> languages;
}

/// Errors are safe to show: raw service bodies may echo credentials or URLs.
class CloudAsrException implements Exception {
  const CloudAsrException(
    this.message, {
    this.tooLarge = false,
    this.format = false,
    this.statusCode,
  });
  final String message;
  final bool tooLarge, format;
  final int? statusCode;
  @override
  String toString() => message;
}
