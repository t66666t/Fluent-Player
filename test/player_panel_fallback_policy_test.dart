import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart'
    show PortraitPanel;
import 'package:video_player_app/screens/video_player_screen.dart'
    show SidebarType;
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';

// The fallback rules of both player pages, pinned before they move into one
// function. Each "page today" helper below is the expression the page uses
// at that place; the policy, mapped onto the page's panels, must give the
// same panel for every input of a non-Bilibili video.

const _bools = <bool>[false, true];

/// Landscape: a target mapped onto the page's panels.
SidebarType _landscapePanel(
  LandscapeSidebarTarget target,
  SidebarType previous,
) {
  switch (target) {
    case LandscapeSidebarTarget.previous:
      return previous;
    case LandscapeSidebarTarget.subtitles:
      return SidebarType.subtitles;
    case LandscapeSidebarTarget.videoCompose:
      return SidebarType.videoCompose;
    case LandscapeSidebarTarget.none:
      return SidebarType.none;
    case LandscapeSidebarTarget.bilibili:
      fail('a non-Bilibili video never gets the Bilibili panel');
  }
}

/// Portrait: a target mapped onto the page's panels.
PortraitPanel _portraitPanel(PortraitPanelTarget target) {
  switch (target) {
    case PortraitPanelTarget.subtitles:
      return PortraitPanel.subtitles;
    case PortraitPanelTarget.videoCompose:
      return PortraitPanel.videoCompose;
    case PortraitPanelTarget.bilibili:
      fail('a non-Bilibili video never gets the Bilibili panel');
  }
}

/// Page today: "previous panel, else the subtitle list when it was left
/// open, else nothing".
SidebarType _todayPreviousOrRemembered(SidebarType previous, bool visible) {
  return previous != SidebarType.none
      ? previous
      : (visible ? SidebarType.subtitles : SidebarType.none);
}

/// Inputs a non-Bilibili video may come with: whatever the Bilibili panel
/// memory and the auto-open rule say, they must not matter.
Iterable<({bool bilibiliRemembered, bool allowAutoOpen})>
_bilibiliNoise() sync* {
  for (final remembered in _bools) {
    for (final allow in _bools) {
      yield (bilibiliRemembered: remembered, allowAutoOpen: allow);
    }
  }
}

