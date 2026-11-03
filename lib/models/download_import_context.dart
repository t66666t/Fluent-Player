import 'package:uuid/uuid.dart';

/// Frozen acquisition order. Scheduling priority must never mutate this value.
class DownloadImportContext {
  const DownloadImportContext({
    required this.batchId,
    required this.memberId,
    required this.order,
    required this.operationId,
    required this.startedAtMs,
    required this.title,
  });

  final String batchId, memberId, operationId, title;
  final List<int> order;
  final int startedAtMs;

  /// Stable even if the library commit succeeds before the queue is saved.
  String get mediaId =>
      const Uuid().v5(Namespace.url.value, 'download:$operationId');

  static List<DownloadImportContext> freeze({
    required Iterable<String> memberIds,
    required String title,
  }) {
    final batchId = const Uuid().v4();
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    final ids = memberIds.toList(growable: false);
    return List.generate(
      ids.length,
      (index) => DownloadImportContext(
        batchId: batchId,
        memberId: ids[index],
        order: List<int>.unmodifiable([index]),
        operationId: const Uuid().v4(),
        startedAtMs: startedAtMs,
        title: title,
      ),
      growable: false,
    );
  }

  factory DownloadImportContext.single({
    required String memberId,
    required String title,
  }) => freeze(memberIds: [memberId], title: title).single;

  DownloadImportContext child({required String memberId, required int index}) =>
      DownloadImportContext(
        batchId: batchId,
        memberId: memberId,
        order: List<int>.unmodifiable([...order, index]),
        operationId: const Uuid().v5(
          Namespace.url.value,
          '$operationId:$memberId:$index',
        ),
        startedAtMs: startedAtMs,
        title: title,
      );

  static int compareOrder(DownloadImportContext a, DownloadImportContext b) {
    final count = a.order.length < b.order.length
        ? a.order.length
        : b.order.length;
    for (var i = 0; i < count; i++) {
      final comparison = a.order[i].compareTo(b.order[i]);
      if (comparison != 0) return comparison;
    }
    final length = a.order.length.compareTo(b.order.length);
    return length != 0 ? length : a.memberId.compareTo(b.memberId);
  }

  Map<String, Object> toJson() => {
    'batchId': batchId,
    'memberId': memberId,
    'order': order,
    'operationId': operationId,
    'startedAtMs': startedAtMs,
    'title': title,
  };

  static DownloadImportContext? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['batchId'] is! String ||
        raw['memberId'] is! String ||
        raw['operationId'] is! String ||
        raw['startedAtMs'] is! num ||
        raw['order'] is! List) {
      return null;
    }
    if ((raw['order'] as List).any((n) => n is! int || n < 0)) {
      return null;
    }
    final order = (raw['order'] as List)
        .whereType<num>()
        .map((n) => n.toInt())
        .toList();
    if (order.isEmpty ||
        order.any((n) => n < 0) ||
        (raw['batchId'] as String).isEmpty ||
        (raw['operationId'] as String).isEmpty) {
      return null;
    }
    return DownloadImportContext(
      batchId: raw['batchId'] as String,
      memberId: raw['memberId'] as String,
      operationId: raw['operationId'] as String,
      startedAtMs: (raw['startedAtMs'] as num).toInt(),
      title: raw['title'] is String ? raw['title'] as String : '下载',
      order: List<int>.unmodifiable(order),
    );
  }
}

/// Issued only after the library and its acquisition order are durable.
class ImportReceipt {
  const ImportReceipt({required this.mediaId, required this.context});
  final String mediaId;
  final DownloadImportContext context;
}
