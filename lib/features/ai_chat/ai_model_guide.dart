import 'ai_chat_settings.dart';

/// What a catalog row is for. Specialized roles are listed after chat models.
enum AiModelRole {
  chat,
  reasoning,
  vision,
  code,
  embedding,
  rerank,
  speech,
  image,
  moderation,
}

/// Relative age inside the catalog the user is looking at, not a global ranking.
enum AiModelAge { latest, previous, older, unknown }

/// Display facts for one model. Context estimates are never request limits.
class AiModelPresentation {
  const AiModelPresentation({
    required this.model,
    required this.role,
    required this.age,
    required this.freshness,
    required this.rank,
    required this.referenceContextTokens,
    required this.releasedLabel,
    required this.specialized,
  });

  final AiModelInfo model;
  final AiModelRole role;
  final AiModelAge age;
  final int freshness;
  final int rank;
  final int? referenceContextTokens;
  final String? releasedLabel;
  final bool specialized;

  int? get displayContext => model.contextWindow ?? referenceContextTokens;
  bool get contextIsEstimate =>
      model.contextWindow == null && referenceContextTokens != null;

  String get roleLabel => switch (role) {
    AiModelRole.chat => '对话',
    AiModelRole.reasoning => '推理',
    AiModelRole.vision => '视觉',
    AiModelRole.code => '代码',
    AiModelRole.embedding => '嵌入',
    AiModelRole.rerank => '重排序',
    AiModelRole.speech => '语音',
    AiModelRole.image => '图像',
    AiModelRole.moderation => '审核',
  };

  String get ageLabel => switch (age) {
    AiModelAge.latest => '最新',
    AiModelAge.previous => '上一代',
    AiModelAge.older => '较早',
    AiModelAge.unknown => '时间未知',
  };

  /// Flagship / light labels only help when choosing a chat-style model.
  String get sizeLabel {
    if (specialized) return '';
    if (rank >= 4) return '旗舰';
    if (rank <= 2) return '轻量';
    return '';
  }

  String get headline {
    final size = sizeLabel;
    if (size.isEmpty) return roleLabel;
    return '$size$roleLabel';
  }

  String get groupTitle {
    if (specialized) return '专用模型';
    return switch (age) {
      AiModelAge.latest => '最新',
      AiModelAge.previous => '上一代',
      AiModelAge.older => '较早的型号',
      AiModelAge.unknown => '未标明时间',
    };
  }
}

class _ModelFacts {
  const _ModelFacts({
    required this.role,
    required this.freshness,
    required this.rank,
    required this.referenceContextTokens,
    required this.releasedLabel,
    required this.specialized,
  });

  final AiModelRole role;
  final int freshness;
  final int rank;
  final int? referenceContextTokens;
  final String? releasedLabel;
  final bool specialized;
}

const _specializedRoles = {
  AiModelRole.embedding,
  AiModelRole.rerank,
  AiModelRole.speech,
  AiModelRole.image,
  AiModelRole.moderation,
};

/// Orders a provider catalog so newer general models come first.
///
/// Dates from the service win. Otherwise an id date (`2026-04-02`) or a
/// known family anchor is used only to sort and to label 最新 / 上一代 / 较早.
List<AiModelPresentation> presentModels(List<AiModelInfo> models) {
  final facts = [for (final model in models) _factsFor(model)];
  var newest = 0;
  for (final fact in facts) {
    if (!fact.specialized && fact.freshness > newest) newest = fact.freshness;
  }
  if (newest == 0) {
    for (final fact in facts) {
      if (fact.freshness > newest) newest = fact.freshness;
    }
  }
  final presented = <AiModelPresentation>[
    for (var index = 0; index < models.length; index++)
      AiModelPresentation(
        model: models[index],
        role: facts[index].role,
        age: _age(facts[index], newest),
        freshness: facts[index].freshness,
        rank: facts[index].rank,
        referenceContextTokens: facts[index].referenceContextTokens,
        releasedLabel: facts[index].releasedLabel,
        specialized: facts[index].specialized,
      ),
  ];
  presented.sort(_compare);
  return presented;
}

int _group(AiModelPresentation item) {
  if (item.specialized) return 4;
  return switch (item.age) {
    AiModelAge.latest => 0,
    AiModelAge.previous => 1,
    AiModelAge.older => 2,
    AiModelAge.unknown => 3,
  };
}

