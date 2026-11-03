import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'web_media_resource.dart';
import '../../services/app_default_settings_trial.dart';

/// One validation rule for the address bar, shortcuts and cookie queries.
Uri? parseWebMediaAddress(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  final parsed = Uri.tryParse(value);
  if (parsed == null) return null;
  final hostWithPort = RegExp(r'^[^/?#:@\s]+:\d+(?:[/?#]|$)').hasMatch(value);
  final candidate = !parsed.hasScheme || hostWithPort
      ? 'https://$value'
      : value;
  final safe = safeWebMediaUri(candidate);
  if (safe == null) return null;
  final validated = safe.path.isEmpty ? safe.replace(path: '/') : safe;
  final original = Uri.parse(candidate);
  return original.hasFragment
      ? validated.replace(fragment: original.fragment)
      : validated;
}

class WebMediaShortcut {
  const WebMediaShortcut({
    required this.id,
    required this.name,
    required this.url,
  });
  final String id;
  final String name;
  final Uri url;

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'url': url.toString(),
  };
}

class WebMediaHistoryEntry {
  const WebMediaHistoryEntry({
    required this.url,
    required this.title,
    required this.visitedAt,
  });
  final Uri url;
  final String title;
  final DateTime visitedAt;

  Map<String, Object> toJson() => {
    'url': url.toString(),
    'title': title,
    'visitedAt': visitedAt.toUtc().toIso8601String(),
  };
}

/// User shortcuts, history and display mode. Cookies stay native.
class WebMediaBrowserPreferences extends ChangeNotifier {
  static const storageKey = 'web_media_browser_home_v1';
  static const defaultDesktopMode = true;
  List<WebMediaShortcut> _shortcuts = [];

  // Older versions persisted their built-in shortcuts alongside user entries.
  // User-created entries have UUIDs; preserve them and edited legacy entries.
  static bool _isLegacyPreset(String id, String name, Uri url) =>
      (id == 'youtube' &&
          name == 'YouTube' &&
          url == Uri.parse('https://www.youtube.com/')) ||
      (id == 'bilibili' &&
          name == '哔哩哔哩' &&
          url == Uri.parse('https://www.bilibili.com/'));
  List<Uri> _sites = [];
  static const historyLimit = 300;
  List<WebMediaHistoryEntry> _history = [];
  Uri? resumePage;
  bool resumeHome = true;
  Future<void>? _loading;
  Future<void>? _writes;
  bool _disposed = false;
  bool loaded = false;
  bool desktopMode = defaultDesktopMode;
  String? error;

  List<WebMediaShortcut> get shortcuts => List.unmodifiable(_shortcuts);
  List<Uri> get sites => List.unmodifiable(_sites);
  List<WebMediaHistoryEntry> get history => List.unmodifiable(_history);

