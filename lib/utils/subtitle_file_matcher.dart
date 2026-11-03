import 'package:path/path.dart' as p;

/// 字幕文件与视频文件的匹配状态等级。
///
/// 旧实现依赖用户手选"前缀匹配模式"，本质是二元匹配。新实现改为
/// 「解析 → 资格判定 → 分级评分」，其中：
///
/// - [autoMatch]   命名证据充分，允许自动加载 / 设为默认字幕；
/// - [manualOnly]  存在可解释的弱证据（如 `Movie (1).srt` 副本、
///                  `Movie 2.srt` 序号），仅允许手动挑选，绝不自动匹配；
/// - [rejected]    主体不匹配 / 年份冲突等硬性否决，视为无关字幕。
enum SubtitleMatchGrade { rejected, manualOnly, autoMatch }

/// 一个字幕文件名的解析 + 判定结果（纯函数产物，不涉及 IO）。
class SubtitleFileNameAnalysis {
  final SubtitleMatchGrade grade;

  /// 规范化语言码：`zh-Hans` / `zh-Hant` / `en` / `ja` / `ko` / `other`，
  /// 无语言标记时为 `null`。
  final String? languageCode;

  /// 语言权重：0=简体中文 1=繁体中文 2=无标记 3=英文 4=其它。
  final int languageRank;

  /// 主体 token 是否与视频主体完全一致（忽略大小写/全半角/分隔符/发布后缀）。
  final bool exactCoreMatch;

  /// 文件名开头被剥离的装饰段数量（如 `【字幕组】`、`[VCB-Studio]`）。
  final int decorationGroupCount;

  /// 名称尾部识别出的额外标记数量（语言/字幕类型标记）。
  final int trailingTagCount;

  /// 是否带副本/重复/序号等弱证据标记（`(1)`、`副本`、`Part 2`…）。
  final bool hasNoiseSuffix;

  const SubtitleFileNameAnalysis({
    required this.grade,
    this.languageCode,
    this.languageRank = 2,
    this.exactCoreMatch = false,
    this.decorationGroupCount = 0,
    this.trailingTagCount = 0,
    this.hasNoiseSuffix = false,
  });

  bool get isAuto => grade == SubtitleMatchGrade.autoMatch;
  bool get isManual => grade == SubtitleMatchGrade.manualOnly;
  bool get isRejected => grade == SubtitleMatchGrade.rejected;
}

class SubtitleFileMatcher {
  const SubtitleFileMatcher();

  /// 支持扫描/参与匹配的字幕扩展名（沿用旧实现白名单）。
  static const Set<String> supportedExtensions = <String>{
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
    '.sup',
    '.lrc',
    '.alrc', '.elrc', '.spl', '.ttml', '.dfxp', '.xml',
    '.yrc', '.qrc', '.krc', '.lys', '.lyl', '.json',
    '.sub',
    '.idx',
    '.scc',
  };

