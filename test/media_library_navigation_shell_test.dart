import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/media_library_navigation.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

void main() {
  final foldersOnly = {MediaLibraryRootEntry.folders};
  final allEntries = MediaLibraryRootEntry.values.toSet();

  bool activeFolder(String id, Map<String, _FakeFolder> folders) {
    final folder = folders[id];
    return folder != null && !folder.recycled;
  }

  String? parentOf(String id, Map<String, _FakeFolder> folders) {
    return folders[id]?.parentId;
  }

  group('MediaLibraryNavigation', () {
    test('新装和未保存入口的旧库默认文件夹', () {
      expect(
        MediaLibraryNavigation.firstRunDefault(
          hasExistingLibraryContent: false,
        ),
        MediaLibraryRootEntry.folders,
      );
      expect(
        MediaLibraryNavigation.firstRunDefault(hasExistingLibraryContent: true),
        MediaLibraryRootEntry.folders,
      );
    });

    test('未初始化不把空库当成新装', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: false,
        hasExistingLibraryContent: false,
        storedEntry: '',
        userChosen: false,
        lastFolderId: '',
        availableEntries: foldersOnly,
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (_) => false,
        parentIdOf: (_) => null,
      );
      expect(plan.preferredEntry, MediaLibraryRootEntry.folders);
      expect(plan.persistPreferred, isFalse);
      expect(plan.folderToOpen, isNull);
    });

    test('初始化后的空库默认文件夹且不写入恢复偏好', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: false,
        storedEntry: '',
        userChosen: false,
        lastFolderId: '',
        availableEntries: foldersOnly,
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (_) => false,
        parentIdOf: (_) => null,
      );
      expect(plan.preferredEntry, MediaLibraryRootEntry.folders);
      expect(plan.persistPreferred, isFalse);
      expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
    });

    test('开启恢复时用户选过的入口优先于首次默认', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: 'recent',
        userChosen: true,
        restoreLastPage: true,
        lastFolderId: '',
        availableEntries: allEntries,
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (_) => false,
        parentIdOf: (_) => null,
      );
      expect(plan.preferredEntry, MediaLibraryRootEntry.recent);
      expect(plan.displayedEntry, MediaLibraryRootEntry.recent);
      expect(plan.persistPreferred, isFalse);
    });

    test('缺失或回收目录回退到最近有效祖先', () {
      final folders = <String, _FakeFolder>{
        'root-child': const _FakeFolder(parentId: null),
        'gone-parent': const _FakeFolder(
          parentId: 'root-child',
          recycled: true,
        ),
        'leaf': const _FakeFolder(parentId: 'gone-parent'),
      };
      expect(
        MediaLibraryNavigation.resolveLivingFolderId(
          requestedId: 'leaf',
          isActiveFolder: (id) => activeFolder(id, folders),
          parentIdOf: (id) => parentOf(id, folders),
        ),
        'leaf',
      );
      folders['leaf'] = const _FakeFolder(
        parentId: 'gone-parent',
        recycled: true,
      );
      expect(
        MediaLibraryNavigation.resolveLivingFolderId(
          requestedId: 'leaf',
          isActiveFolder: (id) => activeFolder(id, folders),
          parentIdOf: (id) => parentOf(id, folders),
        ),
        'root-child',
      );
      expect(
        MediaLibraryNavigation.resolveLivingFolderId(
          requestedId: 'missing',
          isActiveFolder: (id) => activeFolder(id, folders),
          parentIdOf: (id) => parentOf(id, folders),
        ),
        isNull,
      );
    });

    test('关闭恢复上次页面后使用指定入口且不打开文件夹', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: 'recent',
        userChosen: true,
        lastFolderId: 'nested',
        availableEntries: allEntries,
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (id) => id == 'nested',
        parentIdOf: (_) => null,
        restoreLastPage: false,
        startupEntry: 'continueLearning',
      );
      expect(plan.preferredEntry, MediaLibraryRootEntry.continueLearning);
      expect(plan.displayedEntry, MediaLibraryRootEntry.continueLearning);
      expect(plan.persistPreferred, isFalse);
      expect(plan.folderToOpen, isNull);
    });

    test('关闭恢复时非法默认入口回退到文件夹', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: 'recent',
        userChosen: true,
        lastFolderId: 'nested',
        availableEntries: allEntries,
        revealItemId: null,
        returnToSearchResults: false,
        isActiveFolder: (id) => id == 'nested',
        parentIdOf: (_) => null,
        restoreLastPage: false,
        startupEntry: 'missing',
      );
      expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
      expect(plan.folderToOpen, isNull);
    });

    test('定位真实目录忽略上次全局入口且不恢复嵌套文件夹', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: true,
        storedEntry: 'recent',
        userChosen: true,
        lastFolderId: 'nested',
        availableEntries: allEntries,
        revealItemId: 'video-1',
        returnToSearchResults: true,
        isActiveFolder: (id) => id == 'nested',
        parentIdOf: (_) => null,
      );
      expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
      expect(plan.forceFoldersForLocate, isTrue);
      expect(plan.hideSwitcher, isTrue);
      expect(plan.folderToOpen, isNull);
    });

    test('删除项后丢掉旧像素锚点', () {
      const anchor = MediaLibraryScrollAnchor(itemId: 'gone', offset: 420);
      final sanitized = MediaLibraryNavigation.sanitizeAnchor(
        anchor: anchor,
        visibleItemIds: {'still-here'},
      );
      expect(sanitized.itemId, isNull);
      expect(sanitized.offset, isNull);
    });
    test('仅提供定位目标也隐藏入口且不写入首次默认偏好', () {
      final plan = MediaLibraryNavigation.plan(
        libraryInitialized: true,
        hasExistingLibraryContent: false,
        storedEntry: '',
        userChosen: false,
        lastFolderId: '',
        availableEntries: allEntries,
        revealItemId: 'located-media',
        returnToSearchResults: false,
        isActiveFolder: (_) => false,
        parentIdOf: (_) => null,
      );
      expect(plan.forceFoldersForLocate, isTrue);
      expect(plan.hideSwitcher, isTrue);
      expect(plan.persistPreferred, isFalse);
      expect(plan.displayedEntry, MediaLibraryRootEntry.folders);
    });
  });

  testWidgets('未挂载入口不可点，已挂载入口可切换并清空选择', (tester) async {
    final hostKey = GlobalKey<_NavHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _NavHost(
          key: hostKey,
          availableEntries: {
            MediaLibraryRootEntry.folders,
            MediaLibraryRootEntry.recent,
          },
        ),
      ),
    );

    hostKey.currentState!.enterSelection('old-id');
    await tester.pump();
    expect(hostKey.currentState!.selectedIds, {'old-id'});

    await tester.tap(find.text('继续学习'));
    await tester.pump();
    expect(hostKey.currentState!.selectedIds, {'old-id'});
    expect(hostKey.currentState!.displayed, MediaLibraryRootEntry.folders);
    expect(find.text('folders-body'), findsOneWidget);

    await tester.tap(find.text('最近添加'));
    await tester.pump();
    expect(hostKey.currentState!.selectedIds, isEmpty);
    expect(hostKey.currentState!.displayed, MediaLibraryRootEntry.recent);
    expect(find.text('recent-body'), findsOneWidget);
  });

  testWidgets('搜索返回后仍停在原入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _NavHost(
          availableEntries: allEntries,
          initialEntry: MediaLibraryRootEntry.recent,
        ),
      ),
    );
    expect(find.text('recent-body'), findsOneWidget);

    await tester.tap(find.text('open-search'));
    await tester.pumpAndSettle();
    expect(find.text('search-results'), findsOneWidget);
    await tester.tap(find.text('close-search'));
    await tester.pumpAndSettle();
    expect(find.text('recent-body'), findsOneWidget);
  });

  testWidgets('定位页强制文件夹内容，不打开上次目录', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _NavHost(
          availableEntries: allEntries,
          initialEntry: MediaLibraryRootEntry.recent,
          revealItemId: 'item-1',
          returnToSearchResults: true,
          lastFolderId: 'nested',
          folders: const {'nested': _FakeFolder(parentId: null)},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('folders-body'), findsOneWidget);
    expect(find.text('nested-folder'), findsNothing);
    expect(find.text('继续学习'), findsNothing);
  });

  testWidgets('初始化完成后再恢复目录，且只推入一层', (tester) async {
    final hostKey = GlobalKey<_NavHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _NavHost(
          key: hostKey,
          availableEntries: foldersOnly,
          libraryInitialized: false,
          lastFolderId: 'nested',
          folders: const {'nested': _FakeFolder(parentId: null)},
        ),
      ),
    );
    expect(find.text('nested-folder'), findsNothing);

    hostKey.currentState!.markInitialized();
    await tester.pumpAndSettle();
    expect(find.text('nested-folder'), findsOneWidget);
    expect(find.text('folders-body'), findsNothing);
  });

  testWidgets('窄屏切换器与导入进度、迷你播放卡分区不互相覆盖', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: _ChromeProbe()));

    final switcherRect = tester.getRect(find.byType(MediaLibraryEntrySwitcher));
    final importRect = tester.getRect(
      find.byKey(const ValueKey('import-progress')),
    );
    final cardRect = tester.getRect(
      find.byKey(MediaLibraryOverlayKeys.miniPlaybackCard),
    );
    expect(switcherRect.bottom, lessThanOrEqualTo(importRect.top + 0.01));
    expect(importRect.bottom, lessThan(cardRect.top));
    expect(find.byType(MediaLibraryCompactTitle), findsNothing);
  });
}

