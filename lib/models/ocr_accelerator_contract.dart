/// Native compilation of these existing DB + CTC FP32 exports is a cache of
/// their pinned ONNX artifacts, not a replacement weight/model version.
/// Converter: MNN 3.6.1, no weight quantization, approximate GELU or FP16 storage.
/// QNN uses the original ONNX, specializing only named input dimensions.
const ocrAcceleratorContract = 'ppocr-db-ctc-fp32-v1';
const ocrAcceleratorExports = <String>{
  'ocr-v6-tiny-det',
  'ocr-v6-small-det',
  'ocr-v6-medium-det',
  'ocr-v6-small-rec',
  'ocr-v6-medium-rec',
  'ocr-v5-mobile-det',
  'ocr-v5-mobile-rec',
  'ocr-en-v5-mobile-rec',
  'ocr-korean-v5-mobile-rec',
  'ocr-latin-v5-mobile-rec',
};