  /// 语言标记表：尾部语言 token → (规范化语言码, 权重)。
  ///
  /// 权重按用户确认的顺序：中文(简) > 中文(繁) > 无标记 > 英文 > 其它。
  static const Map<String, (String, int)> languageTags = <String, (String, int)>{
    // 简体中文
    'zh': ('zh-Hans', 0),
    'zho': ('zh-Hans', 0),
    'chi': ('zh-Hans', 0),
    'zh-hans': ('zh-Hans', 0),
    'zh-cn': ('zh-Hans', 0),
    'chs': ('zh-Hans', 0),
    'sc': ('zh-Hans', 0),
    'cn': ('zh-Hans', 0),
    'simplified': ('zh-Hans', 0),
    '简': ('zh-Hans', 0),
    '简体': ('zh-Hans', 0),
    '简体中文': ('zh-Hans', 0),
    '简中': ('zh-Hans', 0),
    '中文': ('zh-Hans', 0),
    '中': ('zh-Hans', 0),
    '中字': ('zh-Hans', 0),
    '汉': ('zh-Hans', 0),
    '国语': ('zh-Hans', 0),
    'chinese': ('zh-Hans', 0),
    // 繁体中文
    'zh-hant': ('zh-Hant', 1),
    'zh-tw': ('zh-Hant', 1),
    'zh-hk': ('zh-Hant', 1),
    'cht': ('zh-Hant', 1),
    'tc': ('zh-Hant', 1),
    'big5': ('zh-Hant', 1),
    'trad': ('zh-Hant', 1),
    'traditional': ('zh-Hant', 1),
    '繁': ('zh-Hant', 1),
    '繁體': ('zh-Hant', 1),
    '繁体': ('zh-Hant', 1),
    '繁中': ('zh-Hant', 1),
    '繁體中文': ('zh-Hant', 1),
    // 英文
    'en': ('en', 3),
    'eng': ('en', 3),
    'en-us': ('en', 3),
    'en-gb': ('en', 3),
    'en-au': ('en', 3),
    'english': ('en', 3),
    '英': ('en', 3),
    '英文': ('en', 3),
    '英語': ('en', 3),
    '英语': ('en', 3),
    // 日文
    'ja': ('ja', 4),
    'jp': ('ja', 4),
    'jpn': ('ja', 4),
    'japanese': ('ja', 4),
    '日': ('ja', 4),
    '日文': ('ja', 4),
    '日语': ('ja', 4),
    '日本語': ('ja', 4),
    // 韩文
    'ko': ('ko', 4),
    'kor': ('ko', 4),
    'korean': ('ko', 4),
    '韩': ('ko', 4),
    '韓': ('ko', 4),
    '韩文': ('ko', 4),
    '韩语': ('ko', 4),
    '韓語': ('ko', 4),
    '朝鲜语': ('ko', 4),
    // 其它常见语种
    'fr': ('other', 4),
    'fra': ('other', 4),
    'de': ('other', 4),
    'ger': ('other', 4),
    'es': ('other', 4),
    'spa': ('other', 4),
    'it': ('other', 4),
    'ita': ('other', 4),
    'pt': ('other', 4),
    'ru': ('other', 4),
    'rus': ('other', 4),
    'ar': ('other', 4),
    'tr': ('other', 4),
    'th': ('other', 4),
    'vi': ('other', 4),
    'id': ('other', 4),
    'pl': ('other', 4),
    'nl': ('other', 4),
    'sv': ('other', 4),
  };

  /// 音乐歌词文件里常把源媒体文件名整体嵌入（如 `Song.m4a.lrc`、
  /// `02. 02. Champion.m4a.lrc`），其中的媒体容器 token 是纯导出噪音。
  static const Set<String> containerNoiseTokens = <String>{
    'm4a', 'mp4', 'mkv', 'mov', 'avi', 'webm', 'ts', 'm2ts',
    'mp3', 'flac', 'wav', 'aac', 'ogg', 'opus', 'wma', 'mka',
    'ape', 'wv', 'alac', 'ac3', 'm4v', 'aiff', 'dsf', 'dff',
  };

  /// 多字符罗马数字（作为编号语义时不得被当作标签剥离/放行）。
  static const Set<String> multiCharRomanNumerals = <String>{
    'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x', 'xi',
    'xii', 'xiii', 'xiv', 'xv', 'xvi', 'xvii', 'xviii', 'xix', 'xx',
  };

  static final RegExp _pureNumberToken = RegExp(r'^\d+$');

  /// 字幕类型标记（与语言同处尾部，表示"用于听障/强制"等）。
  static const Set<String> subtitleFlagTags = <String>{
    'forced',
    'foreign',
    'sdh',
    'hi',
    'hearing-impaired',
    'cc',
    'captions',
    'full',
    'normal',
    'default',
    'signs',
    'songs',
    '双语',
    'lyrics',
  };

