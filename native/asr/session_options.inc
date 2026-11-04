// Included into the pinned sherpa session.cc by prepare_asr_native.py.
// This private GPU component never silently accepts a missing execution provider.
#include "fluent_asr_observer.h"
#include <stdexcept>
#include <cstdio>
#include <cstdlib>
#if defined(__ANDROID__)
#include <dlfcn.h>
#endif

namespace sherpa_onnx {
Ort::SessionOptions GetSessionOptionsImpl(
    int32_t threads, const std::string &provider,
    const ProviderConfig *config) {
  Ort::SessionOptions options;
  if (std::getenv("FLUENT_ASR_NATIVE_DEBUG")) std::fprintf(stderr, "ASR session options created\n");
  options.SetIntraOpNumThreads(threads);
  options.SetInterOpNumThreads(1);
  options.SetExecutionMode(ORT_SEQUENTIAL);
  options.AddConfigEntry("session.intra_op.allow_spinning", "0");
  if (!fluent_asr::model_directory.empty()) {
    options.AddConfigEntry("session.model_external_initializers_file_folder_path", fluent_asr::model_directory.c_str());
  }
  auto available = Ort::GetAvailableProviders();
  auto require = [&](const char *name) {
    if (std::find(available.begin(), available.end(), name) == available.end())
      throw std::runtime_error(std::string("Execution provider unavailable: ") + name);
  };
  if (provider == "directml") {
#ifdef _WIN32
    require("DmlExecutionProvider");
    options.DisableMemPattern();
    // The first entry is ABI-stable in the pinned ORT 1.21 DML provider API.
    struct DmlApiPrefix {
      OrtStatus *(ORT_API_CALL *append)(OrtSessionOptions *, int);
    };
    const void *raw = nullptr;
    Ort::ThrowOnError(Ort::GetApi().GetExecutionProviderApi("DML", ORT_API_VERSION, &raw));
    if (std::getenv("FLUENT_ASR_NATIVE_DEBUG")) std::fprintf(stderr, "DML provider API acquired\n");
    if (!raw) throw std::runtime_error("DirectML API missing");
    Ort::ThrowOnError(static_cast<const DmlApiPrefix *>(raw)->append(options, fluent_asr::device));
    if (std::getenv("FLUENT_ASR_NATIVE_DEBUG")) std::fprintf(stderr, "DML provider registered\n");
#else
    throw std::runtime_error("DirectML requires Windows");
#endif
  } else if (provider == "cuda") {
    require("CUDAExecutionProvider");
    OrtCUDAProviderOptions cuda{};
    cuda.device_id = fluent_asr::device;
    cuda.cudnn_conv_algo_search = OrtCudnnConvAlgoSearchHeuristic;
    options.AppendExecutionProvider_CUDA(cuda);
  } else if (provider == "coreml") {
#ifdef __APPLE__
    require("CoreMLExecutionProvider");
    std::unordered_map<std::string, std::string> settings{
      {"ModelFormat", "MLProgram"}, {"MLComputeUnits", "ALL"},
      {"ModelCacheDirectory", fluent_asr::cache},
      {"AllowLowPrecisionAccumulationOnGPU", "0"},
    };
    options.AppendExecutionProvider("CoreML", settings);
#else
    throw std::runtime_error("CoreML requires Apple hardware");
#endif
  } else if (provider == "nnapi") {
#ifdef __ANDROID__
    require("NnapiExecutionProvider");
    using Append = OrtStatus *(*)(OrtSessionOptions *, uint32_t);
    auto append = reinterpret_cast<Append>(dlsym(RTLD_DEFAULT, "OrtSessionOptionsAppendExecutionProvider_Nnapi"));
    if (!append) throw std::runtime_error("NNAPI registration API missing");
    // CPU_DISABLED=4. No FP16 relaxation; keep ORT's optimized CPU fallback.
    Ort::ThrowOnError(append(options, 4));
#else
    throw std::runtime_error("NNAPI requires Android");
#endif
  } else if (provider == "vulkan" || provider == "opencl" || provider == "metal") {
    // Used for metadata only by the private MNN Session adapter. The first
    // Run releases this CPU session, then executes the registered FP32 graph.
    options.SetGraphOptimizationLevel(ORT_DISABLE_ALL);
    options.DisableCpuMemArena();
  } else if (provider != "cpu") {
    throw std::runtime_error("Unsupported acceleration provider");
  }
  if (fluent_asr::profiling) {
    auto name = fluent_asr::profile / ("session-" + std::to_string(++fluent_asr::sequence));
    options.EnableProfiling(name.c_str());
  }
  return options;
}
}  // namespace sherpa_onnx
