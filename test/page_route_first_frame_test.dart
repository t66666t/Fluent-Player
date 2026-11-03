import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';

/// 每次绘制时记录所在路由动画的状态和值。
class _PaintProbe extends SingleChildRenderObjectWidget {
  const _PaintProbe({required this.onPaint, super.child});

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintProbe(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintProbe renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderPaintProbe extends RenderProxyBox {
  _RenderPaintProbe(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

typedef _Frame = ({AnimationStatus status, double value});

class _TrackedRoute extends AppMaterialPageRoute<void> {
  _TrackedRoute()
    : super(builder: (_) => const Scaffold(body: Text('tracked')));

  bool pushFinished = false;

  @override
  TickerFuture didPush() {
    final future = super.didPush();
    future.then((_) => pushFinished = true);
    return future;
  }
}

Widget _probePage(BuildContext context, List<_Frame> log, String label) {
  final route = ModalRoute.of(context)!;
  return _PaintProbe(
    onPaint: () {
      final animation = route.animation!;
      log.add((status: animation.status, value: animation.value));
    },
    child: Scaffold(body: Text(label)),
  );
}

/// 和媒体库外框一样放一个内层导航器：它没有 HeroController，
/// 新页面第一帧不会被放到后台，压帧时画出来的就是用户看到的那一帧。
Widget _app(void Function(BuildContext context) open) {
  return MaterialApp(
    theme: ThemeData(
      platform: TargetPlatform.windows,
      pageTransitionsTheme: appPageTransitionsTheme,
    ),
    home: Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('navigation finishes only after the entrance actually settles', (
    tester,
  ) async {
    final route = _TrackedRoute();
    await tester.pumpWidget(
      _app((context) => Navigator.of(context).push(route)),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(route.animation!.status, AnimationStatus.forward);
    expect(route.pushFinished, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(route.pushFinished, isFalse);
    await tester.pumpAndSettle();
    expect(route.pushFinished, isTrue);
    expect(route.animation!.status, AnimationStatus.completed);
  });

  testWidgets('consuming local history does not restart the entrance clock', (
    tester,
  ) async {
    final route = _TrackedRoute();
    await tester.pumpWidget(
      _app((context) => Navigator.of(context).push(route)),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final before = route.animation!.value;
    var removed = false;
    route.addLocalHistoryEntry(
      LocalHistoryEntry(onRemove: () => removed = true),
    );
    Navigator.of(tester.element(find.text('tracked'))).pop();
    await tester.pump(const Duration(milliseconds: 16));
    expect(removed, isTrue);
    expect(route.animation!.status, AnimationStatus.forward);
    expect(route.animation!.value, greaterThan(before));
    await tester.pumpAndSettle();
  });

  testWidgets('a pop during the entrance never restarts a forward animation', (
    tester,
  ) async {
    final route = _TrackedRoute();
    await tester.pumpWidget(
      _app((context) => Navigator.of(context).push(route)),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final statuses = <AnimationStatus>[];
    route.animation!.addStatusListener(statuses.add);
    Navigator.of(tester.element(find.text('tracked'))).pop();
    await tester.pumpAndSettle();
    expect(statuses, contains(AnimationStatus.reverse));
    expect(statuses, isNot(contains(AnimationStatus.forward)));
    expect(find.text('tracked'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('进文件夹的第一帧按转场起点画，不先整页画出目标页', (tester) async {
    final log = <_Frame>[];
    await tester.pumpWidget(
      _app((context) {
        Navigator.of(context).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: 'A',
            builder: (context) => _probePage(context, log, 'folder'),
          ),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(log, isEmpty, reason: '和视频页一样，零透明度首帧不整页预绘制');
    await tester.pump(const Duration(milliseconds: 16));
    expect(log, isNotEmpty);
    expect(log.first.status, AnimationStatus.forward);
    expect(log.first.value, inExclusiveRange(0.0, 1.0));
    expect(
      log.map((f) => f.status),
      isNot(contains(AnimationStatus.dismissed)),
    );

    await tester.pumpAndSettle();
    expect(find.text('folder'), findsOneWidget);
  });

  testWidgets('普通页面路由的第一帧同样按转场起点画', (tester) async {
    final log = <_Frame>[];
    await tester.pumpWidget(
      _app((context) {
        Navigator.of(context).push(
          AppMaterialPageRoute<void>(
            builder: (context) => _probePage(context, log, 'page'),
          ),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(log, isEmpty);
    await tester.pump(const Duration(milliseconds: 16));
    expect(log, isNotEmpty);
    expect(log.first.status, AnimationStatus.forward);
    expect(
      log.map((f) => f.status),
      isNot(contains(AnimationStatus.dismissed)),
    );

    await tester.pumpAndSettle();
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('返回的第一帧已经处在退出转场中，不卡在完成状态', (tester) async {
    final log = <_Frame>[];
    await tester.pumpWidget(
      _app((context) {
        Navigator.of(context).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: 'A',
            builder: (context) => _probePage(context, log, 'folder'),
          ),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('folder')))!;
    expect(route.animation!.status, AnimationStatus.completed);

    // 被返回的页面在第一帧通常走缓存图层不重画，所以这里直接看
    // pop 之后、下一帧开画之前路由动画处在什么状态：那一帧就按它来画。
    final statuses = <AnimationStatus>[];
    route.animation!.addStatusListener(statuses.add);
    Navigator.of(tester.element(find.text('folder'))).pop();

    expect(route.animation!.status, AnimationStatus.reverse);
    expect(route.animation!.value, 1);
    expect(statuses, isNot(contains(AnimationStatus.completed)));

    await tester.pump();
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(statuses, isNot(contains(AnimationStatus.completed)));

    await tester.pumpAndSettle();
    expect(find.text('folder'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('恢复上次文件夹仍然第一帧直接到位', (tester) async {
    await tester.pumpWidget(
      _app((context) {
        Navigator.of(context).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: 'A',
            restored: true,
            builder: (_) => const Scaffold(body: Text('restored')),
          ),
        );
      }),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    final route = ModalRoute.of(tester.element(find.text('restored')))!;
    expect(route.animation!.status, AnimationStatus.completed);
    expect(find.text('open'), findsNothing);
  });
}