  /// 发布/画质/编码等"非身份" token（常见于场景文件命名尾部）。
  /// 这些 token 允许出现在视频名中而字幕名缺失，反之亦然。
  static final RegExp releaseToken = RegExp(
    r'^(?:\d{3,4}p|8k|4k|uhd|hdr10\+?|hdr|dolbyvision|dv|'
    r'blu-?ray|bdr?ip|brrip|web-?dl|webrip|hdtv(?:rip)?|dvd(?:rip)?|'
    r'bdremux|remux|hmax|amzn|itunes|nfrip|webtv|tvrip|ppvrip|'
    r'h26[45]|x26[45]|hevc|avc|av1|vp[0-9]|'
    r'aac|ac3|eac3|dts(?:-hd(?:-ma)?)?|truehd|atmos|flac|lpcm|pcm|mp3|ddp?[0-9.]*|'
    r'(?:10|8|12)bit|\d+(?:\.\d+)?fps|hq|preair|proper|repack|extended|theatrical)$',
  );

  static final RegExp _yearToken = RegExp(r'^(?:19|20)\d{2}$');

  static final RegExp _tokenChar = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
  static final RegExp _sepOnly = RegExp(r'^[\s._\-·~]+$');

  /// 便捷入口：视频主名 + 字幕主名 → 判定结果。
  static SubtitleFileNameAnalysis analyzeStems({
    required String videoStem,
    required String subtitleStem,
  }) {
    // 特例：B 站分 P 轨道字幕（video.stream_N.srt）走独立关联，直接否决。
    if (_isStreamTrackPair(videoStem, subtitleStem)) {
      return const SubtitleFileNameAnalysis(grade: SubtitleMatchGrade.rejected);
    }

    // 先剥掉末尾的短标签（如 `01. Good Morning [L]` 里的 [L]）。
    final videoPre = _stripTrailingShortTags(videoStem);
    final subPre = _stripTrailingShortTags(subtitleStem);
    // 再剥离开头括号装饰段（【字幕组】等）。
    final (videoDecor, videoCoreText) = _stripLeadingDecorations(videoPre);
    final (subDecor, subCoreText) = _stripLeadingDecorations(subPre);

    final videoTokens = _tokenize(videoCoreText);
    final subTokens = _tokenize(subCoreText);

    // 主体完全为空（整名都写在括号里，如 [REC].mkv）：整名一致才算匹配。
    if (videoTokens.isEmpty || subTokens.isEmpty) {
      final wholeVideo = _canonical(_tokenize(videoDecor));
      final wholeSub = _canonical(_tokenize(subDecor));
      if (wholeSub.isNotEmpty && wholeSub == wholeVideo) {
        return const SubtitleFileNameAnalysis(
          grade: SubtitleMatchGrade.autoMatch,
          exactCoreMatch: true,
          decorationGroupCount: 1,
        );
      }
      return const SubtitleFileNameAnalysis(grade: SubtitleMatchGrade.rejected);
    }

    return _classify(
      videoTokens: videoTokens,
      videoDecorTokens: _tokenize(videoDecor),
      subTokens: subTokens,
      subDecorTokens: _tokenize(subDecor),
    );
  }

