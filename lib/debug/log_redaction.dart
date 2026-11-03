/// Masks login secrets and device ids (Bilibili cookies and tokens) before
/// text reaches the in-app debug console or the VM service log.
///
/// Covers `name=value` (cookie headers, query strings) and JSON-style
/// `"name": "value"` forms.
library;

const List<String> _sensitiveNames = <String>[
  'SESSDATA',
  'bili_jct',
  'DedeUserID__ckMd5',
  'DedeUserID',
  'sid',
  'refresh_token',
  'access_token',
  'access_key',
  'api_key',
  'apiKey',
  'client_secret',
  'password',
  'proxy_password',
  'BDUSS',
  'STOKEN',
  '__puus',
  '__pus',
  '__kps',
  '__ktd',
  '__uid',
  'csrf_token',
  'csrf',
  'buvid3',
  'buvid4',
  '_uuid',
  'b_nut',
  'bili_ticket_expires',
  'bili_ticket',
  'buvid_fp_plain',
  'buvid_fp',
  'fingerprint',
];

final RegExp _assignment = RegExp(
  '\\b(${_sensitiveNames.join('|')})=([^;&\\s"\',]+)',
  caseSensitive: false,
);

final RegExp _jsonField = RegExp(
  '(["\'](?:${_sensitiveNames.join('|')})["\']\\s*:\\s*["\'])([^"\']*)(["\'])',
  caseSensitive: false,
);

final RegExp _authorization = RegExp(
  r'\b((?:proxy-)?authorization["\x27]?\s*[:=]\s*["\x27]?(?:Bearer|Basic)\s+)[^\s,"\x27}]+',
  caseSensitive: false,
);

String redactSensitiveLogText(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAllMapped(_assignment, (m) => '${m[1]}=***');
  out = out.replaceAllMapped(_jsonField, (m) => '${m[1]}***${m[3]}');
  out = out.replaceAllMapped(_authorization, (m) => '${m[1]}***');
  return out;
}
