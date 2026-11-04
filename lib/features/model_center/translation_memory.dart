/// Budget for the pinned GGUF translator with a 4096-token context. CPU
/// inference maps one copy of the weights; KV cache and compute buffers need
/// additional space. GPU loading can temporarily keep a second weight copy.
/// This is an admission estimate, not a measurement of the model's RSS.
int translationAllocationBytes(int modelBytes, {bool gpu = false}) =>
    modelBytes <= 0 ? 0 : modelBytes * (gpu ? 2 : 1) + 1073741824;
