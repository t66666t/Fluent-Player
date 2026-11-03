// Private, version-pinned ASR accelerator. Desktop inference lives in this
// process; Android loads it in :asr_accel, never in the Flutter player process.
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include "json.hpp"
#include "onnxruntime_cxx_api.h"
#include "sherpa-onnx/c-api/c-api.h"
#include "fluent_asr_observer.h"
#include "mnn_session.h"
#include "firered_ctc.h"
#ifdef _WIN32
#include <windows.h>
#include <dxgi1_4.h>
#include <d3d12.h>
#include <wrl/client.h>
#else
#include <dlfcn.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#ifdef __ANDROID__
#include <android/api-level.h>
#include <android/NeuralNetworksTypes.h>
#include <jni.h>
#endif

using Json = nlohmann::json;
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
#ifndef FLUENT_ASR_BUILD_ID
#define FLUENT_ASR_BUILD_ID "unverified-build"
#endif
static long long Milliseconds(Clock::time_point at) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - at).count();
}
static fs::path Path(const std::string &s) { return fs::u8path(s); }
static Json Capabilities(const Json& request = Json::object()) {
  Json devices = Json::array();
  const auto probing = request.value("probeBackend", request.value("backend", "system"));
  const bool system_probe = !fluent_asr::MnnBackend(probing);
#ifdef _WIN32
  // ORT's NuGet declares this redistributable dependency separately. Keep it
  // private and pinned instead of depending on the system DirectML version.
  if (system_probe) {
  static HMODULE directml = [] {
    wchar_t executable[32768]{};
    if (!GetModuleFileNameW(nullptr, executable, 32768)) return HMODULE(nullptr);
    auto file = fs::path(executable).parent_path() / L"DirectML.dll";
    return LoadLibraryExW(file.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  }();
  if (!directml) throw std::runtime_error("Matching private DirectML 1.15.4 component unavailable");
  }
#endif
  auto providers = Ort::GetAvailableProviders();
  auto has = [&](const char *name) {
    return std::find(providers.begin(), providers.end(), name) != providers.end();
  };
  std::string runtime = std::string("sherpa-1.12.12-fluent-") + FLUENT_ASR_BUILD_ID +
    "/ort-" + OrtGetApiBase()->GetVersionString();
#ifdef _WIN32
  runtime += "/dml-1.15.4";
  if (system_probe && has("DmlExecutionProvider")) {
    Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
      for (UINT i = 0;; ++i) {
        Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 info{};
        if (FAILED(adapter->GetDesc1(&info)) || info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
        if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device), nullptr))) continue;
        int bytes = WideCharToMultiByte(CP_UTF8, 0, info.Description, -1, nullptr, 0, nullptr, nullptr);
        std::string name(bytes, '\0');
        WideCharToMultiByte(CP_UTF8, 0, info.Description, -1, name.data(), bytes, nullptr, nullptr);
        if (!name.empty()) name.pop_back();
        LARGE_INTEGER version{};
        adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice), &version);
        auto fingerprint = std::to_string(info.VendorId) + ":" + std::to_string(info.DeviceId) +
          ":" + std::to_string(info.SubSysId) + ":" + std::to_string(info.Revision) + ":" + std::to_string(i) +
          ":" + std::to_string(version.QuadPart);
        devices.push_back({{"backend", "directml"}, {"device", i}, {"label", "GPU · DirectML"},
          {"name", name}, {"fingerprint", fingerprint}, {"runtime", runtime},
          {"dedicatedMemory", info.DedicatedVideoMemory}});
      }
    }
  }
