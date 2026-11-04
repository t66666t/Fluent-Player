/// File identities and preprocessing contracts shared by the app and its
/// standalone OCR helper. Keep this type free of Flutter dependencies.
class OcrModelFiles {
  const OcrModelFiles({
    required this.detection,
    required this.recognition,
    required this.dictionary,
    this.detectionConfig,
    this.identity = '',
    this.legacy = true,
    this.acceleratorContract,
  });
  final String detection, recognition, dictionary, identity;
  final String? detectionConfig;
  final bool legacy;
  final String? acceleratorContract;
  Map<String, Object?> toMessage() => {
    'detection': detection,
    'recognition': recognition,
    'dictionary': dictionary,
    'detectionConfig': detectionConfig,
    'identity': identity,
    'legacy': legacy,
    if (acceleratorContract != null) 'acceleratorContract': acceleratorContract,
  };
  factory OcrModelFiles.fromMessage(Map<Object?, Object?> m) => OcrModelFiles(
    detection: m['detection']! as String,
    recognition: m['recognition']! as String,
    dictionary: m['dictionary']! as String,
    detectionConfig: m['detectionConfig'] as String?,
    identity: m['identity'] as String? ?? '',
    legacy: m['legacy'] != false,
    acceleratorContract: m['acceleratorContract'] as String?,
  );
}
