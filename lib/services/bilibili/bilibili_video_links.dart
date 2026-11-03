import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/bilibili_browse_models.dart' show isValidBvid;
import '../../utils/bilibili_url_parser.dart';

enum BilibiliVideoOpenResult { app, browser, failed, cancelled }

/// Use the device platform, not its screen size (tablets can have wide panels).
bool get bilibiliVideoOpensInApp =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Public links derived from the playing video's identity, without a request
/// for its details. They also work while those details are loading or offline.
@immutable
class BilibiliVideoLinks {
  const BilibiliVideoLinks._(this.bvid, this.page);

  static BilibiliVideoLinks? tryParse(String bvid, {int page = 1}) {
    final value = bvid.trim();
    if (value.length < 2 || value.substring(0, 2).toUpperCase() != 'BV') {
      return null;
    }
    final normalized = normalizeBvidCase(value);
    if (!isValidBvid(normalized)) return null;
    return BilibiliVideoLinks._(normalized, page > 0 ? page : 1);
  }

  final String bvid;
  final int page;

  Uri get web => Uri.https(
    'www.bilibili.com',
    '/video/$bvid/',
    page > 1 ? <String, String>{'p': '$page'} : null,
  );

  Uri? get app {
    final aid = aidFromBvid(bvid);
    if (aid == null) return null;
    return Uri(
      scheme: 'bilibili',
      host: 'video',
      path: '/$aid',
      // The official mobile site's getVideoExtra uses page = web p - 1.
      query: 'page=${page - 1}',
    );
  }

  /// Try the mobile app directly, then the public website. Avoid canLaunchUrl:
  /// package visibility restrictions can make it report a false negative.
  /// A closed panel or a changed video must not trigger a delayed fallback.
  Future<BilibiliVideoOpenResult> open({bool Function()? isCurrent}) async {
    bool current() => isCurrent?.call() ?? true;
    if (!current()) return BilibiliVideoOpenResult.cancelled;
    final nativeUri = bilibiliVideoOpensInApp ? app : null;
    if (nativeUri != null) {
      if (await _launch(nativeUri)) return BilibiliVideoOpenResult.app;
      if (!current()) return BilibiliVideoOpenResult.cancelled;
    }
    return await _launch(web)
        ? BilibiliVideoOpenResult.browser
        : BilibiliVideoOpenResult.failed;
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Android throws when no matching activity is installed; other platforms
      // can return false. Both must allow the same fallback and retry.
      return false;
    }
  }
}