#elif defined(__ANDROID__)
  if (system_probe && android_get_device_api_level() >= 29 && has("NnapiExecutionProvider")) {
    void *lib = dlopen("libneuralnetworks.so", RTLD_NOW | RTLD_LOCAL);
    if (lib) {
      using Count = int (*)(uint32_t *);
      using Get = int (*)(uint32_t, void **);
      using Type = int (*)(const void *, int32_t *);
      using Name = int (*)(const void *, const char **);
      auto count = reinterpret_cast<Count>(dlsym(lib, "ANeuralNetworks_getDeviceCount"));
      auto get = reinterpret_cast<Get>(dlsym(lib, "ANeuralNetworks_getDevice"));
      auto type = reinterpret_cast<Type>(dlsym(lib, "ANeuralNetworksDevice_getType"));
      auto name = reinterpret_cast<Name>(dlsym(lib, "ANeuralNetworksDevice_getName"));
      auto version = reinterpret_cast<Name>(dlsym(lib, "ANeuralNetworksDevice_getVersion"));
      uint32_t n = 0;
      if (count && get && type && name && version && count(&n) == 0) {
        std::string fingerprint;
        for (uint32_t i = 0; i < n; ++i) {
          void *device = nullptr; int32_t kind = 0;
          const char *description = nullptr, *driver = nullptr;
          if (get(i, &device) == 0 && type(device, &kind) == 0 &&
              (kind == ANEURALNETWORKS_DEVICE_GPU || kind == ANEURALNETWORKS_DEVICE_ACCELERATOR) &&
              name(device, &description) == 0 && version(device, &driver) == 0 && description && driver) {
            fingerprint += std::string(description) + ":" + driver + ";";
          }
        }
        if (!fingerprint.empty()) devices.push_back({{"backend", "nnapi"}, {"device", 0},
          {"label", "GPU/NPU · NNAPI"}, {"fingerprint", fingerprint}, {"runtime", runtime}});
      }
      dlclose(lib);
    }
  }
#elif defined(__APPLE__)
  // iOS is additionally gated by the signed application's validation manifest.
  char hardware[256]{};
  size_t hardware_size = sizeof(hardware);
  const char *hardware_key =
#ifdef FLUENT_ASR_IOS
    "hw.machine";
#else
    "hw.model";
#endif
  if (sysctlbyname(hardware_key, hardware, &hardware_size, nullptr, 0) != 0)
    throw std::runtime_error("Cannot identify Apple hardware");
  if (system_probe && has("CoreMLExecutionProvider")) devices.push_back({{"backend", "coreml"}, {"device", 0},
    {"label", "GPU/NPU · CoreML"}, {"fingerprint", std::string("coreml:") + hardware}, {"runtime", runtime}});
#else
  if (system_probe && has("CUDAExecutionProvider")) {
    void *lib = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (lib) {
      auto init = reinterpret_cast<int (*)(unsigned)>(dlsym(lib, "cuInit"));
      auto count = reinterpret_cast<int (*)(int *)>(dlsym(lib, "cuDeviceGetCount"));
      auto name = reinterpret_cast<int (*)(char *, int, int)>(dlsym(lib, "cuDeviceGetName"));
      auto driver = reinterpret_cast<int (*)(int *)>(dlsym(lib, "cuDriverGetVersion"));
      int n = 0, version = 0;
      std::ifstream version_file("/proc/driver/nvidia/version");
      std::string driver_text((std::istreambuf_iterator<char>(version_file)), std::istreambuf_iterator<char>());
      if (init && count && name && driver && init(0) == 0 && count(&n) == 0 && driver(&version) == 0) {
        for (int i = 0; i < n; ++i) {
          char description[256]{};
          if (name(description, sizeof(description), i) == 0) devices.push_back({{"backend", "cuda"},
            {"device", i}, {"label", "GPU · CUDA"}, {"name", description},
            {"fingerprint", std::string(description) + ":" + std::to_string(i) + ":" + std::to_string(version) + ":" + driver_text},
            {"runtime", runtime}});
        }
      }
      dlclose(lib);
    }
  }
