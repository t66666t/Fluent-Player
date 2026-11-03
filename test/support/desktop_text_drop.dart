import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Object?> sendDesktopDropMessage(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  const codec = StandardMethodCodec();
  final bytes = await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage(
        'desktop_drop',
        codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );
  return bytes == null ? null : codec.decodeEnvelope(bytes);
}

Future<bool> dropDesktopText(
  WidgetTester tester,
  Offset point, {
  String? text,
  List<String> urls = const [],
  String method = 'performTextOperation',
}) async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    point *= tester.view.devicePixelRatio;
  }
  return await sendDesktopDropMessage(tester, method, {
        'x': point.dx,
        'y': point.dy,
        'text': text,
        'urls': urls,
      }) ==
      true;
}
