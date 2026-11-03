import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

class _RecordingLibrary extends ChangeNotifier implements LibraryService {
  final imports = <Invocation>[];

  @override
  bool get hasActiveImport => false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #importVideosBackground) {
      imports.add(invocation);
      return Future.value(const MediaImportExecutionResult());
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = MethodChannel('com.example.video_player_app/file_manager');
  final calls = <MethodCall>[];
  late _RecordingLibrary library;
  Object? selection;
  final stage = p.join(
    Directory.systemTemp.path,
    'own-cache',
    'picked_media',
    'id',
    'movie.mp4',
  );
  final source = p.join(Directory.systemTemp.path, 'provider', 'movie.mp4');

  setUp(() {
    library = _RecordingLibrary();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(files, (call) async {
          calls.add(call);
          return selection;
        });
  });

  tearDown(() async {
    await AppToast.dismiss(immediate: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(files, null);
    library.dispose();
  });

  Future<void> choose(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    VideoActionButtons.showImportMenu(context, null),
                child: const Text('导入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithIcon(ListTile, Icons.folder_open),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.widgetWithIcon(ListTile, Icons.folder_open));
    await tester.pumpAndSettle();
    await AppToast.dismiss(immediate: true);
    await tester.pump();
  }

  testWidgets(
    'SAF passes a selected staged file and its read-only sidecar hint',
    (tester) async {
      selection = {
        'paths': [stage],
        'sourcePathHints': {
          stage: source,
          '/not-selected.mp4': '/unrelated.mp4',
        },
      };
      await choose(tester);
      expect(library.imports, hasLength(1));
      final request = library.imports.single;
      expect(request.positionalArguments.first, [stage]);
      expect(request.namedArguments[#sidecarSourcePaths], {stage: source});
      expect(request.namedArguments[#shouldCopy], isFalse);
      expect(request.namedArguments[#useOriginalPath], isFalse);
      expect((calls.single.arguments as Map)['includeSourceHints'], isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'legacy host list still imports without a source hint',
    (tester) async {
      selection = [stage];
      await choose(tester);
      expect(library.imports, hasLength(1));
      expect(library.imports.single.positionalArguments.first, [stage]);
      expect(
        library.imports.single.namedArguments[#sidecarSourcePaths] ?? {},
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'URI and traversal hints do not redirect sidecar discovery',
    (tester) async {
      final other = p.join(Directory.systemTemp.path, 'own-cache', 'other.mp4');
      selection = {
        'paths': [stage, other],
        'sourcePathHints': {
          stage: 'content://untrusted.provider/private/movie.mp4',
          other:
              '${p.dirname(source)}${p.separator}..${p.separator}private.mp4',
        },
      };
      await choose(tester);
      expect(library.imports, hasLength(1));
      expect(library.imports.single.positionalArguments.first, [stage, other]);
      expect(
        library.imports.single.namedArguments[#sidecarSourcePaths] ?? {},
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
