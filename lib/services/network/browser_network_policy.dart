import 'network_models.dart';

/// Retired compatibility API; model/service HTTP networking uses NetworkHttp directly.
abstract final class BrowserNetworkPolicy {
  static Never _retired() => throw UnsupportedError('本地版已移除内置浏览器');
  static void release(Object owner) {}
  static Future<Uri> endpoint(NetworkScope scope, {Uri? source}) async =>
      _retired();
  static Future<void> prepare(
    NetworkScope scope, {
    Uri? source,
    Object? owner,
  }) async => _retired();
  static Future<String> windowsArguments(
    NetworkScope scope, {
    Uri? source,
  }) async => _retired();
}
