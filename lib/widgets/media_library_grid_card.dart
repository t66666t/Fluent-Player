import 'card_context_menu.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';

import '../theme/app_tokens.dart';
import '../models/video_item.dart';
import 'media_card_preparation.dart';
import 'media_library_keyboard_navigation.dart';

/// Shared chrome for media-library grid cards.
///
/// Default [Card] + [InkWell] draws a translucent white rounded highlight.
/// After an orientation change that highlight often stays behind, which is
/// exactly the stray square on shrunken portrait thumbnails.
class MediaLibraryGridCard extends StatelessWidget {
  const MediaLibraryGridCard({
    super.key,
    required this.radius,
    required this.isSelected,
    required this.onTap,
    required this.child,
    this.onSecondaryTap,
    this.elevation,
    this.cacheItem,
    this.keyboardItemId,
    this.isSelectionMode = false,
  });

  final double radius;
  final bool isSelected;
  final VoidCallback onTap;

  /// Fallback secondary action when no overflow menu is visible.
  final VoidCallback? onSecondaryTap;
  final Widget child;
  final double? elevation;
  final VideoItem? cacheItem;
  final String? keyboardItemId;
  final bool isSelectionMode;

  static const WidgetStateProperty<Color?> _noOverlay =
      WidgetStatePropertyAll<Color?>(Colors.transparent);

  @override
  Widget build(BuildContext context) {
    return CardContextMenu(
      onFallback: onSecondaryTap,
      builder: (context, openMenu) => MediaLibraryKeyboardItem(
        itemId: MediaLibraryKeyboardIdentity.of(context) ?? keyboardItemId ?? cacheItem?.id ?? '',
        selected: isSelected,
        selectionMode: isSelectionMode,
        onActivate: onTap,
        child: MediaCardPreparationHost(
          radius: radius,
          child: Card(
            margin: EdgeInsets.zero,
            elevation: elevation ?? 0,
            color: isSelected ? AppTokens.accentSoft : AppTokens.bgCard,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
            child: InkWell(
              canRequestFocus: !MediaLibraryKeyboardRegion.enabledOf(context),
              onTap: () {
                unawaited(AppHaptics.cardTap(SettingsService()));
                onTap();
              },
              onSecondaryTap: openMenu,
              splashFactory: NoSplash.splashFactory,
              overlayColor: _noOverlay,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              focusColor: Colors.transparent,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