  static SubtitleFileNameAnalysis _classify({
    required List<String> videoTokens,
    required List<String> videoDecorTokens,
    required List<String> subTokens,
    required List<String> subDecorTokens,
  }) {
    final decorationGroups =
        videoDecorTokens.isNotEmpty || subDecorTokens.isNotEmpty ? 1 : 0;

    // ---- 语言与字幕类型标记：仅允许在字幕名【尾部】被剥离 ----
    String? languageCode;
    var languageRank = 2;
    var trailingTagCount = 0;
    var core = List<String>.of(subTokens);
    while (core.isNotEmpty) {
      final tail = core.last;
      final tag = languageTags[tail];
      if (tag != null) {
        if (languageCode == null) {
          languageCode = tag.$1;
          languageRank = tag.$2;
        }
        trailingTagCount++;
        core.removeLast();
        continue;
      }
      if (subtitleFlagTags.contains(tail)) {
        trailingTagCount++;
        core.removeLast();
        continue;
      }
      break;
    }

    // ---- 视频侧：拆出年份与身份 token ----
    final (vYears, videoKeep) = _splitIdentityTokens(videoTokens);
    // ---- 字幕侧：同样拆出年份（供一致性比对）----
    final (sYears, subKeep) = _splitIdentityTokens(core);

    // 年份规则：
    // 1) 两侧都带年份：必须完全一致（防 Movie.2024 误配 Movie.1977）；
    // 2) 视频带年份而字幕省略年份：允许（Movie.srt 可匹配
    //    Movie.2024.1080p...）；
    // 3) 视频无年份而字幕自带年份：属于另一版本的证据，硬性否决
    //    （防 StarWars 误配 StarWars.1977 这类续作/老版本字幕）。
    if (sYears.isNotEmpty) {
      if (vYears.isEmpty || !_sameMultiset(vYears, sYears)) {
        return SubtitleFileNameAnalysis(
          grade: SubtitleMatchGrade.rejected,
          languageCode: languageCode,
          languageRank: languageRank,
          trailingTagCount: trailingTagCount,
        );
      }
    }

    // 主体一致（含"编号集合一致 + 主干词一致"的结构化容错）→ 自动匹配。
    if (_coreIdentical(subKeep, videoKeep)) {
      return SubtitleFileNameAnalysis(
        grade: SubtitleMatchGrade.autoMatch,
        languageCode: languageCode,
        languageRank: languageRank,
        exactCoreMatch: true,
        decorationGroupCount: decorationGroups,
        trailingTagCount: trailingTagCount,
      );
    }

    // 主体不一致：检查字幕多出的部分是否全部属于"弱证据"（副本/序号）。
    if (_weakEvidence(subKeep, videoKeep)) {
      return SubtitleFileNameAnalysis(
        grade: SubtitleMatchGrade.manualOnly,
        languageCode: languageCode,
        languageRank: languageRank,
        decorationGroupCount: decorationGroups,
        trailingTagCount: trailingTagCount,
        hasNoiseSuffix: true,
      );
    }

    // 进一步兜底：主体"高度相似"（仅残留少量小噪音 token，例如
    // `01. Good Morning [L].m4a` 与 `01. 01. Good Morning.m4a.lrc` 的
    // 重复序号 / 源容器扩展名 / 单字母标记）→ 仅允许手动挑选，绝不自动。
    if (_nearSimilarManual(subKeep, videoKeep)) {
      return SubtitleFileNameAnalysis(
        grade: SubtitleMatchGrade.manualOnly,
        languageCode: languageCode,
        languageRank: languageRank,
        decorationGroupCount: decorationGroups,
        trailingTagCount: trailingTagCount,
        hasNoiseSuffix: true,
      );
    }

    return SubtitleFileNameAnalysis(
      grade: SubtitleMatchGrade.rejected,
      languageCode: languageCode,
      languageRank: languageRank,
      trailingTagCount: trailingTagCount,
    );
  }

