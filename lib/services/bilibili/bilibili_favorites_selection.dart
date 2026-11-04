import 'package:flutter/foundation.dart';

import '../../models/bilibili_favorites_models.dart';
import 'bilibili_favorites_service.dart';

class BilibiliFavoritesSelection extends ChangeNotifier {
  final Map<String, BilibiliFavoriteVideo> _selected = {};
  BilibiliFavoriteContents? _contents;
  bool active = false;
  bool loading = false;
  int loaded = 0;
  int total = 0;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  List<BilibiliFavoriteVideo> get videos => _contents == null
      ? _selected.values.toList(growable: false)
      : _contents!.entries
            .where((video) => _selected.containsKey(video.key))
            .toList(growable: false);
  int get count => _selected.length;
  bool contains(BilibiliFavoriteVideo video) =>
      _selected.containsKey(video.key);
  bool get allSelected =>
      _contents != null &&
      _contents!.playable.isNotEmpty &&
      _contents!.playable.every(contains);

  void enter([BilibiliFavoriteVideo? video]) {
    active = true;
    if (video != null && video.canPlay) _selected[video.key] = video;
    notifyListeners();
  }

  void toggle(BilibiliFavoriteVideo video) {
    if (!active || loading || !video.canPlay) return;
    if (_selected.remove(video.key) == null) _selected[video.key] = video;
    notifyListeners();
  }

  Future<void> selectAll(
    BilibiliFavoritesService service,
    int mid,
    int folderId,
  ) async {
    if (!active || loading) return;
    if (allSelected) {
      _selected.clear();
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final contents =
          _contents ??
          await service.fetchAllVideos(
            mid,
            folderId,
            isCancelled: () => _disposed || generation != _generation,
            onProgress: (count, size) {
              if (_disposed || generation != _generation) return;
              loaded = count;
              total = size;
              notifyListeners();
            },
          );
      if (_disposed || generation != _generation) return;
      _contents = contents;
      _selected.clear();
      _selected.addEntries(
        contents.playable.map((video) => MapEntry(video.key, video)),
      );
    } on BilibiliFavoritesCancelled {
      // An exit or account change owns the next visible state.
    } catch (failure) {
      if (!_disposed && generation == _generation) error = failure.toString();
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void imported(Set<String> keys) {
    _selected.removeWhere((key, _) => keys.contains(key));
    if (_selected.isEmpty) {
      exit();
    } else {
      notifyListeners();
    }
  }

  void exit() {
    _generation++;
    active = false;
    loading = false;
    error = null;
    loaded = total = 0;
    _selected.clear();
    _contents = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