class _FakeFolder {
  const _FakeFolder({required this.parentId, this.recycled = false});

  final String? parentId;
  final bool recycled;
}

class _NavHost extends StatefulWidget {
  const _NavHost({
    super.key,
    required this.availableEntries,
    this.initialEntry = MediaLibraryRootEntry.folders,
    this.revealItemId,
    this.returnToSearchResults = false,
    this.lastFolderId = '',
    this.libraryInitialized = true,
    this.folders = const {},
  });

  final Set<MediaLibraryRootEntry> availableEntries;
  final MediaLibraryRootEntry initialEntry;
  final String? revealItemId;
  final bool returnToSearchResults;
  final String lastFolderId;
  final bool libraryInitialized;
  final Map<String, _FakeFolder> folders;

  @override
  State<_NavHost> createState() => _NavHostState();
}

class _NavHostState extends State<_NavHost> {
  late MediaLibraryRootEntry storedEntry = widget.initialEntry;
  late bool initialized = widget.libraryInitialized;
  final selectedIds = <String>{};
  bool selectionMode = false;
  bool restoredFolder = false;

  MediaLibraryRootEntry get displayed => _plan.displayedEntry;

  MediaLibraryNavigationPlan get _plan {
    return MediaLibraryNavigation.plan(
      libraryInitialized: initialized,
      hasExistingLibraryContent: true,
      storedEntry: storedEntry.storageValue,
      userChosen: true,
      restoreLastPage: true,
      lastFolderId: widget.lastFolderId,
      availableEntries: widget.availableEntries,
      revealItemId: widget.revealItemId,
      returnToSearchResults: widget.returnToSearchResults,
      isActiveFolder: (id) =>
          widget.folders[id] != null && !widget.folders[id]!.recycled,
      parentIdOf: (id) => widget.folders[id]?.parentId,
    );
  }

