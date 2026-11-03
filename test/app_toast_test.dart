import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_toast.dart';

void main() {
  Future<void> pumpToastHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pump();
  }

  testWidgets('replacing a toast before its first frame leaves no orphan', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);
    AppToast.show('旧任务通知');
    final current = AppToast.show('新任务通知');
    await tester.pump();
    expect(find.text('旧任务通知'), findsNothing);
    expect(find.text('新任务通知'), findsOneWidget);
    await current.dismiss(immediate: true);
    await tester.pump();
    expect(find.text('新任务通知'), findsNothing);
  });

  testWidgets('a toast dismissed before its first frame never appears', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);
    final notice = AppToast.show('已添加任务');
    await notice.dismiss(immediate: true);
    await tester.pump();
    expect(find.text('已添加任务'), findsNothing);
  });

  testWidgets('loading toast has a hard auto-dismiss timeout', (tester) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.showLoading('正在处理媒体文件...');
    await tester.pump();
    expect(find.text('正在处理媒体文件...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('正在处理媒体文件...'), findsNothing);
  });

  testWidgets('custom durations are capped by the global safety timeout', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.show('不会永久停留', duration: const Duration(days: 1));
    await tester.pump();
    expect(find.text('不会永久停留'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('不会永久停留'), findsNothing);
  });

  testWidgets('loading handle only dismisses its own presentation', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final loading = AppToast.showLoading('旧加载提示');
    await tester.pump();
    AppToast.show('新的完成提示', duration: const Duration(seconds: 10));
    await tester.pump();

    await loading.dismiss(immediate: true);
    await tester.pump();

    expect(find.text('旧加载提示'), findsNothing);
    expect(find.text('新的完成提示'), findsOneWidget);

    await AppToast.dismiss(immediate: true);
    await tester.pump();
  });

  testWidgets('loading handle immediately removes the current toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final loading = AppToast.showLoading('处理中');
    await tester.pump();
    expect(find.text('处理中'), findsOneWidget);

    await loading.dismiss(immediate: true);
    await tester.pump();

    expect(find.text('处理中'), findsNothing);
  });

  testWidgets('ordinary toast handle can force-remove an import notice', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final handle = AppToast.show('已添加 3 个任务到队列');
    await tester.pump();
    expect(find.text('已添加 3 个任务到队列'), findsOneWidget);

    await handle.dismiss(immediate: true);
    await tester.pump();
    expect(find.text('已添加 3 个任务到队列'), findsNothing);
  });

  testWidgets('any upward swipe fades out and removes the toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await tester.binding.setSurfaceSize(const Size(1400, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpToastHost(tester);

    AppToast.show('翻译完成', duration: const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('翻译完成'), findsOneWidget);

    // The raw-pointer fallback deliberately dismisses before Flutter's normal
    // drag touch-slop is reached. This protects tablet layouts from a partial
    // drag leaving a strip of the overlay at the top edge.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('翻译完成')),
    );
    await gesture.moveBy(const Offset(0, -12));
    await gesture.up();

    // It remains mounted while the reverse animation is fading it out.
    expect(find.text('翻译完成'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 160));

    expect(find.text('翻译完成'), findsNothing);
  });

  testWidgets('an old progress flow cannot update a newer toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final oldFlow = AppToast.showProgress('旧流程', progress: 0.1);
    await tester.pump();
    AppToast.show('新流程', duration: const Duration(seconds: 10));
    await tester.pump();

    oldFlow.updateProgress(message: '不应出现', progress: 0.9);
    await tester.pump();

    expect(find.text('新流程'), findsOneWidget);
    expect(find.text('不应出现'), findsNothing);

    await AppToast.dismiss(immediate: true);
    await tester.pump();
  });

  testWidgets('route changes immediately remove the previous flow toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        navigatorObservers: [AppToast.observer],
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pump();

    AppToast.show('上一页流程', duration: const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('上一页流程'), findsOneWidget);

    AppToast.navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pump();

    expect(find.text('上一页流程'), findsNothing);
  });

  testWidgets('background interruption immediately removes the toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.showLoading('处理中');
    await tester.pump();
    expect(find.text('处理中'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(find.text('处理中'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('interruption also removes an overlay already animating out', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.show('退出中的通知', duration: const Duration(seconds: 8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('退出中的通知')),
    );
    await gesture.moveBy(const Offset(0, -12));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await gesture.up();
    await tester.pump();

    expect(find.text('退出中的通知'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