#endif
  Json optional = Json::array();
  auto* mnn = fluent_asr::MnnApi::instance();
  const auto id = request.value("modelId", "");
  if (mnn && (id.empty() || fluent_asr::MnnModelSupported(id))) {
    runtime += std::string("/") + mnn->version();
#ifdef __APPLE__
    const std::vector<std::string> routes = {"metal"};
#else
    const std::vector<std::string> routes = {"vulkan", "opencl"};
#endif
    const auto probe = request.value("probeBackend", request.value("backend", "system"));
    for (const auto& route : routes) {
      optional.push_back(route);
      if (probe != route) continue;
      const int kind = fluent_asr::MnnBackend(route);
      if (mnn->probe(kind)) devices.push_back({{"backend", route}, {"device", 0},
        {"label", route == "metal" ? "GPU · Metal" : route == "vulkan" ? "GPU · Vulkan" : "GPU · OpenCL"},
        {"name", mnn->device(kind)}, {"fingerprint", std::string(mnn->device(kind)) + ":" + mnn->version()},
        {"runtime", runtime}, {"requiresFloatWeights", true}});
    }
  }
  if (id == "whisper-large-v3-turbo-int8" || id == "firered-asr2-ctc-int8") {
    for (auto& device : devices) device["requiresFloatWeights"] = true;
  }
  return {{"devices", devices}, {"runtime", runtime}, {"optionalBackends", optional},
    {"reason", devices.empty() ? "No verified hardware execution provider in this runtime" : ""}};
}