  void enterSelection(String id) {
    setState(() {
      selectionMode = true;
      selectedIds
        ..clear()
        ..add(id);
    });
  }

  void markInitialized() {
    setState(() => initialized = true);
  }

  void _select(MediaLibraryRootEntry entry) {
    if (!widget.availableEntries.contains(entry)) return;
    setState(() {
      storedEntry = entry;
      selectionMode = false;
      selectedIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (initialized && !restoredFolder && plan.folderToOpen != null) {
      restoredFolder = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('nested-folder')),
              body: const SizedBox.shrink(),
            ),
          ),
        );
      });
    }

    final Widget body = switch (plan.displayedEntry) {
      MediaLibraryRootEntry.continueLearning => const Text('continue-body'),
      MediaLibraryRootEntry.recent => const Text('recent-body'),
      MediaLibraryRootEntry.folders => const Text('folders-body'),
      MediaLibraryRootEntry.bilibili => const Text('bilibili-body'),
      MediaLibraryRootEntry.podcasts => const Text('podcasts-body'),
      MediaLibraryRootEntry.cloudDrive => const Text('cloud-body'),
    };

    return Scaffold(
      appBar: AppBar(
        title: plan.hideSwitcher
            ? const Text('我的媒体库')
            : MediaLibraryEntrySwitcher(
                selected: plan.displayedEntry,
                availableEntries: widget.availableEntries,
                onSelected: _select,
              ),
      ),
      body: Column(
        children: [
          body,
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('close-search'),
                    ),
                    appBar: AppBar(title: const Text('search-results')),
                  ),
                ),
              );
            },
            child: const Text('open-search'),
          ),
        ],
      ),
    );
  }
}

class _ChromeProbe extends StatelessWidget {
  const _ChromeProbe();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 50,
        leadingWidth: 40,
        titleSpacing: 3,
        leading: MediaLibraryCompactIconButton(
          icon: Icons.grid_view_rounded,
          tooltip: '视图',
          onPressed: () {},
        ),
        title: MediaLibraryEntrySwitcher(
          compact: true,
          selected: MediaLibraryRootEntry.folders,
          availableEntries: {MediaLibraryRootEntry.folders},
          onSelected: (_) {},
        ),
        actions: [
          MediaLibraryCompactIconButton(
            icon: Icons.search_rounded,
            tooltip: '搜索',
            onPressed: () {},
          ),
        ],
      ),
      body: Stack(
        children: [
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 36,
            child: ColoredBox(
              key: ValueKey('import-progress'),
              color: Colors.orange,
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            height: 72,
            child: ColoredBox(
              key: MediaLibraryOverlayKeys.miniPlaybackCard,
              color: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }
}
