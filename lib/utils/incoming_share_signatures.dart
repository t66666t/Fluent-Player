/// Dedupes platform share deliveries without permanently swallowing a file.
///
/// Android/iOS can emit the same share twice (pending queue + event channel).
/// A short window absorbs that race. The same archive shared again later must
/// still open the import dialog.
class IncomingShareSignatures {
  IncomingShareSignatures._();

  static const Duration defaultWindow = Duration(seconds: 3);

  static String? fromItems(List<dynamic> items) {
    final signatures = <String>[];
    for (final item in items) {
      if (item is String) {
        final normalized = item.trim();
        if (normalized.isNotEmpty) {
          signatures.add(
            normalized.toLowerCase().endsWith('.fluentpack')
                ? 'fluentpack:${normalized.toLowerCase()}'
                : 'media:${normalized.toLowerCase()}',
          );
        }
        continue;
      }
      if (item is! Map) {
        continue;
      }

      final kind = (item['kind'] as String?)?.trim().toLowerCase() ?? 'media';
      if (kind == 'archive' || kind == 'fluentpack') {
        final path = (item['path'] as String?)?.trim();
        final uri = (item['uri'] as String?)?.trim();
        final displayName = (item['displayName'] as String?)?.trim();
        final key = path?.isNotEmpty == true
            ? path!.toLowerCase()
            : (uri?.isNotEmpty == true
                  ? uri!
                  : (displayName?.isNotEmpty == true
                        ? displayName!
                        : kind));
        signatures.add('$kind:$key');
        continue;
      }

      final path = (item['path'] as String?)?.trim();
      if (path != null && path.isNotEmpty) {
        signatures.add('media:${path.toLowerCase()}');
      }
    }
    if (signatures.isEmpty) return null;
    signatures.sort();
    return signatures.join('||');
  }

  /// Returns false when [signature] was already accepted inside [window].
  static bool accept(
    String signature,
    Map<String, DateTime> recent, {
    DateTime? now,
    Duration window = defaultWindow,
  }) {
    final current = now ?? DateTime.now();
    recent.removeWhere((_, seenAt) => current.difference(seenAt) > window);
    final previous = recent[signature];
    if (previous != null && current.difference(previous) <= window) {
      return false;
    }
    recent[signature] = current;
    return true;
  }

  static void release(String signature, Map<String, DateTime> recent) {
    recent.remove(signature);
  }
}

/// Host-route gate for import UI.
///
/// System shares arrive while a player page is on top. Those must still show
/// the archive dialog on the root navigator. Drag-and-drop keeps the stricter
/// "current route" check so a buried folder page cannot present a second UI.
bool canPresentIncomingImportUi({
  required bool requireCurrentRoute,
  required bool? routeIsCurrent,
}) {
  if (!requireCurrentRoute) return true;
  return routeIsCurrent == true;
}
