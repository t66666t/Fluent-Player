import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/widgets/experimental_layout_widgets.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ExperimentalLayout.instance.value = false;
  });
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1440, 900),
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('navigation and settings fit $size at $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
        Widget host(Widget child) => MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: child,
        );
        await tester.pumpWidget(
          host(
            Scaffold(
              body: ExperimentalHomeFrame(
                selected: selected,
                available: MediaLibraryRootEntry.values.toSet(),
                onSelected: (value) => selected = value,
                onSettings: () {},
                child: const Center(child: Text('媒体内容')),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('继续学习'));
        expect(selected, MediaLibraryRootEntry.continueLearning);
        await tester.pumpWidget(
          host(
            const ExperimentalSettingsPage(
              items: [
                SettingsCategoryBoundary(ExperimentalSettingsCategory.general),
                SwitchListTile(
                  value: true,
                  onChanged: null,
                  title: Text('启动偏好'),
                ),
                SettingsCategoryBoundary(ExperimentalSettingsCategory.playback),
                ListTile(title: Text('播放选项')),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('播放').first);
        await tester.pumpAndSettle();
        expect(find.text('播放选项'), findsOneWidget);
        expect(find.text('启动偏好'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
