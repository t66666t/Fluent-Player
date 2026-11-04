/// Compatibility API only. Local-only playback never opens a browser or reads cookies.
class BilibiliWebLoginBrowser {
  Object? get environment => null;
  Never _retired() => throw UnsupportedError('本地版已移除哔哩哔哩登录与在线播放');
  Future<void> prepare() async => _retired();
  Future<void> reopen() async => _retired();
  Future<Map<String, String>> readCookies() async => _retired();
  Future<void> dispose() async {}
}
