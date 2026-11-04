import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source checks for the media library frame: pages that are not library
/// pages must open above the frame (and so above its mini player), and the
/// library pages must only react while nothing covers the frame.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  int lineOf(String source, int offset) =>
      '\n'.allMatches(source.substring(0, offset)).length + 1;

  /// Library routes that stay on the frame's navigator.
  const libraryRouteMarkers = <String>[
    'buildMediaLibraryFolderRoute',
    'buildMediaLibrarySearchResultsRoute',
    'PodcastDiscoverPage',
    '_buildDirectoryLocationRoute',
  ];

  test('library pages open other pages only through the frame entry', () {
    const files = <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
      'lib/widgets/video_action_buttons.dart',
      'lib/screens/bilibili/bilibili_home_page.dart',
      'lib/screens/bilibili/bilibili_card_actions.dart',
    ];
    final push = RegExp(
      r'(Navigator\.of\([^()]*\)\s*\.\s*|Navigator\.|navigator\.)'
      r'(push|pushReplacement|pushAndRemoveUntil|pushNamed)\b',
    );
    final offenders = <String>[];
    for (final path in files) {
      final source = read(path);
      for (final match in push.allMatches(source)) {
        final after = source.substring(
          match.start,
          (match.start + 400).clamp(0, source.length),
        );
        final before = source.substring(
          (match.start - 1500).clamp(0, source.length),
          match.start,
        );
        final isLibraryRoute = libraryRouteMarkers.any(after.contains);
        // Locate pushes a folder route or a home page that reveals an item.
        final isLocate =
            after.startsWith('Navigator.of(context).push(route)') &&
            before.contains('void _locateLibraryEntry(');
        // A navigator taken from the frame entry.
        final isCoverNavigator =
            match.group(1) == 'navigator.' &&
            RegExp(
              r'navigator = mediaLibraryCoverNavigator\(',
            ).allMatches(before).isNotEmpty;
        // A breadcrumb that finds no folder to pop to places it directly.
        final isBreadcrumb =
            match.group(1) == 'navigator.' &&
            before.contains('popMediaLibraryToFolder(navigator') &&
            libraryRouteMarkers.any(after.contains);
        if (isLibraryRoute || isLocate || isCoverNavigator || isBreadcrumb) {
          continue;
        }
        offenders.add('$path:${lineOf(source, match.start)}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Open non-library pages with pushAboveMediaLibrary so they cover '
          'the mini player',
    );
  });

  test('recycle bin and playback open above the media library frame', () {
    // 社区版已退役 Bilibili 卡片导航；兼容层不再从 card_actions 打开全屏页。
    final cardActions = read('lib/screens/bilibili/bilibili_card_actions.dart');
    expect(
      'pushAboveMediaLibrary('.allMatches(cardActions).length,
      0,
      reason: 'community edition: no Bilibili card shell navigation',
    );
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
    ]) {
      final source = read(path);
      final recycle = RegExp(
        r'pushAboveMediaLibrary\(\s*context,\s*AppMaterialPageRoute\(\s*'
        r'builder: \(_\) => const RecycleBinScreen\(\)',
      );
      expect(recycle.allMatches(source).length, 3, reason: path);
      expect(
        source,
        contains(
          'pushAboveMediaLibrary(\n      context,\n'
          '      _buildVideoPlayerRoute(item, existingController),',
        ),
      );
    }
  });

  test('menus and sheets opened from library pages cover the card', () {
    final settingsSource = read('lib/widgets/media_library_settings_sheet.dart');
    // 设置页改为根 Navigator 全屏 push，与 useRootNavigator 的 sheet 等价。
    expect(
      settingsSource,
      contains(
        'Navigator.of(\n    context,\n    rootNavigator: true,\n  ).push<void>(AppMaterialPageRoute(builder: buildSurface)',
      ),
      reason: 'lib/widgets/media_library_settings_sheet.dart',
    );
    for (final entry in <String, String>{
      'lib/widgets/media_library_style_sheet.dart': 'showModalBottomSheet<',
      'lib/widgets/library_folder_picker.dart': 'showModalBottomSheet<',
      'lib/features/podcasts/podcast_menu.dart': 'showGeneralDialog<',
      'lib/features/progress_sync/progress_sync_components.dart':
          'showModalBottomSheet<',
      'lib/widgets/video_action_buttons.dart': 'showModalBottomSheet(',
      'lib/widgets/media_library_compact_app_bar.dart':
          'CapsulePopupMenuButton<',
    }.entries) {
      final source = read(entry.key);
      final matches = entry.value.allMatches(source).toList();
      expect(matches, isNotEmpty, reason: entry.key);
      for (final match in matches) {
        final call = source.substring(match.start, match.start + 200);
        expect(
          call,
          anyOf(
            contains('useRootNavigator: true'),
            contains('rootNavigator: true'),
          ),
          reason: entry.key,
        );
      }
    }
  });

  test('library pages react only while nothing covers the frame', () {
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
      'lib/widgets/video_action_buttons.dart',
    ]) {
      final source = read(path);
      expect(source, isNot(contains('ModalRoute.of(')), reason: path);
    }
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
    ]) {
      final source = read(path);
      final keyHandler = source.substring(
        source.indexOf('KeyEventResult _handleShortcutKeyEvent('),
      );
      final firstReturn = keyHandler.indexOf('return KeyEventResult');
      expect(
        keyHandler.substring(0, firstReturn + 200),
        contains('if (!isMediaLibraryRouteCurrent(context)) return'),
        reason: '$path: Esc, space and arrows',
      );
      for (final callback in <String>['onDragDone:', 'onDragEntered:']) {
        final start = source.indexOf(callback);
        expect(start, isNonNegative, reason: '$path $callback');
        expect(
          source.substring(start, start + 160),
          contains('if (!isMediaLibraryRouteCurrent(context)) return;'),
          reason: '$path $callback: file drops',
        );
      }
    }
    final actions = read('lib/widgets/video_action_buttons.dart');
    expect(
      'isMediaLibraryRouteCurrent(context)'.allMatches(actions).length,
      3,
      reason: 'dropped folder checks',
    );
    expect(
      actions,
      contains('routeIsCurrent: mediaLibraryRouteIsCurrent(context)'),
    );
  });

  test('the mini player lives only in the library frame', () {
    final main = read('lib/main.dart');
    expect(main, contains('buildMediaLibraryShellRoute<void>('));
    expect(main, contains('home: const HomeScreen()'));
    expect(main, isNot(contains('MiniPlaybackCard')));
    expect(main, contains('MouseBackButtonListener('));
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
      'lib/screens/video_player_screen.dart',
      'lib/screens/portrait_video_screen.dart',
      'lib/services/playback_navigation_service.dart',
    ]) {
      final source = read(path);
      expect(source, isNot(contains('MiniPlaybackCard(')), reason: path);
      expect(source, isNot(contains('mini_playback_card.dart')), reason: path);
    }
    final shell = read('lib/widgets/media_library_shell.dart');
    expect('MiniPlaybackCard('.allMatches(shell).length, 1);
    expect(shell, contains('openCurrentPlaybackSession('));
    expect(shell, contains('AppToast.createRouteChangeObserver()'));
    expect(shell, contains('NavigatorPopHandler'));
  });
}