  Future<void> load() {
    DefaultTrialRuntime.bindings['browser-${identityHashCode(this)}'] =
        DefaultTrialRuntimeBinding(
          flush: () async {
            await _writes;
          },
          reload: () async {
            if (!loaded || _disposed) return;
            final prefs = await SharedPreferences.getInstance();
            final raw = jsonDecode(prefs.getString(storageKey) ?? '{}') as Map;
            desktopMode = raw['desktopMode'] is bool
                ? raw['desktopMode'] as bool
                : defaultDesktopMode;
            _notify();
          },
        );
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        final data = jsonDecode(raw);
        if (data is! Map ||
            (data['shortcuts'] != null && data['shortcuts'] is! List)) {
          throw const FormatException('Invalid browser preferences');
        }
        final shortcuts = <WebMediaShortcut>[];
        final ids = <String>{};
        final urls = <Uri>{};
        for (final entry in data['shortcuts'] as List? ?? []) {
          if (entry is! Map) continue;
          final url = entry['url'] is String
              ? parseWebMediaAddress(entry['url'])
              : null;
          final id = entry['id'];
          final name = entry['name'];
          if (url == null ||
              id is! String ||
              id.isEmpty ||
              id.length > 128 ||
              name is! String ||
              name.trim().isEmpty ||
              name.length > 80 ||
              ids.contains(id) ||
              urls.contains(url)) {
            continue;
          }
          if (_isLegacyPreset(id, name.trim(), url)) continue;
          shortcuts.add(WebMediaShortcut(id: id, name: name.trim(), url: url));
          ids.add(id);
          urls.add(url);
        }
        _shortcuts = shortcuts;
        if (data['desktopMode'] is bool) desktopMode = data['desktopMode'];
        resumePage = data['resumePage'] is String
            ? parseWebMediaAddress(data['resumePage'])
            : null;
        resumeHome = data['resumeHome'] != false;
        final historyUrls = <Uri>{};
        for (final entry
            in (data['history'] is List ? data['history'] as List : const [])) {
          if (_history.length >= historyLimit) break;
          if (entry is! Map) continue;
          final url = entry['url'] is String
              ? parseWebMediaAddress(entry['url'])
              : null;
          final date = entry['visitedAt'] is String
              ? DateTime.tryParse(entry['visitedAt'])
              : null;
          if (url == null || date == null || !historyUrls.add(url)) continue;
          final title = entry['title'] is String
              ? entry['title'] as String
              : '';
          _history.add(
            WebMediaHistoryEntry(
              url: url,
              title: title.substring(0, title.length.clamp(0, 240)),
              visitedAt: date,
            ),
          );
        }
        for (final value
            in (data['sites'] is List ? data['sites'] as List : const []).take(
              200,
            )) {
          final uri = value is String ? parseWebMediaAddress(value) : null;
          if (uri != null) {
            final origin = Uri.parse('${uri.origin}/');
            if (!_sites.contains(origin)) _sites.add(origin);
          }
        }
      }
    } catch (_) {
      error = '网站快捷入口未能读取，请重试。';
    }
    loaded = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Mutations are serialized and become visible only after a durable write.
  /// A failed save leaves the last working layout intact and can be retried.
  Future<void> _change(void Function() mutation, {bool Function()? when}) {
    final task = (_writes ?? Future<void>.value()).then((_) async {
      await load();
      if (when != null && !when()) return;
      final previous = _shortcuts;
      final previousSites = _sites;
      final previousMode = desktopMode;
      final previousHistory = _history;
      final previousPage = resumePage;
      final previousHome = resumeHome;
      _shortcuts = List.of(_shortcuts);
      _sites = List.of(_sites);
      _history = List.of(_history);
      SharedPreferences? prefs;
      try {
        mutation();
        prefs = await SharedPreferences.getInstance();
        final saved = await prefs.setString(
          storageKey,
          jsonEncode({
            'shortcuts': _shortcuts.map((item) => item.toJson()).toList(),
            'sites': _sites.map((uri) => uri.toString()).toList(),
            'desktopMode': desktopMode,
            'history': _history.map((entry) => entry.toJson()).toList(),
            'resumePage': resumePage?.toString(),
            'resumeHome': resumeHome,
          }),
        );
        if (!saved) throw StateError('Browser preferences were not saved');
        error = null;
      } catch (_) {
        _shortcuts = previous;
        _sites = previousSites;
        desktopMode = previousMode;
        _history = previousHistory;
        resumePage = previousPage;
        resumeHome = previousHome;
        // Legacy SharedPreferences updates its cache before the native write.
        // Discard that speculative value if persistence failed.
        try {
          await prefs?.reload();
        } catch (_) {}
        error = '保存未完成，请重试。';
        rethrow;
      } finally {
        _notify();
      }
    });
    _writes = task.catchError((Object _) {});
    return task;
  }

  Future<void> setDesktopMode(bool value) => _change(() => desktopMode = value);

  Future<void> saveLocation(Uri? page, {required bool showHome}) => _change(() {
    resumePage = page;
    resumeHome = showHome;
  }, when: () => resumePage != page || resumeHome != showHome);

  Future<void> recordVisit(Uri page, {String? title}) {
    if (parseWebMediaAddress(page.toString()) == null) {
      return Future.value();
    }
    return _change(() {
      final previous = _history.where((entry) => entry.url == page).firstOrNull;
      final label = title?.trim();
      _history.removeWhere((entry) => entry.url == page);
      _history.insert(
        0,
        WebMediaHistoryEntry(
          url: page,
          title: label == null || label.isEmpty
              ? previous?.title ?? page.host
              : label.substring(0, label.length.clamp(0, 240)),
          visitedAt: DateTime.now(),
        ),
      );
      if (_history.length > historyLimit) _history.removeLast();
    });
  }

  Future<void> removeHistory(Uri page) =>
      _change(() => _history.removeWhere((entry) => entry.url == page));

  Future<void> clearHistory() => _change(() => _history.clear());

  Future<void> saveShortcut({
    String? id,
    required String name,
    required Uri url,
  }) {
    final label = name.trim();
    if (label.isEmpty ||
        label.length > 80 ||
        parseWebMediaAddress(url.toString()) == null) {
      return Future.error(const FormatException('请输入名称和有效的网站地址'));
    }
    return _change(() {
      final index = id == null
          ? _shortcuts.indexWhere((item) => item.url == url)
          : _shortcuts.indexWhere((item) => item.id == id);
      if (_shortcuts.any(
        (item) =>
            item.url == url &&
            item.id != (index < 0 ? null : _shortcuts[index].id),
      )) {
        throw const FormatException('这个网址已经在首页中');
      }
      if (index < 0) {
        _shortcuts.add(
          WebMediaShortcut(id: const Uuid().v4(), name: label, url: url),
        );
      } else {
        _shortcuts[index] = WebMediaShortcut(
          id: _shortcuts[index].id,
          name: label,
          url: url,
        );
      }
    });
  }

  Future<void> removeShortcut(String id) =>
      _change(() => _shortcuts.removeWhere((item) => item.id == id));

  Future<void> moveShortcut(String id, int destination) => _change(() {
    final index = _shortcuts.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final item = _shortcuts.removeAt(index);
    _shortcuts.insert(destination.clamp(0, _shortcuts.length), item);
  });

  Future<void> rememberSite(Uri page) async {
    await load();
    final origin = Uri.parse('${page.origin}/');
    if (_sites.contains(origin)) return;
    await _change(() {
      _sites.remove(origin);
      _sites.insert(0, origin);
      if (_sites.length > 200) _sites.removeLast();
    });
  }

  @override
  void dispose() {
    DefaultTrialRuntime.bindings.remove('browser-${identityHashCode(this)}');
    _disposed = true;
    super.dispose();
  }
}
