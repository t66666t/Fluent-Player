import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'subtitle_release_info.dart';
import 'subtitle_search_models.dart';

/// Parse the site's published cards. Detail URLs and catalog IDs come from
/// their own links; download hosts are resolved separately at download time.
SubtitleSearchPage parseSubhdPage((String, SubtitleSearchQuery) input) {
  final (body, query) = input;
  final document = html.parse(body);
  final hits = <String, SubtitleSearchHit>{};
  for (final anchor in document.querySelectorAll('a[href]')) {
    final path = anchor.attributes['href'] ?? '';
    final id = RegExp(r'^/a/([A-Za-z0-9_-]+)$').firstMatch(path)?[1];
    if (id == null) continue;
    Element? card = anchor;
    while (card != null && !card.classes.contains('row')) {
      card = card.parent;
    }
    if (card == null) continue;
    final release = _firstText([
      card.querySelector('.view-text a[href^="/a/"]')?.text,
      ...card.querySelectorAll('a[href^="/a/"]').map((e) => e.text),
    ]);
    final workLink = card
        .querySelectorAll('a[href^="/d/"]')
        .where((e) => e.text.trim().isNotEmpty)
        .firstOrNull;
    final linkedId = RegExp(
      r'^/d/(\d+)',
    ).firstMatch(workLink?.attributes['href'] ?? '')?[1];
    final workTitle = workLink?.text.trim() ?? '';
    // An empty poster link must not become the title, and the search filter
    // must not be stored as if the result itself confirmed that work.
    final title = _firstText([workTitle, release, anchor.text, '字幕 $id'])!;
    final queryId = query.work?.id;
    final evidence = linkedId == null
        ? SubtitleCatalogEvidence.unknown
        : queryId != null && queryId.isNotEmpty && queryId != linkedId
        ? SubtitleCatalogEvidence.conflict
        : SubtitleCatalogEvidence.linked;
    final tags = card
        .querySelectorAll('span')
        .map((e) => e.text.trim())
        .toSet();
    const languages = {'双语', '简体', '繁体', '英语', '日语', '韩语', '法语', '西班牙语'};
    final language = tags.where(languages.contains).join(' / ');
    const formats = {'SRT', 'ASS', 'SSA', 'VTT', 'SUP', 'PGS', 'IDX', 'SUB'};
    final fileFormats = tags
        .map((t) => t.toUpperCase())
        .where(formats.contains)
        .toSet();
    // Image-only releases cannot be previewed/imported by the text renderer.
    if (fileFormats.isNotEmpty &&
        !fileFormats.any({'SRT', 'ASS', 'SSA', 'VTT'}.contains)) {
      continue;
    }
    final parsedRelease = SubtitleReleaseInfo.parse(release ?? title);
    final asked = query.season != null || query.episode != null;
    final incomplete =
        asked &&
        parsedRelease.season == null &&
        parsedRelease.episode == null &&
        !parsedRelease.pack &&
        !parsedRelease.special;
    final hit = SubtitleSearchHit(
      source: SubtitleSearchSource.subhd,
      id: id,
      title: title,
      workTitle: workTitle,
      release: release ?? '',
      language: language,
      format: fileFormats.join(' / '),
      catalogId: linkedId,
      queryCatalogId: queryId,
      catalogEvidence: evidence,
      qualification: incomplete
          ? SubtitleQualification.incomplete
          : SubtitleQualification.confirmed,
      mediaType: query.work?.type ?? '',
      websiteUrl: 'https://subhd.tv/a/$id',
    );
    if (hit.releaseInfo.accepts(query.season, query.episode) &&
        subtitleMatchesLanguage(language, query.language)) {
      hits[id] = hit;
    }
  }
  final hasMore = document.querySelectorAll('.pagination a[href]').any((a) {
    final page = int.tryParse((a.attributes['href'] ?? '').split('/').last);
    return page != null && page > query.page;
  });
  return SubtitleSearchPage(hits.values.toList(), hasMore: hasMore);
}

String? _firstText(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return null;
}

List<String> parseSubhdEntries(String body) => html
    .parse(body)
    .querySelectorAll('.subtitle-file-name[data-filename]')
    .map((e) => e.attributes['data-filename'] ?? '')
    .where(
      (n) => RegExp(r'\.(srt|ass|ssa|vtt)$', caseSensitive: false).hasMatch(n),
    )
    .toSet()
    .toList();

bool subtitleMatchesLanguage(String label, String code) {
  if (label.trim().isEmpty || code.isEmpty) return true;
  final value = label.toLowerCase();
  if ({'默认', 'unknown', 'und'}.contains(value)) return true;
  return switch (code) {
    'zh-cn' =>
      {'sc', 'chs', 'zh-cn', '简体&英语', '中文'}.contains(value) ||
          value.contains('简') ||
          value.contains('chs') ||
          value.contains('chinese') ||
          value.contains('scjp') ||
          value == 'zh',
    'zh-tw' =>
      {'tc', 'cht', 'zh-tw'}.contains(value) ||
          value.contains('繁') ||
          value.contains('cht') ||
          value.contains('traditional') ||
          value.contains('tcjp'),
    'en' => value.contains('英') || value.contains('eng') || value == 'en',
    'ja' =>
      value.contains('日') ||
          value.contains('jap') ||
          value == 'ja' ||
          value == 'jp' ||
          value.contains('scjp') ||
          value.contains('tcjp'),
    _ => true,
  };
}