class Decoder {
 public:
  ~Decoder() {
    Clear();
    if (!profile_.empty()) { std::error_code ignored; fs::remove_all(profile_, ignored); }
  }
  void Clear() {
    if (offline_) SherpaOnnxDestroyOfflineRecognizer(offline_);
    if (online_) SherpaOnnxDestroyOnlineRecognizer(online_);
    offline_ = nullptr; online_ = nullptr;
    firered_.reset();
  }
  void Load(const Json &request) {
    Clear(); config_ = request; accelerated_nodes_ = 0; needs_probe_ = true;
    const auto backend = request.value("backend", "");
    const auto engine = request.value("engine", "");
    const bool native_cpu = backend == "cpu" && (engine == "firered2" || engine == "whisper");
    if (!native_cpu && backend != "directml" && backend != "cuda" && backend != "nnapi" && backend != "coreml" && !fluent_asr::MnnBackend(backend))
      throw std::runtime_error("Explicit GPU provider required");
    if (!native_cpu && (request.value("engine", "") == "firered2" || request.value("engine", "") == "whisper") &&
        !request.value("floatWeights", false)) throw std::runtime_error("This architecture requires its FP32 GPU pack");
    if (fluent_asr::MnnBackend(backend) && (!fluent_asr::MnnModelSupported(request.value("modelId", "")) ||
        !request.value("floatWeights", false))) throw std::runtime_error("This ASR GPU route needs its registered FP32 acceleration pack");
    if (!native_cpu) {
      const auto capabilities = Capabilities(request);
      bool found = false;
      for (const auto &item : capabilities["devices"]) {
        if (item["backend"] == backend && item["device"] == request.value("device", 0)) found = true;
      }
      if (!found) throw std::runtime_error("GPU device/provider unavailable");
    }
    needs_probe_ = !native_cpu;
    auto root = Path(request.at("profileRoot").get<std::string>());
    fs::create_directories(root);
    profile_ = root / ("asr-profile-" + std::to_string(Clock::now().time_since_epoch().count()));
    fs::create_directory(profile_);
    auto cache_root = Path(request.value("cacheRoot", request.at("profileRoot").get<std::string>()));
    auto cache_identity = request.value("directory", "") + request.value("backend", "") +
      OrtGetApiBase()->GetVersionString() + request.value("cacheSignature", "");
    const bool mnn_route = fluent_asr::MnnBackend(backend) != 0;
    if (mnn_route) cache_identity = request.value("directory", "") + request.value("weightsIdentity", "") +
      fluent_asr::MnnApi::instance()->version();
    auto cache = cache_root / (mnn_route ? "asr-mnn-cache" : "asr-coreml-cache") / request.value("modelId", "model") /
      std::to_string(std::hash<std::string>{}(cache_identity));
    if (backend == "coreml" || fluent_asr::MnnBackend(backend)) {
      fs::create_directories(cache);
      cache_ = cache.u8string();
    } else cache_.clear();
    SetContext();
    Create();
  }
  Json Decode(const std::string &filename) {
    SetContext();
    if (!offline_ && !online_ && !firered_) throw std::runtime_error("ASR model not loaded");
    std::ifstream input(Path(filename), std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("PCM input unavailable");
    const auto size = input.tellg();
    if (size <= 0 || size > 16000LL * 4 * 30 || size % 4 != 0)
      throw std::runtime_error("PCM segment must contain at most 30 seconds of float32 audio");
    std::vector<float> samples(static_cast<size_t>(size) / sizeof(float));
    input.seekg(0); input.read(reinterpret_cast<char *>(samples.data()), size);
    if (!input) throw std::runtime_error("PCM input incomplete");
    Json result;
    if (firered_) {
      result = Json::parse(firered_->Decode(samples).AsJsonString());
    } else if (offline_) {
      auto stream = SherpaOnnxCreateOfflineStream(offline_);
      if (!stream) throw std::runtime_error("Cannot create offline stream");
      try {
        SherpaOnnxAcceptWaveformOffline(stream, 16000, samples.data(), static_cast<int>(samples.size()));
        SherpaOnnxDecodeOfflineStream(offline_, stream);
        const char *text = SherpaOnnxGetOfflineStreamResultAsJson(stream);
        if (!text) throw std::runtime_error("No offline result");
        try { result = Json::parse(text); } catch (...) { SherpaOnnxDestroyOfflineStreamResultJson(text); throw; }
        SherpaOnnxDestroyOfflineStreamResultJson(text);
      } catch (...) { SherpaOnnxDestroyOfflineStream(stream); throw; }
      SherpaOnnxDestroyOfflineStream(stream);
    } else {
      auto stream = SherpaOnnxCreateOnlineStream(online_);
      if (!stream) throw std::runtime_error("Cannot create online stream");
      try {
        auto drain = [&] {
          while (SherpaOnnxIsOnlineStreamReady(online_, stream)) SherpaOnnxDecodeOnlineStream(online_, stream);
        };
        for (size_t at = 0; at < samples.size(); at += 5120) {
          SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples.data() + at,
            static_cast<int>(std::min<size_t>(5120, samples.size() - at)));
          drain();
        }
        std::vector<float> tail(4800);
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, tail.data(), static_cast<int>(tail.size()));
        SherpaOnnxOnlineStreamInputFinished(stream); drain();
        const char *text = SherpaOnnxGetOnlineStreamResultAsJson(online_, stream);
        if (!text) throw std::runtime_error("No online result");
        try { result = Json::parse(text); } catch (...) { SherpaOnnxDestroyOnlineStreamResultJson(text); throw; }
        SherpaOnnxDestroyOnlineStreamResultJson(text);
      } catch (...) { SherpaOnnxDestroyOnlineStream(stream); throw; }
      SherpaOnnxDestroyOnlineStream(stream);
    }
    if (needs_probe_ && fluent_asr::MnnBackend(config_.value("backend", ""))) {
      accelerated_nodes_ = fluent_asr::mnn_executed;
      if (!accelerated_nodes_) throw std::runtime_error("ASR graph executed no verified GPU kernels");
      needs_probe_ = false;
    } else if (needs_probe_) {
      // Session destruction flushes ORT profiles. Prove actual EP assignment
      // once, then recreate the retained session without profiling overhead.
      Clear();
      const auto backend = config_.value("backend", "");
      const std::string expected = backend == "directml" ? "DmlExecutionProvider" :
        backend == "cuda" ? "CUDAExecutionProvider" : backend == "coreml" ?
        "CoreMLExecutionProvider" : "NnapiExecutionProvider";
      for (const auto &file : fs::directory_iterator(profile_)) {
        if (file.path().extension() != ".json") continue;
        std::ifstream trace(file.path());
        const auto events = Json::parse(trace);
        for (const auto &event : events) {
          if (event.contains("args") && event["args"].is_object() &&
              event["args"].value("provider", "") == expected) ++accelerated_nodes_;
        }
      }
      fs::remove_all(profile_);
      needs_probe_ = false;
      SetContext();
      if (!accelerated_nodes_) throw std::runtime_error("GPU provider accepted zero ASR kernels; CPU fallback required");
      Create();
    }
    return {{"result", result}, {"acceleratedNodes", accelerated_nodes_}};
  }

 private:
  void SetContext() {
    fluent_asr::cache = cache_;
    fluent_asr::model_directory = config_.value("directory", "");
    fluent_asr::profile = profile_;
    fluent_asr::device = config_.value("device", 0);
    fluent_asr::profiling = needs_probe_;
    fluent_asr::mnn_backend = fluent_asr::MnnBackend(config_.value("backend", ""));
    fluent_asr::mnn_executed = 0;
  }
  void Create() {
    if (std::getenv("FLUENT_ASR_NATIVE_DEBUG")) std::cerr << "ASR recognizer configuration\n";
    const auto directory = Path(config_.at("directory").get<std::string>());
    auto path = [&](const char *name) { return (directory / name).u8string(); };
    const bool floating = config_.value("floatWeights", false);
    const auto tokens = path("tokens.txt"), model = path(floating ? "model.onnx" : "model.int8.onnx"),
      encoder = path(floating ? "encoder.onnx" : "encoder.int8.onnx"),
      decoder = path(floating ? "decoder.onnx" : "decoder.int8.onnx"),
      joiner = path(floating ? "joiner.onnx" : "joiner.int8.onnx"), bpe = path("bpe.vocab");
    const auto engine = config_.value("engine", ""), backend = config_.value("backend", ""),
      language = config_.value("language", "auto"), hotwords = config_.value("hotwordsFile", "");
    const char *method = hotwords.empty() ? "greedy_search" : "modified_beam_search";
    int threads = std::clamp(config_.value("threads", 2), 1, 12);
    if (engine == "firered2") {
      firered_ = std::make_unique<fluent_asr::FireRedCtc>(directory, floating, backend, threads);
    } else if (engine == "zipformer") {
      SherpaOnnxOnlineRecognizerConfig c{};
      c.feat_config.sample_rate = 16000; c.feat_config.feature_dim = 80;
      c.model_config.transducer = {encoder.c_str(), decoder.c_str(), joiner.c_str()};
      c.model_config.tokens = tokens.c_str(); c.model_config.num_threads = threads;
      c.model_config.provider = backend.c_str();
      c.model_config.debug = std::getenv("FLUENT_ASR_NATIVE_DEBUG") ? 1 : 0;
      c.model_config.modeling_unit = "cjkchar+bpe"; c.model_config.bpe_vocab = bpe.c_str();
      c.decoding_method = method; c.max_active_paths = 4;
      c.hotwords_file = hotwords.c_str(); c.hotwords_score = 1.5;
      online_ = SherpaOnnxCreateOnlineRecognizer(&c);
      if (!online_) throw std::runtime_error("Cannot load streaming ASR model");
    } else {
      SherpaOnnxOfflineRecognizerConfig c{};
      c.feat_config.sample_rate = 16000; c.feat_config.feature_dim = 80;
      c.model_config.tokens = tokens.c_str(); c.model_config.num_threads = threads;
      c.model_config.provider = backend.c_str();
      c.model_config.debug = std::getenv("FLUENT_ASR_NATIVE_DEBUG") ? 1 : 0;
      if (engine == "sensevoice") c.model_config.sense_voice = {model.c_str(), language.c_str(), 1};
      else if (engine == "dolphin") c.model_config.dolphin.model = model.c_str();
      else if (engine == "parakeet") {
        c.model_config.transducer = {encoder.c_str(), decoder.c_str(), joiner.c_str()};
        c.model_config.model_type = "nemo_transducer";
      } else if (engine == "whisper") {
        const auto whisper_tokens = path("turbo-tokens.txt");
        const auto whisper_encoder = path(floating ? "turbo-encoder.onnx" : "turbo-encoder.int8.onnx");
        const auto whisper_decoder = path(floating ? "turbo-decoder.onnx" : "turbo-decoder.int8.onnx");
        c.model_config.tokens = whisper_tokens.c_str();
        c.model_config.whisper.encoder = whisper_encoder.c_str();
        c.model_config.whisper.decoder = whisper_decoder.c_str();
        c.model_config.whisper.language = language == "auto" ? "" : language.c_str();
        c.model_config.whisper.task = "transcribe";
        c.model_config.whisper.tail_paddings = -1;
        c.decoding_method = "greedy_search"; c.max_active_paths = 4;
        offline_ = SherpaOnnxCreateOfflineRecognizer(&c);
        if (!offline_) throw std::runtime_error("Cannot load Whisper Turbo model");
        return;
      } else throw std::runtime_error("Unknown ASR model engine");
      c.decoding_method = method; c.max_active_paths = 4;
      offline_ = SherpaOnnxCreateOfflineRecognizer(&c);
      if (!offline_) throw std::runtime_error("Cannot load offline ASR model");
    }
  }
  Json config_;
  fs::path profile_;
  std::string cache_;
  bool needs_probe_ = true;
  const SherpaOnnxOfflineRecognizer *offline_ = nullptr;
  const SherpaOnnxOnlineRecognizer *online_ = nullptr;
  std::unique_ptr<fluent_asr::FireRedCtc> firered_;
  int accelerated_nodes_ = 0;
};

