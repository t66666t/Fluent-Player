import 'dart:async';

import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/settings_service.dart';

/// The remembered open / closed state of the landscape Bilibili panel.
///
/// Only a deliberate user action changes it: the panel button, its shortcut
/// or the panel's collapse button. The player not opening the panel by
/// itself, another panel shown over it for a moment and entering or leaving
/// full screen only change what is shown now.
class BilibiliPlayerPanelMemory {
  BilibiliPlayerPanelMemory({
    required bool Function() read,
    required Future<void> Function(bool open) write,
  }) : _read = read,
       _write = write;

  factory BilibiliPlayerPanelMemory.of(SettingsService settings) =>
      BilibiliPlayerPanelMemory(
        read: () => settings.bilibiliPlayerPanelOpen,
        write: settings.saveBilibiliPlayerPanelOpen,
      );

  final bool Function() _read;
  final Future<void> Function(bool open) _write;

  bool get remembered => _read();

  /// The panel button or shortcut was used while the panel was [showing]:
  /// returns whether it is open afterwards and remembers that.
  bool userToggled({required bool showing}) {
    final open = !showing;
    unawaited(_write(open));
    return open;
  }

  /// The panel's own collapse button was used.
  void userCollapsed() {
    unawaited(_write(false));
  }
}

/// The remembered tab of the portrait 「详情 | 字幕」 switch of Bilibili
/// videos (one choice for all of them; 详情 at first).
///
/// Only a tap on the switch in the player changes it. Panels shown in its
/// place for a while (subtitle manager, part list, ...) do not, and neither
/// does the switch on the loading page: what is picked there only carries
/// over to the playback page it opens ([handOff], [takeHandOff]).
class BilibiliPortraitTabMemory {
  BilibiliPortraitTabMemory({
    required bool Function() readSubtitles,
    required Future<void> Function(bool subtitles) writeSubtitles,
  }) : _read = readSubtitles,
       _write = writeSubtitles;

  factory BilibiliPortraitTabMemory.of(SettingsService settings) =>
      BilibiliPortraitTabMemory(
        readSubtitles: () => settings.bilibiliPortraitShowsSubtitles,
        writeSubtitles: settings.saveBilibiliPortraitShowsSubtitles,
      );

  final bool Function() _read;
  final Future<void> Function(bool subtitles) _write;

  PortraitBilibiliTab get remembered =>
      _read() ? PortraitBilibiliTab.subtitles : PortraitBilibiliTab.details;

  /// The switch in the player was tapped.
  void userPicked(PortraitBilibiliTab tab) {
    unawaited(_write(tab == PortraitBilibiliTab.subtitles));
  }

  static String? _handOffItemId;
  static PortraitBilibiliTab? _handOffTab;

  /// The loading page shows [tab] and opens the playback page of [itemId]:
  /// that page starts on [tab] too.
  static void handOff(String itemId, PortraitBilibiliTab tab) {
    _handOffItemId = itemId;
    _handOffTab = tab;
  }

  /// The tab handed over for [itemId], once; null when there is none.
  static PortraitBilibiliTab? takeHandOff(String itemId) {
    if (_handOffItemId != itemId) return null;
    final tab = _handOffTab;
    _handOffItemId = null;
    _handOffTab = null;
    return tab;
  }
}
