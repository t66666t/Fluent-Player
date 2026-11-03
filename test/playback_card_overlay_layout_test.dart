import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

void main() {
  group('PlaybackCardOverlayLayout', () {
    test('content keeps system navigation space after closing the card', () {
      for (final cardHeight in [124.0, 146.0]) {
        expect(
          PlaybackCardOverlayLayout.contentBottomPadding(
            stableBottomInset: 32,
            cardHeight: cardHeight,
            isCardVisible: true,
          ),
          32 + PlaybackCardOverlayLayout.cardBottomGap + cardHeight,
        );
        expect(
          PlaybackCardOverlayLayout.contentBottomPadding(
            stableBottomInset: 32,
            cardHeight: cardHeight,
            isCardVisible: false,
          ),
          32,
        );
      }
      expect(
        PlaybackCardOverlayLayout.contentBottomPadding(
          stableBottomInset: 32,
          selectionBarHeight: 104,
          cardHeight: 146,
          isCardVisible: false,
        ),
        104,
      );
    });

    test('keeps the bottom inset when immersive mode reports zero', () {
      final normal = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(
          viewPadding: EdgeInsets.only(bottom: 24),
          padding: EdgeInsets.only(bottom: 24),
          systemGestureInsets: EdgeInsets.only(bottom: 16),
        ),
        0,
      );
      final immersive = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(),
        normal,
      );

      expect(normal, 24);
      expect(immersive, 24);
    });

    test('uses gesture inset when view padding is temporarily unavailable', () {
      final inset = PlaybackCardOverlayLayout.resolveStableBottomInset(
        const MediaQueryData(systemGestureInsets: EdgeInsets.only(bottom: 18)),
        0,
      );

      expect(inset, 18);
    });

    test('keeps the mini player above a selection bar', () {
      const stableInset = 24.0;
      const barHeight = 104.0;
      final lifted = PlaybackCardOverlayLayout.cardBottomAbove(
        stableBottomInset: stableInset,
        selectionBarHeight: barHeight,
      );

      expect(lifted, barHeight + PlaybackCardOverlayLayout.cardBottomGap);
      expect(
        PlaybackCardOverlayLayout.cardBottomAbove(
          stableBottomInset: stableInset,
          selectionBarHeight: 0,
        ),
        PlaybackCardOverlayLayout.cardBottom(stableInset),
      );
      // A bar shorter than the resting inset must not drop the player.
      expect(
        PlaybackCardOverlayLayout.cardBottomAbove(
          stableBottomInset: 48,
          selectionBarHeight: 20,
        ),
        PlaybackCardOverlayLayout.cardBottom(48),
      );
    });

    test('keeps action toggle at a fixed gap above the mini player', () {
      const stableInset = 24.0;
      const cardHeight = 124.0;
      final cardBottom = PlaybackCardOverlayLayout.cardBottom(stableInset);
      final actionBottom = PlaybackCardOverlayLayout.actionButtonsBottom(
        stableBottomInset: stableInset,
        cardHeight: cardHeight,
        isCardVisible: true,
      );

      expect(
        actionBottom - (cardBottom + cardHeight),
        PlaybackCardOverlayLayout.actionButtonsGap,
      );
    });

    test('custom FAB location anchors to the physical bottom-right', () {
      const geometry = ScaffoldPrelayoutGeometry(
        bottomSheetSize: Size.zero,
        contentBottom: 800,
        contentTop: 80,
        floatingActionButtonSize: Size(56, 400),
        minInsets: EdgeInsets.zero,
        scaffoldSize: Size(400, 800),
        snackBarSize: Size.zero,
        materialBannerSize: Size.zero,
        textDirection: TextDirection.ltr,
        minViewPadding: EdgeInsets.zero,
      );

      expect(
        const PlaybackActionButtonsLocation().getOffset(geometry),
        const Offset(328, 400),
      );
    });

    test('action buttons clear a landscape navigation bar or cutout', () {
      const geometry = ScaffoldPrelayoutGeometry(
        bottomSheetSize: Size.zero,
        contentBottom: 390,
        contentTop: 0,
        floatingActionButtonSize: Size(56, 120),
        minInsets: EdgeInsets.only(right: 48),
        scaffoldSize: Size(844, 390),
        snackBarSize: Size.zero,
        materialBannerSize: Size.zero,
        textDirection: TextDirection.ltr,
        minViewPadding: EdgeInsets.only(right: 44),
      );
      final offset = const PlaybackActionButtonsLocation().getOffset(geometry);
      expect(
        offset.dx + geometry.floatingActionButtonSize.width,
        844 - 48 - 16,
      );
      expect(offset.dy + geometry.floatingActionButtonSize.height, 390);
    });
  });
}
