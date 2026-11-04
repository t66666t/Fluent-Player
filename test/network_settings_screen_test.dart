import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/network_settings_screen.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

void main() {
  testWidgets(
    'only local learning services are offered without changing stored legacy modes',
    (tester) async {
      final store = MemoryNetworkStore()
        ..saved = NetworkConfiguration(
          modes: {
            NetworkScope.bilibili: NetworkMode.system,
            NetworkScope.cloudDrive: NetworkMode.system,
            NetworkScope.translation: NetworkMode.direct,
          },
        );
      final settings = NetworkSettingsService(
        store: store,
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      final before = Map.of(settings.configuration.featureModes);
      await tester.binding.setSurfaceSize(const Size(700, 1900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: NetworkSettingsScreen(service: settings)),
      );
      await tester.pumpAndSettle();
      for (final scope in [
        NetworkScope.speechRecognition,
        NetworkScope.cloudTranscription,
        NetworkScope.translation,
        NetworkScope.updates,
        NetworkScope.modelDownloads,
        NetworkScope.other,
      ]) {
        expect(find.text(scope.label), findsOneWidget);
      }
      for (final scope in [
        NetworkScope.bilibili,
        NetworkScope.cloudDrive,
        NetworkScope.ytDlpDomestic,
        NetworkScope.ytDlpOther,
        NetworkScope.podcastsDomestic,
        NetworkScope.podcasts,
      ]) {
        expect(find.text(scope.label), findsNothing);
      }
      expect(find.text('媒体缓存传输'), findsNothing);
      expect(find.textContaining('播客'), findsNothing);
      expect(find.textContaining('YTDLP'), findsNothing);
      expect(settings.configuration.featureModes, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unified settings fit a narrow screen with larger text', (
    tester,
  ) async {
    final settings = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await settings.ready;
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: NetworkSettingsScreen(service: settings),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CapsuleDropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('统一不使用系统代理').last);
    await tester.pumpAndSettle();
    expect(settings.configuration.unifiedMode, NetworkMode.direct);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unified choices cover features and restore individual controls',
    (tester) async {
      final settings = NetworkSettingsService(
        store: MemoryNetworkStore(),
        credentials: MemoryCredentials(),
        migrateLegacy: false,
      );
      await settings.ready;
      await tester.binding.setSurfaceSize(const Size(430, 1900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: NetworkSettingsScreen(service: settings)),
      );
      await tester.pumpAndSettle();
      expect(find.text('语音识别接口'), findsOneWidget);
      await tester.tap(find.byType(CapsuleDropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('统一跟随设备网络').last);
      await tester.pumpAndSettle();
      expect(settings.configuration.unifiedMode, NetworkMode.system);
      expect(
        find.byType(CapsuleDropdownButtonFormField<NetworkMode>),
        findsNothing,
      );
      expect(find.text('播客 · 使用统一设置'), findsNothing);
      await tester.tap(find.byType(CapsuleDropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按功能分别设置（默认）').last);
      await tester.pumpAndSettle();
      expect(settings.configuration.unifiedMode, isNull);
      expect(
        settings.configuration.modes[NetworkScope.speechRecognition],
        NetworkMode.direct,
      );
      expect(find.text('语音识别接口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unconfigured unified custom mode opens form before applying', (
    tester,
  ) async {
    final settings = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await settings.ready;
    await tester.pumpWidget(
      MaterialApp(home: NetworkSettingsScreen(service: settings)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CapsuleDropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('统一使用自定义代理').last);
    await tester.pumpAndSettle();
    expect(settings.configuration.unifiedMode, isNull);
    expect(find.text('保存后，所有功能统一使用此代理'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '代理主机'),
      '127.0.0.1',
    );
    final save = find.text('保存代理配置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(settings.configuration.unifiedMode, NetworkMode.custom);
    expect(settings.configuration.modes.values.toSet(), {NetworkMode.custom});
  });
  testWidgets('missing password can be replaced without changing the route', (
    tester,
  ) async {
    final store = MemoryNetworkStore()
      ..saved = NetworkConfiguration(
        proxy: const ProxyProfile(
          protocol: ProxyProtocol.http,
          host: '127.0.0.1',
          port: 7890,
          username: 'account',
          credentialKey: 'missing',
        ),
        modes: {NetworkScope.translation: NetworkMode.custom},
      );
    final credentials = MemoryCredentials();
    final settings = NetworkSettingsService(
      store: store,
      credentials: credentials,
      migrateLegacy: false,
    );
    await expectLater(settings.ready, throwsA(isA<NetworkSettingsException>()));
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: NetworkSettingsScreen(service: settings)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '自定义代理'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码（可选）'),
      'replacement',
    );
    final save = find.text('保存代理配置');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(settings.isLoaded, isTrue);
    expect(
      settings.configuration.modes[NetworkScope.translation],
      NetworkMode.custom,
    );
    expect(
      await settings.passwordFor(settings.configuration.proxy),
      'replacement',
    );
    expect(settings.state, NetworkSaveState.applied);
  });
  testWidgets(
    'invalid custom form cannot replace the applied route or save credentials',
    (tester) async {
      final store = MemoryNetworkStore();
      final credentials = MemoryCredentials();
      final settings = NetworkSettingsService(
        store: store,
        credentials: credentials,
        migrateLegacy: false,
      );
      await settings.ready;
      await tester.binding.setSurfaceSize(const Size(900, 1700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: NetworkSettingsScreen(service: settings)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, '自定义代理'));
      await tester.pumpAndSettle();
      final host = find.widgetWithText(TextFormField, '代理主机');
      await tester.enterText(host, 'https://invalid:8080/path');
      final save = find.text('保存代理配置');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('请输入主机名或 IP 地址，地址不含类型和端口'), findsOneWidget);
      expect(settings.configuration.proxy, isNull);
      expect(store.saved, isNull);
      expect(credentials.values, isEmpty);
    },
  );
}
