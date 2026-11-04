class YtDlpVersions {
  static const String androidBundled = '2026.10.21';
  static const String windowsBundled = '2026.10.21';
  static const String macosBundled = '2026.10.21';
  static const String linuxBundled = '2026.10.21';

  const YtDlpVersions._();

  static int compare(String left, String right) {
    List<int>? parse(String value) {
      final normalized = value.trim().replaceFirst(
        RegExp(r'^v', caseSensitive: false),
        '',
      );
      final parts = normalized.split('.');
      if (parts.isEmpty) {
        return null;
      }
      final numbers = <int>[];
      for (final part in parts) {
        final number = int.tryParse(part);
        if (number == null) {
          return null;
        }
        numbers.add(number);
      }
      return numbers;
    }

    final leftParts = parse(left);
    final rightParts = parse(right);
    if (leftParts == null || rightParts == null) {
      return left.trim().compareTo(right.trim());
    }
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final leftPart = index < leftParts.length ? leftParts[index] : 0;
      final rightPart = index < rightParts.length ? rightParts[index] : 0;
      final comparison = leftPart.compareTo(rightPart);
      if (comparison != 0) {
        return comparison;
      }
    }
    return 0;
  }

  static String normalize(String? version) {
    return version?.trim().replaceFirst(
          RegExp(r'^v', caseSensitive: false),
          '',
        ) ??
        '';
  }

  static String? extractStableVersion(String? value) {
    if (value == null) {
      return null;
    }
    return RegExp(r'\d{4}\.\d{1,2}\.\d{1,2}').firstMatch(value)?.group(0);
  }

  static bool shouldReplaceInstalledStable({
    required String? installedVersionStamp,
    required String bundledVersionStamp,
  }) {
    final installed = extractStableVersion(installedVersionStamp);
    final bundled = extractStableVersion(bundledVersionStamp);
    return installed != null &&
        bundled != null &&
        compare(installed, bundled) < 0;
  }

  static String latestStableLabel(
    String version, {
    required bool supportsOnlineUpdate,
  }) {
    return supportsOnlineUpdate ? version : '$version（当前平台不支持在线更新）';
  }
}
