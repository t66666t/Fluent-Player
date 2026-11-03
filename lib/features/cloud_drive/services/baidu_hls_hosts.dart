import 'dart:convert';

/// Baidu's web player rotates the authorities declared in each TS URL's
/// `backhost` JSON array after a CDN error (its `smartHost` path). The signed
/// path and query identify the same segment on each of those servers.
List<Uri> baiduHlsHostCandidates(
  Uri source, {
  String? preferredAuthority,
  Iterable<String> inheritedAuthorities = const [],
}) {
  const suffixes = ['.baidu.com', '.baidupcs.com', '.bcebos.com'];
  bool allowed(String host) => suffixes.any(host.endsWith);
  if (source.scheme != 'https' && source.scheme != 'http' ||
      !allowed(source.host)) {
    return [source];
  }
  final raw = source.queryParameters['backhost'];
  if (raw != null && raw.length > 4096) return [source];
  final Object? decoded;
  try {
    decoded = raw == null ? inheritedAuthorities.toList() : jsonDecode(raw);
  } on FormatException {
    return [source];
  }
  if (decoded is! List) return [source];
  final candidates = <Uri>[source];
  final authorities = <String>{source.authority};
  for (final value in decoded.take(8)) {
    if (value is! String || value.isEmpty || value.length > 253) continue;
    final host = Uri.tryParse('${source.scheme}://$value');
    if (host == null ||
        !host.hasAuthority ||
        host.userInfo.isNotEmpty ||
        host.path.isNotEmpty ||
        host.hasQuery ||
        host.hasFragment ||
        !allowed(host.host) ||
        host.port < 1 ||
        host.port > 65535 ||
        !authorities.add(host.authority)) {
      continue;
    }
    candidates.add(source.replace(host: host.host, port: host.port));
  }
  if (preferredAuthority != null) {
    final index = candidates.indexWhere(
      (uri) => uri.authority == preferredAuthority,
    );
    if (index > 0) candidates.insert(0, candidates.removeAt(index));
  }
  return candidates;
}