int _compare(AiModelPresentation a, AiModelPresentation b) {
  final group = _group(a).compareTo(_group(b));
  if (group != 0) return group;
  final fresh = b.freshness.compareTo(a.freshness);
  if (fresh != 0) return fresh;
  final rank = b.rank.compareTo(a.rank);
  if (rank != 0) return rank;
  return a.model.displayName.toLowerCase().compareTo(
    b.model.displayName.toLowerCase(),
  );
}

AiModelAge _age(_ModelFacts fact, int newest) {
  if (fact.freshness <= 0 || newest <= 0) return AiModelAge.unknown;
  final days = _daysBetween(newest, fact.freshness);
  if (days <= 200) return AiModelAge.latest;
  if (days <= 800) return AiModelAge.previous;
  return AiModelAge.older;
}

int _daysBetween(int newer, int older) {
  DateTime date(int value) =>
      DateTime.utc(value ~/ 10000, (value ~/ 100) % 100, value % 100);
  return date(newer).difference(date(older)).inDays;
}

_ModelFacts _factsFor(AiModelInfo model) {
  final bare = _bare(model.id);
  final role = _role(model, bare);
  final explicit = _explicitDate(model, bare);
  final freshness = explicit ?? _anchorDate(bare) ?? 0;
  return _ModelFacts(
    role: role,
    freshness: freshness,
    rank: _rank(bare),
    referenceContextTokens: model.contextWindow == null
        ? _referenceContext(bare)
        : null,
    releasedLabel: explicit == null ? null : _formatDate(explicit),
    specialized: _specializedRoles.contains(role),
  );
}

String _bare(String id) {
  var bare = id.trim().toLowerCase();
  final slash = bare.lastIndexOf('/');
  if (slash >= 0) bare = bare.substring(slash + 1);
  return bare.replaceFirst(RegExp(r'^models/'), '');
}

String _formatDate(int yyyymmdd) {
  final year = yyyymmdd ~/ 10000;
  final month = ((yyyymmdd ~/ 100) % 100).toString().padLeft(2, '0');
  return '$year-$month';
}

/// A date printed by the provider or embedded in the id. Anchors are excluded
/// so the UI does not present a guess as a release month.
int? _explicitDate(AiModelInfo model, String bare) {
  final released = model.releasedAt?.toUtc();
  if (released != null) {
    return released.year * 10000 + released.month * 100 + released.day;
  }
  return _dateInText(bare);
}

int? _dateInText(String text) {
  final match = RegExp(r'(20\d{2})[-_]?(\d{2})[-_]?(\d{2})').firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return year * 10000 + month * 100 + day;
}

AiModelRole _role(AiModelInfo model, String bare) {
  final inputs = model.inputModalities
      .map((item) => item.toLowerCase())
      .toSet();
  final outputs = model.outputModalities
      .map((item) => item.toLowerCase())
      .toSet();
  bool matches(String pattern) => RegExp(pattern).hasMatch(bare);
  if (matches(r'embed') || outputs.contains('embedding')) {
    return AiModelRole.embedding;
  }
  if (matches(r're-?rank')) return AiModelRole.rerank;
  if (matches(r'moderat')) return AiModelRole.moderation;
  if (matches(
        r'dall-e|dalle|gpt-image|stable-diffusion|flux-|cogview|imagen',
      ) ||
      (outputs.contains('image') && !outputs.contains('text'))) {
    return AiModelRole.image;
  }
  if (matches(r'whisper|tts|speech|transcribe') &&
      !matches(r'gpt-|gemini-|claude-')) {
    return AiModelRole.speech;
  }
  if (matches(r'codex|coder|codestral|-code($|-)|codechat')) {
    return AiModelRole.code;
  }
  if (matches(r'reasoner|(^|[^a-z])o[134]([^a-z0-9]|$)|-r1($|-)')) {
    return AiModelRole.reasoning;
  }
  if (inputs.contains('image') ||
      inputs.contains('video') ||
      matches(r'vision|(^|[^a-z])vl([^a-z]|$)|gpt-4o|omni')) {
    return AiModelRole.vision;
  }
  return AiModelRole.chat;
}

