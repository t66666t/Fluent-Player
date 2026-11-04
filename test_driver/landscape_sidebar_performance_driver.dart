import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      final output =
          Platform.environment['SIDEBAR_PROFILE_OUTPUT'] ??
          'build/sidebar-performance/native.json';
      final file = File(output);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    },
  );
}