  /// 拆分 token 为 (年份列表, 身份 token 列表)。
  ///
  /// 身份 token 之外的发布 token（分辨率/编码/音轨等）会被剔除：这样
  /// `Movie.srt` 能匹配 `Movie.2024.1080p.BluRay.x264-GRP.mkv`。
  static (List<String>, List<String>) _splitIdentityTokens(
    List<String> tokens,
  ) {
    final years = <String>[];
    final keep = <String>[];
    var inReleaseRun = false;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i].toLowerCase();
      if (_yearToken.hasMatch(token)) {
        years.add(token);
        inReleaseRun = true;
        continue;
      }
      if (releaseToken.hasMatch(token)) {
        inReleaseRun = true;
        continue;
      }
      // 紧跟发布 token 的纯数字（如 `5.1` 的 `1`）属于音轨信息。
      if (inReleaseRun && RegExp(r'^\d{1,2}$').hasMatch(token)) {
        continue;
      }
      // 场景发布组（`x264-GRP` 的组名）仅在最后一个发布 token 之后。
      if (inReleaseRun && _isSceneGroupTail(tokens, i, token)) {
        continue;
      }
      keep.add(token);
      inReleaseRun = false;
    }
    return (years, keep);
  }

  static bool _isSceneGroupTail(List<String> tokens, int index, String token) {
    if (index != tokens.length - 1) return false;
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,15}$').hasMatch(token)) return false;
    final prev = tokens[index - 1].toLowerCase();
    return _yearToken.hasMatch(prev) || releaseToken.hasMatch(prev);
  }

  /// 主体不一致但字幕恰好多出"副本/序号"弱证据时返回 true（Manual 级）。
  static bool _weakEvidence(List<String> subKeep, List<String> videoKeep) {
    if (subKeep.length <= videoKeep.length) return false;
    if (!_tokenPrefixEquals(subKeep, videoKeep)) return false;
    final extra = subKeep.sublist(videoKeep.length);
    const duplicateWords = <String>{
      'copy', 'duplicate', 'dup', 'backup', 'original', 'download',
      'downloaded', '副本', '备份', 'orig',
    };
    const partWords = <String>{'part', 'cd', 'disc', 'disk', 'vol', 'pt'};
    const roman = <String>{
      'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x', 'xi',
      'xii', 'xiii', 'xiv', 'xv', 'xvi', 'xvii', 'xviii', 'xix', 'xx',
    };
    var i = 0;
    while (i < extra.length) {
      final token = extra[i].toLowerCase();
      if (duplicateWords.contains(token) ||
          RegExp(r'^\d{1,2}$').hasMatch(token)) {
        i++;
        continue;
      }
      if (partWords.contains(token) &&
          i + 1 < extra.length &&
          RegExp(r'^\d{1,2}$').hasMatch(extra[i + 1])) {
        i += 2;
        continue;
      }
      if (roman.contains(token)) {
        i++;
        continue;
      }
      return false;
    }
    return true;
  }

  /// 对称相似兜底（仅用于升级为 manual，绝不自动）：
  ///
  /// 忽略纯数字 token 后，若两侧存在公共主干 token，且双方剩余未匹配的
  /// "噪音 token" 都是短片段（长度 ≤ 4、总量 ≤ 3），则认为名称高度相似。
  /// 覆盖 `Movie [L]` 配 `01. 01. Movie.m4a.lrc`、`Episode 02` 配
  /// `Episode 02 (2).srt` 这类"看着像同一部，但命名被工具污染"的情况。
  static bool _nearSimilarManual(List<String> subKeep, List<String> videoKeep) {
    List<String> clean(Iterable<String> tokens) => tokens
        .map(_canonicalToken)
        .where((token) => !RegExp(r'^\d+$').hasMatch(token))
        .toList();

    final a = clean(subKeep);
    final b = clean(videoKeep);
    if (a.isEmpty || b.isEmpty) return false;

    // 数值 token（曲目号/集号等）要求两侧有交集，否则视为不同作品
    // （Episode 01 与 Episode 010 的编号互斥，不构成"相似"）。
    final numericA = subKeep
        .map(_canonicalToken)
        .where((token) => RegExp(r'^\d+$').hasMatch(token))
        .toSet();
    final numericB = videoKeep
        .map(_canonicalToken)
        .where((token) => RegExp(r'^\d+$').hasMatch(token))
        .toSet();
    if (numericA.isNotEmpty || numericB.isNotEmpty) {
      if (numericA.intersection(numericB).isEmpty) return false;
    }

    final counts = <String, int>{};
    for (final token in b) {
      counts[token] = (counts[token] ?? 0) + 1;
    }
    final aLeftover = <String>[];
    var common = 0;
    for (final token in a) {
      final left = counts[token];
      if (left != null && left > 0) {
        counts[token] = left - 1;
        common++;
      } else {
        aLeftover.add(token);
      }
    }
    if (common == 0) return false;

    final bLeftover = <String>[];
    counts.forEach((token, left) {
      if (left > 0) bLeftover.addAll(List.filled(left, token));
    });

    if (aLeftover.length + bLeftover.length > 3) return false;
    for (final token in aLeftover) {
      if (token.length > 4) return false;
    }
    for (final token in bLeftover) {
      if (token.length > 4) return false;
    }
    return true;
  }

  static bool _tokenPrefixEquals(List<String> list, List<String> prefix) {
    if (prefix.length > list.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (_canonicalToken(list[i]) != _canonicalToken(prefix[i])) return false;
    }
    return true;
  }

  static bool _sameMultiset(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final counts = <String, int>{};
    for (final token in a) {
      counts[token] = (counts[token] ?? 0) + 1;
    }
    for (final token in b) {
      final left = counts[token];
      if (left == null || left <= 0) return false;
      counts[token] = left - 1;
    }
    return true;
  }

  /// 结构化容错的主体一致性判定（音乐专辑/剧集常见命名污染场景）：
  ///
  /// 1. 纯数字 token（曲目号/分P 号等）改为"集合相等"比较——字幕里重复的
  ///    曲目号（如 `02. 02. Champion.m4a.lrc` 双写 02）被容忍；
  /// 2. 两侧移除"媒体容器噪音"（m4a/flac/mp3…）后，主干词序列必须逐字一致。
  ///
  /// 这样 `01. Good Morning [L].m4a` 能与 `01. 01. Good Morning.m4a.lrc`
  /// 自动配对；但编号集合不同（01 vs 02）或标题词不同（Good Morning vs
  /// Champion）的两条永远无法配对，杜绝错配。
  static bool _coreIdentical(List<String> subKeep, List<String> videoKeep) {
    final subNorm = subKeep.map(_canonicalToken).toList();
    final videoNorm = videoKeep.map(_canonicalToken).toList();

    final subNumbers = subNorm.where(_pureNumberToken.hasMatch).toSet();
    final videoNumbers = videoNorm.where(_pureNumberToken.hasMatch).toSet();
    if (!_sameSet(subNumbers, videoNumbers)) return false;

    final subWords = subNorm
        .where((t) => !_pureNumberToken.hasMatch(t) && !containerNoiseTokens.contains(t))
        .join();
    final videoWords = videoNorm
        .where((t) => !_pureNumberToken.hasMatch(t) && !containerNoiseTokens.contains(t))
        .join();
    if (subWords.isEmpty || videoWords.isEmpty) return false;
    return subWords == videoWords;
  }

  static bool _sameSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  // ---- B 站分 P 轨道排除（沿用旧语义：视频本身不是 stream 文件才生效）----
  static bool _isStreamTrackPair(String videoStem, String subtitleStem) {
    final videoLower = videoStem.toLowerCase();
    final subLower = subtitleStem.toLowerCase();
    if (videoLower.contains('stream_')) return false;
    return subLower.startsWith('$videoLower.stream_');
  }

  /// 剥掉末尾的"短标签"括号组（如 `[L]`、`[HD]`、`[LIVE]`），用于处理
  /// 音乐等场景里媒体名被工具追加了不构成身份信息的标签。
  ///
  /// 安全约束（防止误剥正文）：
  /// - 标签内部必须是恰好 1 个 token、纯小写字母、长度 1–4；
  /// - 不能是语言码或字幕类型标记（留给尾部语言逻辑处理，保留双语排序）；
  /// - 不能是多字符罗马数字（`[II]`/`[IV]` 不剥，防续集误配）；
  /// - 剥离后主干仍需有词（整名写在括号里的 `[REC]` 不剥）。
  static String _stripTrailingShortTags(String stem) {
    var end = stem.length;
    while (end > 0) {
      final closeChar = stem[end - 1];
      final openChar = _bracketOpeningFor(closeChar);
      if (openChar == null) break;
      final openIndex = stem.lastIndexOf(openChar, end - 2);
      if (openIndex < 0) break;
      final interior = stem.substring(openIndex + 1, end - 1).trim();
      final interiorTokens = _tokenize(interior);
      if (interiorTokens.length != 1) break;
      final tag = interiorTokens.single;
      if (languageTags.containsKey(tag) || subtitleFlagTags.contains(tag)) {
        break;
      }
      if (multiCharRomanNumerals.contains(tag)) break;
      if (!RegExp(r'^[a-z]{1,4}$').hasMatch(tag)) break;
      final remainder = stem.substring(0, openIndex);
      if (_tokenize(remainder).isEmpty) break;
      end = openIndex;
      while (end > 0 && _sepOnly.hasMatch(stem[end - 1])) {
        end--;
      }
    }
    if (end == stem.length) return stem;
    return stem.substring(0, end);
  }

  static String? _bracketOpeningFor(String ch) {
    switch (ch) {
      case ']':
        return '[';
      case ')':
        return '(';
      case '】':
        return '【';
      case '）':
        return '（';
      case '」':
        return '「';
      case '』':
        return '『';
      case '］':
        return '［';
      default:
        return null;
    }
  }

  /// 剥离开头的成对括号装饰段，返回 (装饰段原始文本, 剩余主干文本)。
  ///
  /// 支持 `[...]`、`(...)`、`【…】`、`（…）`、`「…」`、`『…』`、`［…］`；
  /// 多个装饰段与主体之间的空格/点/下划线会被一并吞掉。
  static (String, String) _stripLeadingDecorations(String stem) {
    var index = 0;
    var decor = '';
    while (index < stem.length) {
      final closing = _bracketClosing(stem[index]);
      if (closing == null) break;
      final closeIndex = stem.indexOf(closing, index + 1);
      if (closeIndex < 0) break;
      decor += stem.substring(index, closeIndex + 1);
      index = closeIndex + 1;
      // 允许连续装饰段：[A][B] Name.srt
      continue;
    }
    if (decor.isEmpty) return ('', stem);
    while (index < stem.length && _sepOnly.hasMatch(stem[index])) {
      index++;
    }
    return (decor, stem.substring(index));
  }

  static String? _bracketClosing(String ch) {
    switch (ch) {
      case '[':
        return ']';
      case '(':
        return ')';
      case '【':
        return '】';
      case '（':
        return '）';
      case '「':
        return '」';
      case '『':
        return '』';
      case '［':
        return '］';
      default:
        return null;
    }
  }

  /// 把字符串切成 token 序列。token = 连续字母/数字（含 CJK），`-` 作为
  /// 内部连接符（`zh-hans` 保持一个 token）；`.` `_` 空格与括号等为分隔符。
  static List<String> _tokenize(String input) {
    final normalized = _halfWidth(input);
    final tokens = <String>[];
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString().toLowerCase());
        buffer.clear();
      }
    }

    for (final rune in normalized.runes) {
      final ch = String.fromCharCode(rune);
      if (_tokenChar.hasMatch(ch) || ch == '-') {
        buffer.write(ch);
      } else {
        flush();
      }
    }
    flush();
    // 孤立/纯连字符段（如 "Movie - 副本" 中的 "-"）不产生身份 token。
    return tokens.where((token) => _canonicalToken(token).isNotEmpty).toList();
  }

  /// 全角 → 半角（覆盖 ASCII 区与常见全角标点）。
  static String _halfWidth(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0x3000) {
        buffer.write(' ');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static String _canonical(List<String> tokens) =>
      tokens.map(_canonicalToken).join();

  static String _canonicalToken(String token) =>
      token.toLowerCase().replaceAll('-', '');

  /// 供展示使用：把规范化语言码翻译成人话。
  static String? languageDisplayName(String? code) {
    switch (code) {
      case 'zh-Hans':
        return '简体中文';
      case 'zh-Hant':
        return '繁体中文';
      case 'en':
        return '英文';
      case 'ja':
        return '日文';
      case 'ko':
        return '韩文';
      case 'other':
        return '其它语言';
      default:
        return null;
    }
  }

  static String languageRankDisplay(int rank) => switch (rank) {
        0 => '简体中文',
        1 => '繁体中文',
        2 => '无语言标记',
        3 => '英文',
        _ => '其它语言',
      };
}

/// 根据文件名主干的相对路径片段完成一次匹配（供发现服务使用）。
SubtitleFileNameAnalysis matchSubtitleFile({
  required String videoPath,
  required String subtitlePath,
}) {
  return SubtitleFileMatcher.analyzeStems(
    videoStem: p.basenameWithoutExtension(videoPath),
    subtitleStem: p.basenameWithoutExtension(subtitlePath),
  );
}
