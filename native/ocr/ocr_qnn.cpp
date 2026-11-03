#include "ocr_accelerator.h"
#if defined(__ANDROID__)
#include "onnxruntime_c_api.h"
#include <dlfcn.h>
#include <sys/system_properties.h>
#include <cstdlib>
#include <cstring>
#include <map>
#include <algorithm>
#include <cctype>
#include <memory>
#include <mutex>

namespace fluent_ocr {
namespace {
const OrtApi* api = nullptr;
OrtEnv* env = nullptr;
OrtAllocator* allocator = nullptr;
std::string libraryDirectory;
std::once_flag initialized;
void check(OrtStatus* status) {
    if (!status) return;
    const std::string message = api->GetErrorMessage(status);
    api->ReleaseStatus(status);
    throw std::runtime_error(message);
}
void initialize() {
    std::call_once(initialized, [] {
        // Different SONAME from the player's pinned CPU/NNAPI library.
        // All QNN objects and their allocations stay behind this private API.
        void* library = dlopen("libocr_qnn.so", RTLD_NOW | RTLD_LOCAL);
        if (!library) throw std::runtime_error("Private OCR QNN runtime is unavailable");
        auto entry = reinterpret_cast<const OrtApiBase* (*)()>(dlsym(library, "OrtGetApiBase"));
        if (!entry || !(api = entry()->GetApi(14))) throw std::runtime_error("OCR QNN ABI mismatch");
        Dl_info location{};
        if (!dladdr(reinterpret_cast<void*>(entry), &location) || !location.dli_fname)
            throw std::runtime_error("Cannot locate OCR QNN libraries");
        libraryDirectory = location.dli_fname;
        libraryDirectory = libraryDirectory.substr(0, libraryDirectory.find_last_of('/'));
        check(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "fluent-ocr-qnn", &env));
        check(api->GetAllocatorWithDefaultOptions(&allocator));
        const char* previous = std::getenv("ADSP_LIBRARY_PATH");
        const std::string dsp = libraryDirectory + ";" + (previous ? previous :
            "/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/system/lib/rfsa/adsp;/dsp");
        setenv("ADSP_LIBRARY_PATH", dsp.c_str(), 1);
    });
}
class QnnSession final : public Session {
public:
    QnnSession(const char* path, int backend, int threads)
        : path_(path), backend_(backend), threads_(threads) {
        initialize();
        OrtSessionOptions* options = nullptr;
        OrtTypeInfo* type = nullptr;
        check(api->CreateSessionOptions(&options));
        try {
            check(api->SetIntraOpNumThreads(options, 1));
            check(api->SetSessionGraphOptimizationLevel(options, ORT_DISABLE_ALL));
            check(api->CreateSession(env, path, options, &metadataSession_));
            size_t inputCount = 0, outputCount = 0;
            check(api->SessionGetInputCount(metadataSession_, &inputCount));
            check(api->SessionGetOutputCount(metadataSession_, &outputCount));
            if (inputCount != 1 || outputCount != 1) throw std::runtime_error("OCR QNN graph must have one input and output");
            char *in = nullptr, *out = nullptr;
            check(api->SessionGetInputName(metadataSession_, 0, allocator, &in));
            inputName_ = in; check(api->AllocatorFree(allocator, in));
            check(api->SessionGetOutputName(metadataSession_, 0, allocator, &out));
            outputName_ = out; check(api->AllocatorFree(allocator, out));
            check(api->SessionGetInputTypeInfo(metadataSession_, 0, &type));
            const OrtTensorTypeAndShapeInfo* tensor = nullptr;
            check(api->CastTypeInfoToTensorInfo(type, &tensor));
            size_t rank = 0;
            check(api->GetDimensionsCount(tensor, &rank));
            if (rank < 1 || rank > 8) throw std::runtime_error("Invalid OCR QNN input rank");
            std::vector<const char*> symbols(rank);
            dimensions_.resize(rank);
            check(api->GetSymbolicDimensions(tensor, symbols.data(), rank));
            check(api->GetDimensions(tensor, dimensions_.data(), rank));
            for (const char* symbol : symbols) symbols_.emplace_back(symbol ? symbol : "");
            api->ReleaseTypeInfo(type); type = nullptr;
            // Keep metadata only; retaining this CPU session would duplicate
            // every model's weights beside its QNN graph for the entire task.
            api->ReleaseSession(metadataSession_); metadataSession_ = nullptr;
        } catch (...) {
            if (type) api->ReleaseTypeInfo(type);
            api->ReleaseSessionOptions(options);
            if (metadataSession_) api->ReleaseSession(metadataSession_);
            metadataSession_ = nullptr;
            throw;
        }
        api->ReleaseSessionOptions(options);
    }
    ~QnnSession() override {
        if (session_) api->ReleaseSession(session_);
        if (metadataSession_) api->ReleaseSession(metadataSession_);
    }
    Result* run(const float* data, const int64_t* shape, int rank) override {
        const size_t n = elements(shape, rank, 64 * 1024 * 1024 / sizeof(float));
        if (!data) throw std::runtime_error("Missing OCR QNN input");
        if (std::vector<int64_t>(shape, shape + rank) != shape_) specialize(shape, rank);
        OrtMemoryInfo* memory = nullptr;
        OrtValue *input = nullptr, *output = nullptr;
        OrtTensorTypeAndShapeInfo* info = nullptr;
        try {
            check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
            check(api->CreateTensorWithDataAsOrtValue(memory, const_cast<float*>(data), n * sizeof(float),
                shape, rank, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input));
            const char *in = inputName_.c_str(), *out = outputName_.c_str();
            check(api->Run(session_, nullptr, &in, &input, 1, &out, 1, &output));
            check(api->GetTensorTypeAndShape(output, &info));
            size_t outputRank = 0;
            check(api->GetDimensionsCount(info, &outputRank));
            if (outputRank < 1 || outputRank > 8) throw std::runtime_error("Invalid OCR QNN output rank");
            std::unique_ptr<Result> result(new Result);
            result->shape.resize(outputRank);
            check(api->GetDimensions(info, result->shape.data(), outputRank));
            const auto count = elements(result->shape.data(), int(outputRank), kMaxOutputBytes / sizeof(float));
            ONNXTensorElementDataType type;
            check(api->GetTensorElementType(info, &type));
            if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) throw std::runtime_error("OCR QNN output must be float32");
            void* values = nullptr;
            check(api->GetTensorMutableData(output, &values));
            result->data.assign(static_cast<float*>(values), static_cast<float*>(values) + count);
            api->ReleaseTensorTypeAndShapeInfo(info); info = nullptr;
            api->ReleaseValue(output); output = nullptr;
            api->ReleaseValue(input); input = nullptr;
            api->ReleaseMemoryInfo(memory); memory = nullptr;
            return result.release();
        } catch (...) {
            if (info) api->ReleaseTensorTypeAndShapeInfo(info);
            if (output) api->ReleaseValue(output);
            if (input) api->ReleaseValue(input);
            if (memory) api->ReleaseMemoryInfo(memory);
            throw;
        }
    }
private:
    void specialize(const int64_t* shape, int rank) {
        // Keep at most one shape per component. Changing a crop/batch releases
        // its former graph before compiling another, bounding HTP/GPU memory.
        if (session_) { api->ReleaseSession(session_); session_ = nullptr; }
        OrtSessionOptions* options = nullptr;
        check(api->CreateSessionOptions(&options));
        try {
            check(api->SetIntraOpNumThreads(options, threads_));
            check(api->SetInterOpNumThreads(options, 1));
            check(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
            check(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL));
            check(api->AddSessionConfigEntry(options, "session.intra_op.allow_spinning", "0"));
            check(api->AddSessionConfigEntry(options, "session.inter_op.allow_spinning", "0"));
            // A successful session must execute with QNN, never silently CPU.
            check(api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"));
            if (int(dimensions_.size()) != rank) throw std::runtime_error("OCR QNN input rank mismatch");
            std::map<std::string, int64_t> overrides;
            for (int i = 0; i < rank; ++i) {
                if (dimensions_[i] > 0) {
                    if (dimensions_[i] != shape[i]) throw std::runtime_error("OCR QNN fixed input mismatch");
                } else {
                    if (symbols_[i].empty()) throw std::runtime_error("OCR QNN needs named dynamic input dimensions");
                    const auto found = overrides.find(symbols_[i]);
                    if (found != overrides.end() && found->second != shape[i])
                        throw std::runtime_error("Conflicting OCR QNN shape symbols");
                    overrides[symbols_[i]] = shape[i];
                }
            }
            for (const auto& entry : overrides)
                check(api->AddFreeDimensionOverrideByName(options, entry.first.c_str(), entry.second));
            const std::string backend = libraryDirectory + (backend_ == 100 ? "/libQnnGpu.so" : "/libQnnHtp.so");
            std::vector<const char*> keys = {"backend_path", "qnn_context_priority"};
            std::vector<const char*> values = {backend.c_str(), "normal"};
            if (backend_ == 101) {
                keys.insert(keys.end(), {"enable_htp_fp16_precision", "htp_performance_mode", "htp_graph_finalization_optimization_mode"});
                values.insert(values.end(), {"1", "balanced", "1"});
            }
            check(api->SessionOptionsAppendExecutionProvider(options, "QNN", keys.data(), values.data(), keys.size()));
            check(api->CreateSession(env, path_.c_str(), options, &session_));
            shape_.assign(shape, shape + rank);
            api->ReleaseSessionOptions(options);
        } catch (...) {
            api->ReleaseSessionOptions(options);
            throw;
        }
    }
    std::string path_, inputName_, outputName_;
    int backend_, threads_;
    OrtSession *metadataSession_ = nullptr, *session_ = nullptr;
    std::vector<int64_t> shape_;
    std::vector<int64_t> dimensions_;
    std::vector<std::string> symbols_;
};
}
bool probeQnn(int backend) {
    char manufacturer[PROP_VALUE_MAX] = {};
    __system_property_get("ro.soc.manufacturer", manufacturer);
    std::string soc(manufacturer);
    std::transform(soc.begin(), soc.end(), soc.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    char hardware[PROP_VALUE_MAX] = {};
    __system_property_get("ro.hardware", hardware);
    if (soc.find("qualcomm") == std::string::npos && soc.find("qti") == std::string::npos &&
        std::string(hardware).find("qcom") == std::string::npos) return false;
    initialize();
    char** providers = nullptr;
    int count = 0;
    check(api->GetAvailableProviders(&providers, &count));
    bool found = false;
    for (int i = 0; i < count; ++i) if (std::strcmp(providers[i], "QNNExecutionProvider") == 0) found = true;
    check(api->ReleaseAvailableProviders(providers, count));
    if (!found) return false;
    const auto name = libraryDirectory + (backend == 100 ? "/libQnnGpu.so" : "/libQnnHtp.so");
    void* library = dlopen(name.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library) return false;
    const bool usable = dlsym(library, "QnnInterface_getProviders") != nullptr;
    dlclose(library);
    return usable;
}
Session* createQnn(const char* path, int backend, int threads) { return new QnnSession(path, backend, threads); }
}
#else
namespace fluent_ocr {
bool probeQnn(int) { return false; }
Session* createQnn(const char*, int, int) { throw std::runtime_error("QNN is available only on Android"); }
}
#endif