int _rank(String bare) {
  if (RegExp(r'nano|tiny|lite|mini|haiku').hasMatch(bare)) return 1;
  if (RegExp(r'flash|small').hasMatch(bare)) return 2;
  if (RegExp(r'pro|max|opus|plus|large|ultra').hasMatch(bare)) return 4;
  return 3;
}

/// Approximate publication months for ids that ship without a timestamp.
/// Specific patterns must stay above the broader family pattern.
final List<(RegExp, int)> _anchors = [
  (RegExp(r'gpt-6\.1|gpt-6-1'), 20261001),
  (RegExp(r'gpt-6'), 20260801),
  (RegExp(r'gpt-5\.5'), 20260701),
  (RegExp(r'gpt-5\.4'), 20260301),
  (RegExp(r'gpt-5\.2'), 20251201),
  (RegExp(r'gpt-5\.1'), 20251101),
  (RegExp(r'gpt-5'), 20250801),
  (RegExp(r'(^|[^a-z])o[34]([^a-z0-9]|$)'), 20250401),
  (RegExp(r'gpt-4\.1'), 20250414),
  (RegExp(r'gpt-4o'), 20240513),
  (RegExp(r'(^|[^a-z])o1([^a-z0-9]|$)'), 20240912),
  (RegExp(r'gpt-4'), 20230613),
  (RegExp(r'gpt-3\.5|gpt-35'), 20230301),
  (RegExp(r'claude-(opus|sonnet|haiku)-4|claude-4'), 20250522),
  (RegExp(r'claude-3-7|claude-3\.7'), 20250224),
  (RegExp(r'claude-3-5|claude-3\.5'), 20240620),
  (RegExp(r'claude-3'), 20240304),
  (RegExp(r'claude-2'), 20230701),
  (RegExp(r'gemini-3'), 20260101),
  (RegExp(r'gemini-2\.5'), 20250617),
  (RegExp(r'gemini-2'), 20250201),
  (RegExp(r'gemini-1\.5'), 20240514),
  (RegExp(r'gemini-1'), 20231206),
  (RegExp(r'deepseek-v4|deepseek-flash|deepseek-reasoner'), 20260115),
  (RegExp(r'deepseek-v3'), 20241226),
  (RegExp(r'deepseek-v2'), 20240501),
  (RegExp(r'qwen3\.[6-9]|qwen3-[6-9]'), 20260401),
  (RegExp(r'qwen3'), 20250428),
  (RegExp(r'qwen2\.5|qwen2-5'), 20240919),
  (RegExp(r'qwen2'), 20240601),
  (RegExp(r'glm-5'), 20260201),
  (RegExp(r'glm-4'), 20240601),
  (RegExp(r'grok-4'), 20260101),
  (RegExp(r'grok-3'), 20250217),
  (RegExp(r'grok-2'), 20240813),
  (RegExp(r'llama-?4'), 20250405),
  (RegExp(r'llama-?3\.3'), 20241206),
  (RegExp(r'llama-?3\.1'), 20240723),
  (RegExp(r'llama-?3'), 20240418),
];

int? _anchorDate(String bare) {
  for (final (pattern, date) in _anchors) {
    if (pattern.hasMatch(bare)) return date;
  }
  return null;
}

/// Public context sizes used only as a label. Omit anything still in flux.
const Map<String, int> _knownContext = {
  'gpt-4o': 128000,
  'gpt-4o-mini': 128000,
  'gpt-4.1': 1047576,
  'gpt-4.1-mini': 1047576,
  'gpt-4.1-nano': 1047576,
  'gpt-3.5-turbo': 16385,
  'o1': 200000,
  'o1-mini': 128000,
  'o1-preview': 128000,
  'o3-mini': 200000,
  'claude-3-5-sonnet-latest': 200000,
  'claude-3-5-haiku-latest': 200000,
  'claude-3-opus-latest': 200000,
  'gemini-1.5-pro': 1048576,
  'gemini-1.5-flash': 1048576,
  'gemini-2.0-flash': 1048576,
  'gemini-2.5-pro': 1048576,
  'gemini-2.5-flash': 1048576,
};

int? _referenceContext(String bare) {
  final undated = bare.replaceFirst(RegExp(r'-\d{4}-\d{2}-\d{2}$'), '');
  return _knownContext[bare] ?? _knownContext[undated];
}
