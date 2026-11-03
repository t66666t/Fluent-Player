import 'dart:convert';
import 'package:crypto/crypto.dart';

class WbiSigner {
  static const List<int> _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13
  ];

  /// Get the mixin key from the imgKey and subKey
  static String getMixinKey(String orig) {
    String temp = '';
    for (int i = 0; i < _mixinKeyEncTab.length; i++) {
      if (_mixinKeyEncTab[i] < orig.length) {
        temp += orig[_mixinKeyEncTab[i]];
      }
    }
    return temp.substring(0, 32);
  }

  /// Sign the parameters
  static Map<String, dynamic> sign(
      Map<String, dynamic> params, String imgKey, String subKey) {
    final mixinKey = getMixinKey(imgKey + subKey);
    final currTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    
    final newParams = Map<String, dynamic>.from(params);
    newParams['wts'] = currTime;

    // Sort keys
    final sortedKeys = newParams.keys.toList()..sort();
    
    String query = '';
    for (final key in sortedKeys) {
      final value = newParams[key];
      // Filter reserved characters
      final safeValue = value.toString().replaceAll(RegExp(r"[!'()*]"), "");
      // The server signs the filtered value, so send that same value.
      if (safeValue != value.toString()) newParams[key] = safeValue;
      if (query.isNotEmpty) {
        query += '&';
      }
      // Percent-encoded like the web client; plain ASCII ids are unchanged.
      query += '${Uri.encodeComponent(key)}=${Uri.encodeComponent(safeValue)}';
    }

    final wbiSign = md5.convert(utf8.encode(query + mixinKey)).toString();
    newParams['w_rid'] = wbiSign;

    return newParams;
  }
}