void main() {
  group('landscape fallbacks, non-Bilibili video', () {
    SidebarType afterClose(
      LandscapeSidebarClosing closing,
      SidebarType previous,
      bool visible, {
      bool bilibiliRemembered = false,
      bool allowAutoOpen = true,
    }) {
      return _landscapePanel(
        landscapeSidebarAfterClose(
          closing: closing,
          hasPrevious: previous != SidebarType.none,
          subtitleSidebarRemembered: visible,
          isBilibiliVideo: false,
          bilibiliPanelRemembered: bilibiliRemembered,
          allowAutoOpen: allowAutoOpen,
        ),
        previous,
      );
    }

    SidebarType defaultPanel(
      bool visible, {
      bool bilibiliRemembered = false,
      bool allowAutoOpen = true,
    }) {
      return _landscapePanel(
        landscapeDefaultSidebar(
          subtitleSidebarRemembered: visible,
          isBilibiliVideo: false,
          bilibiliPanelRemembered: bilibiliRemembered,
          allowAutoOpen: allowAutoOpen,
        ),
        SidebarType.none,
      );
    }

    test('entering the player (initState)', () {
      for (final visible in _bools) {
        for (final noise in _bilibiliNoise()) {
          final today = visible ? SidebarType.subtitles : SidebarType.none;
          expect(
            defaultPanel(
              visible,
              bilibiliRemembered: noise.bilibiliRemembered,
              allowAutoOpen: noise.allowAutoOpen,
            ),
            today,
            reason: 'visible=$visible $noise',
          );
        }
      }
    });

    test('panel kept to come back to (_normalizedSidebarForRestore)', () {
      SidebarType today(SidebarType sidebar, bool visible) {
        if (sidebar == SidebarType.subtitlePosition) {
          return visible ? SidebarType.subtitles : SidebarType.none;
        }
        return sidebar;
      }

      SidebarType policy(SidebarType sidebar, bool visible) {
        if (sidebar == SidebarType.subtitlePosition) {
          return defaultPanel(visible);
        }
        return sidebar;
      }

      for (final sidebar in SidebarType.values) {
        for (final visible in _bools) {
          expect(
            policy(sidebar, visible),
            today(sidebar, visible),
            reason: '$sidebar visible=$visible',
          );
        }
      }
    });

    // Every place that closes a tool panel with "previous, else remembered
    // subtitle list, else nothing".
    const toolPanelSites = <String>[
      'subtitle position / drag mode exits (_exitSubtitleDragMode)',
      'style button pressed again (_toggleFloatingSubtitleSettingsSidebar)',
      'back key on any other panel than the subtitle list',
      'chapter button pressed again (_toggleChapterSidebar)',
      'subtitle style panel: close',
      'subtitle style panel: back',
      'subtitle editor: close',
      'settings panel: close',
      'subtitle manager: close',
      'AI transcription: back',
      'video compose: back',
      'OCR subtitles: back',
    ];
    for (final site in toolPanelSites) {
      test(site, () {
        for (final previous in SidebarType.values) {
          for (final visible in _bools) {
            for (final noise in _bilibiliNoise()) {
              expect(
                afterClose(
                  LandscapeSidebarClosing.toolPanel,
                  previous,
                  visible,
                  bilibiliRemembered: noise.bilibiliRemembered,
                  allowAutoOpen: noise.allowAutoOpen,
                ),
                _todayPreviousOrRemembered(previous, visible),
                reason: 'previous=$previous visible=$visible $noise',
              );
            }
          }
        }
      });
    }

    test('back key on the subtitle style panel', () {
      SidebarType today(SidebarType previous, bool visible, bool fromCompose) {
        if (fromCompose) return SidebarType.videoCompose;
        return _todayPreviousOrRemembered(previous, visible);
      }

      for (final previous in SidebarType.values) {
        for (final visible in _bools) {
          for (final fromCompose in _bools) {
            expect(
              afterClose(
                fromCompose
                    ? LandscapeSidebarClosing.styleFromCompose
                    : LandscapeSidebarClosing.toolPanel,
                previous,
                visible,
              ),
              today(previous, visible, fromCompose),
              reason:
                  'previous=$previous visible=$visible fromCompose=$fromCompose',
            );
          }
        }
      }
    });

    test('close button of the subtitle list ignores the previous panel', () {
      for (final previous in SidebarType.values) {
        for (final visible in _bools) {
          for (final noise in _bilibiliNoise()) {
            final today = visible ? SidebarType.subtitles : SidebarType.none;
            expect(
              afterClose(
                LandscapeSidebarClosing.subtitleList,
                previous,
                visible,
                bilibiliRemembered: noise.bilibiliRemembered,
                allowAutoOpen: noise.allowAutoOpen,
              ),
              today,
              reason: 'previous=$previous visible=$visible $noise',
            );
          }
        }
      }
    });
  });

  group('portrait fallbacks, non-Bilibili video', () {
    PortraitPanel afterClose(
      PortraitPanelClosing closing, {
      PortraitBilibiliTab tab = PortraitBilibiliTab.details,
    }) {
      return _portraitPanel(
        portraitPanelAfterClose(
          closing: closing,
          isBilibiliVideo: false,
          rememberedTab: tab,
        ),
      );
    }

    test('first panel (_activePanel initial value)', () {
      for (final tab in PortraitBilibiliTab.values) {
        expect(
          _portraitPanel(
            portraitDefaultPanel(isBilibiliVideo: false, rememberedTab: tab),
          ),
          PortraitPanel.subtitles,
        );
      }
      expect(_portraitPanel(portraitDefaultPanel()), PortraitPanel.subtitles);
    });

    test('subtitle style close / back (_closeSubtitleStyleSettings) and '
        'subtitle manager close (_closeSubtitleManager)', () {
      for (final fromCompose in _bools) {
        for (final tab in PortraitBilibiliTab.values) {
          final today = fromCompose
              ? PortraitPanel.videoCompose
              : PortraitPanel.subtitles;
          expect(
            afterClose(
              fromCompose
                  ? PortraitPanelClosing.fromCompose
                  : PortraitPanelClosing.toolPanel,
              tab: tab,
            ),
            today,
            reason: 'fromCompose=$fromCompose tab=$tab',
          );
        }
      }
    });

    test('back key on any panel other than the subtitle list', () {
      PortraitPanel today(
        PortraitPanel active,
        bool styleFromCompose,
        bool managerFromCompose,
      ) {
        if (active == PortraitPanel.subtitleStyle && styleFromCompose) {
          return PortraitPanel.videoCompose;
        } else if (active == PortraitPanel.subtitleManager &&
            managerFromCompose) {
          return PortraitPanel.videoCompose;
        } else {
          return PortraitPanel.subtitles;
        }
      }

      for (final active in PortraitPanel.values) {
        if (active == PortraitPanel.subtitles) continue;
        for (final styleFromCompose in _bools) {
          for (final managerFromCompose in _bools) {
            final fromCompose =
                (active == PortraitPanel.subtitleStyle && styleFromCompose) ||
                (active == PortraitPanel.subtitleManager && managerFromCompose);
            expect(
              afterClose(
                fromCompose
                    ? PortraitPanelClosing.fromCompose
                    : PortraitPanelClosing.toolPanel,
              ),
              today(active, styleFromCompose, managerFromCompose),
              reason:
                  '$active style=$styleFromCompose manager=$managerFromCompose',
            );
          }
        }
      }
    });

    const backToSubtitleSites = <String>[
      'AI transcription: back',
      'part picker: close',
      'video compose: back',
      'OCR subtitles: back',
      'subtitle editor: back',
      'settings panel: close',
    ];
    for (final site in backToSubtitleSites) {
      test(site, () {
        for (final tab in PortraitBilibiliTab.values) {
          expect(
            afterClose(PortraitPanelClosing.toolPanel, tab: tab),
            PortraitPanel.subtitles,
          );
        }
      });
    }
  });

  group('Bilibili videos', () {
    test('landscape: the Bilibili panel comes first when it was left open '
        'and the window may open it', () {
      LandscapeSidebarTarget pick({
        required bool subtitles,
        required bool bilibili,
        required bool allow,
      }) => landscapeDefaultSidebar(
        subtitleSidebarRemembered: subtitles,
        isBilibiliVideo: true,
        bilibiliPanelRemembered: bilibili,
        allowAutoOpen: allow,
      );

      expect(
        pick(subtitles: true, bilibili: true, allow: true),
        LandscapeSidebarTarget.bilibili,
      );
      expect(
        pick(subtitles: false, bilibili: true, allow: true),
        LandscapeSidebarTarget.bilibili,
      );
      expect(
        pick(subtitles: true, bilibili: false, allow: true),
        LandscapeSidebarTarget.subtitles,
      );
      expect(
        pick(subtitles: true, bilibili: true, allow: false),
        LandscapeSidebarTarget.subtitles,
      );
      expect(
        pick(subtitles: false, bilibili: true, allow: false),
        LandscapeSidebarTarget.none,
      );
    });

    test('landscape: a tool panel still goes back to the panel before it', () {
      expect(
        landscapeSidebarAfterClose(
          closing: LandscapeSidebarClosing.toolPanel,
          hasPrevious: true,
          subtitleSidebarRemembered: true,
          isBilibiliVideo: true,
          bilibiliPanelRemembered: true,
        ),
        LandscapeSidebarTarget.previous,
      );
      expect(
        landscapeSidebarAfterClose(
          closing: LandscapeSidebarClosing.toolPanel,
          hasPrevious: false,
          subtitleSidebarRemembered: true,
          isBilibiliVideo: true,
          bilibiliPanelRemembered: true,
        ),
        LandscapeSidebarTarget.bilibili,
      );
      expect(
        landscapeSidebarAfterClose(
          closing: LandscapeSidebarClosing.styleFromCompose,
          hasPrevious: false,
          subtitleSidebarRemembered: true,
          isBilibiliVideo: true,
          bilibiliPanelRemembered: true,
        ),
        LandscapeSidebarTarget.videoCompose,
      );
    });

    test('portrait: the remembered tab decides, details by default', () {
      expect(
        portraitDefaultPanel(isBilibiliVideo: true),
        PortraitPanelTarget.bilibili,
      );
      expect(
        portraitDefaultPanel(
          isBilibiliVideo: true,
          rememberedTab: PortraitBilibiliTab.subtitles,
        ),
        PortraitPanelTarget.subtitles,
      );
      expect(
        portraitPanelAfterClose(
          closing: PortraitPanelClosing.toolPanel,
          isBilibiliVideo: true,
        ),
        PortraitPanelTarget.bilibili,
      );
      expect(
        portraitPanelAfterClose(
          closing: PortraitPanelClosing.fromCompose,
          isBilibiliVideo: true,
        ),
        PortraitPanelTarget.videoCompose,
      );
    });
  });
}