static std::mutex request_mutex;
static std::unique_ptr<Decoder> decoder;
static Json Request(const Json &request) {
  const auto op = request.value("op", "");
  if (op == "open") return Json::object();
  if (op == "capabilities") return Capabilities(request);
  if (op == "unload" || op == "close") { decoder.reset(); return Json::object(); }
  if (op == "load") {
    decoder = std::make_unique<Decoder>();
    auto at = Clock::now(); decoder->Load(request);
    return {{"loadMs", Milliseconds(at)}};
  }
  if (op == "decode") {
    if (!decoder) throw std::runtime_error("ASR session unavailable");
    return decoder->Decode(request.at("path").get<std::string>());
  }
  throw std::runtime_error("Unknown ASR request");
}

#ifdef _WIN32
#define FLUENT_EXPORT __declspec(dllexport)
#else
#define FLUENT_EXPORT __attribute__((visibility("default")))
#endif
extern "C" FLUENT_EXPORT char *FluentAsrRequest(const char *text) {
  std::lock_guard<std::mutex> guard(request_mutex);
  struct ContextGuard {
    ~ContextGuard() {
      fluent_asr::profiling = false; fluent_asr::device = 0;
      fluent_asr::cache.clear(); fluent_asr::model_directory.clear(); fluent_asr::profile.clear();
    }
  } context_guard;
  Json reply;
  int id = 0;
  try {
    const auto input = Json::parse(text);
    id = input.value("id", 0);
    reply = Request(input); reply["ok"] = true;
  } catch (const std::exception &error) {
    decoder.reset();
    reply = {{"ok", false}, {"error", error.what()}};
  } catch (...) {
    decoder.reset(); reply = {{"ok", false}, {"error", "Native ASR failure"}};
  }
  reply["id"] = id;
  const auto result = reply.dump();
  auto output = static_cast<char *>(std::malloc(result.size() + 1));
  if (!output) return nullptr;
  std::memcpy(output, result.c_str(), result.size() + 1);
  return output;
}
extern "C" FLUENT_EXPORT void FluentAsrFree(char *text) { std::free(text); }

#ifdef __ANDROID__
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_example_video_1player_1app_AsrAccelerationService_nativeRequest(
    JNIEnv *env, jobject, jbyteArray input) {
  const auto length = env->GetArrayLength(input);
  std::vector<char> utf8(static_cast<size_t>(length) + 1);
  env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte *>(utf8.data()));
  char *result = FluentAsrRequest(utf8.data());
  const char *text = result ? result : "{\"ok\":false,\"error\":\"Native allocation failure\"}";
  auto output = env->NewByteArray(static_cast<jsize>(std::strlen(text)));
  env->SetByteArrayRegion(output, 0, static_cast<jsize>(std::strlen(text)), reinterpret_cast<const jbyte *>(text));
  FluentAsrFree(result); return output;
}
#elif !defined(FLUENT_ASR_IOS)
int main() {
#ifdef _WIN32
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
#endif
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.size() > 1024 * 1024) return 2;
    char *result = FluentAsrRequest(line.c_str());
    if (!result) return 3;
    std::cout << result << std::endl;
    FluentAsrFree(result);
  }
  decoder.reset();
  return 0;
}
#endif
