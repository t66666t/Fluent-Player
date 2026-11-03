enum CloudDriveResumeAction { append, replace, complete }

class CloudDriveResumeDecision {
  const CloudDriveResumeDecision(this.action, this.reason);

  final CloudDriveResumeAction action;
  final String reason;
}

class ParsedContentRange {
  const ParsedContentRange({this.start, this.end, this.total});

  final int? start;
  final int? end;
  final int? total;
}

/// Parses `bytes START-END/TOTAL` and the 416 form `bytes */TOTAL`.
ParsedContentRange? parseContentRange(String? header) {
  if (header == null || header.isEmpty) return null;
  final full = RegExp(
    r'bytes\s+(\d+)-(\d+)/(\d+|\*)',
    caseSensitive: false,
  ).firstMatch(header);
  if (full != null) {
    return ParsedContentRange(
      start: int.parse(full.group(1)!),
      end: int.parse(full.group(2)!),
      total: full.group(3) == '*' ? null : int.parse(full.group(3)!),
    );
  }
  final unsatisfied = RegExp(
    r'bytes\s+\*/(\d+)',
    caseSensitive: false,
  ).firstMatch(header);
  if (unsatisfied == null) return null;
  return ParsedContentRange(total: int.parse(unsatisfied.group(1)!));
}

String? normalizeEntityTag(String? value) {
  if (value == null) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  if (text.toLowerCase().startsWith('w/')) text = text.substring(2).trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1);
  }
  return text.isEmpty ? null : text;
}

/// RFC 9110 range resume. A 200 is never appended onto a partial file.
CloudDriveResumeDecision decideCloudDriveResume({
  required int localBytes,
  required int statusCode,
  required int? contentRangeStart,
  required int? contentRangeTotal,
  String? responseEtag,
  String? expectedEtag,
  String? responseRevision,
  String? expectedRevision,
  String? contentEncoding,
}) {
  if (expectedRevision != null &&
      responseRevision != null &&
      expectedRevision != responseRevision) {
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.replace,
      'revision changed',
    );
  }
  final gotTag = normalizeEntityTag(responseEtag);
  final wantTag = normalizeEntityTag(expectedEtag);
  if (wantTag != null && gotTag != null && wantTag != gotTag) {
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.replace,
      'etag changed',
    );
  }
  final encoding = contentEncoding?.trim().toLowerCase();
  if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.replace,
      'encoded body cannot be appended',
    );
  }
  if (statusCode == 206) {
    if (contentRangeStart == null || contentRangeStart != localBytes) {
      return const CloudDriveResumeDecision(
        CloudDriveResumeAction.replace,
        'range start does not match local bytes',
      );
    }
    if (contentRangeTotal != null && localBytes > contentRangeTotal) {
      return const CloudDriveResumeDecision(
        CloudDriveResumeAction.replace,
        'local file is longer than the resource',
      );
    }
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.append,
      'partial content continues the local file',
    );
  }
  if (statusCode == 200) {
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.replace,
      'server ignored the range',
    );
  }
  if (statusCode == 416) {
    if (contentRangeTotal != null && localBytes == contentRangeTotal) {
      return const CloudDriveResumeDecision(
        CloudDriveResumeAction.complete,
        'local file already has the full length',
      );
    }
    return const CloudDriveResumeDecision(
      CloudDriveResumeAction.replace,
      'range was not satisfiable',
    );
  }
  return CloudDriveResumeDecision(
    CloudDriveResumeAction.replace,
    'unexpected status $statusCode',
  );
}
