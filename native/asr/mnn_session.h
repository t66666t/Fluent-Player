#pragma once
#include "fluent_asr_observer.h"
#include "../asr_mnn/mnn_graph.h"
#include <onnxruntime_cxx_api.h>
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
#endif

namespace fluent_asr {
struct MnnApi {
    decltype(&FluentMnnAbi) abi;
    decltype(&FluentMnnVersion) version;
    decltype(&FluentMnnError) error;
    decltype(&FluentMnnProbe) probe;
    decltype(&FluentMnnDevice) device;
    decltype(&FluentMnnOpen) open;
    decltype(&FluentMnnClose) close;
    decltype(&FluentMnnRun) run;
    decltype(&FluentMnnRead) read;
    decltype(&FluentMnnFree) free;
    decltype(&FluentMnnAccelerated) accelerated;
    static MnnApi* instance() {
        static MnnApi* result = []() -> MnnApi* {
#if defined(_WIN32)
            wchar_t path[32768]{};
            if (!GetModuleFileNameW(nullptr, path, 32768)) return nullptr;
            const auto file = std::filesystem::path(path).parent_path() / L"fluent_asr_mnn.dll";
            void* library = LoadLibraryExW(file.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
            auto get = [&](const char* name) { return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(library), name)); };
#else
#ifdef __APPLE__
            std::vector<char> executable(32768);
            uint32_t size = uint32_t(executable.size());
            if (_NSGetExecutablePath(executable.data(), &size)) return nullptr;
            const auto file = std::filesystem::path(executable.data()).parent_path() / "libfluent_asr_mnn.dylib";
            void* library = dlopen(file.c_str(), RTLD_NOW | RTLD_LOCAL);
#else
            void* library = dlopen("libfluent_asr_mnn.so", RTLD_NOW | RTLD_LOCAL);
#endif
            auto get = [&](const char* name) { return dlsym(library, name); };
#endif
            if (!library) return nullptr;
            std::unique_ptr<MnnApi> api(new MnnApi);
#define FLUENT_MNN_SYMBOL(field, symbol) api->field = reinterpret_cast<decltype(api->field)>(get(#symbol)); if (!api->field) return nullptr
            FLUENT_MNN_SYMBOL(abi, FluentMnnAbi);
            FLUENT_MNN_SYMBOL(version, FluentMnnVersion);
            FLUENT_MNN_SYMBOL(error, FluentMnnError);
            FLUENT_MNN_SYMBOL(probe, FluentMnnProbe);
            FLUENT_MNN_SYMBOL(device, FluentMnnDevice);
            FLUENT_MNN_SYMBOL(open, FluentMnnOpen);
            FLUENT_MNN_SYMBOL(close, FluentMnnClose);
            FLUENT_MNN_SYMBOL(run, FluentMnnRun);
            FLUENT_MNN_SYMBOL(read, FluentMnnRead);
            FLUENT_MNN_SYMBOL(free, FluentMnnFree);
            FLUENT_MNN_SYMBOL(accelerated, FluentMnnAccelerated);
#undef FLUENT_MNN_SYMBOL
            if (api->abi() != 1) return nullptr;
            return api.release();
        }();
        return result;
    }
};
inline int MnnBackend(const std::string& name) {
    return name == "vulkan" ? 7 : name == "opencl" ? 3 : name == "metal" ? 1 : 0;
}
// These adapters retain sherpa's exact frontend, decoding, hotwords, streaming
// states and timestamps. They are not a generic ONNX-extension compatibility
// claim. Large external-weight Parakeet keeps its existing ORT GPU adapters.
inline bool MnnModelSupported(const std::string& id) {
    return id == "sensevoice-small-int8" || id == "dolphin-base-int8" || id == "zipformer-zh-en-tiny-int8";
}
class Session : public Ort::Session {
public:
    Session(const std::string& source, const Ort::Env& env, const void* data, size_t length,
            const Ort::SessionOptions& options)
        : Ort::Session(env, data, length, options), source_(source), backend_(mnn_backend) {
        if (!backend_) return;
        for (size_t i = 0; i < GetOutputCount(); ++i) {
            const auto info = GetOutputTypeInfo(i);
            const auto tensor = info.GetTensorTypeAndShapeInfo();
            types_.push_back(tensor.GetElementType());
            shapes_.push_back(tensor.GetShape());
        }
        cache_ = cache;
    }
    ~Session() { if (graph_) MnnApi::instance()->close(graph_); }
    std::vector<Ort::Value> Run(const Ort::RunOptions& options, const char* const* inputNames,
        const Ort::Value* inputs, size_t inputCount, const char* const* outputNames, size_t outputCount) {
        if (!backend_) return Ort::Session::Run(options, inputNames, inputs, inputCount, outputNames, outputCount);
        auto* api = MnnApi::instance();
        if (!api) throw std::runtime_error("ASR MNN component unavailable");
        if (!graph_) {
            // All sherpa metadata access has completed before first inference.
            // Release the temporary CPU session before GPU weights are loaded.
            Ort::Session::operator=(Ort::Session(nullptr));
            graph_ = api->open(source_.c_str(), cache_.c_str(), backend_);
            if (!graph_) throw std::runtime_error(api->error());
        }
        std::vector<std::vector<int64_t>> dimensions(inputCount);
        std::vector<FluentMnnTensor> views;
        views.reserve(inputCount);
        for (size_t i = 0; i < inputCount; ++i) {
            auto info = inputs[i].GetTensorTypeAndShapeInfo();
            dimensions[i] = info.GetShape();
            views.push_back({int(info.GetElementType()), int(dimensions[i].size()),
                dimensions[i].data(), inputs[i].GetTensorRawData()});
        }
        void* result = api->run(graph_, inputNames, views.data(), int(inputCount), outputNames, int(outputCount));
        if (!result) throw std::runtime_error(api->error());
        try {
            std::vector<Ort::Value> values;
            Ort::AllocatorWithDefaultOptions allocator;
            for (size_t i = 0; i < outputCount; ++i) {
                FluentMnnTensor tensor{};
                if (!api->read(result, int(i), &tensor) || i >= types_.size() ||
                    size_t(tensor.rank) != shapes_[i].size()) throw std::runtime_error("ASR GPU output rank mismatch");
                for (int j = 0; j < tensor.rank; ++j) {
                    if (tensor.shape[j] < 0 || (shapes_[i][j] > 0 && tensor.shape[j] != shapes_[i][j]))
                        throw std::runtime_error("ASR GPU output dimensions mismatch");
                }
                auto value = Ort::Value::CreateTensor(allocator, tensor.shape, tensor.rank, types_[i]);
                const auto n = value.GetTensorTypeAndShapeInfo().GetElementCount();
                if (tensor.type == 1 && types_[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
                    if (n) std::memcpy(value.GetTensorMutableData<float>(), tensor.data, n * sizeof(float));
                } else if (tensor.type == 6 && types_[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
                    auto* out = value.GetTensorMutableData<int64_t>();
                    const auto* in = static_cast<const int32_t*>(tensor.data);
                    for (size_t j = 0; j < n; ++j) out[j] = in[j];
                } else if (tensor.type == 6 && types_[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
                    if (n) std::memcpy(value.GetTensorMutableData<int32_t>(), tensor.data, n * sizeof(int32_t));
                } else throw std::runtime_error("ASR GPU output type mismatch");
                values.push_back(std::move(value));
            }
            mnn_executed = std::max(mnn_executed, api->accelerated(graph_));
            api->free(result);
            return values;
        } catch (...) { api->free(result); throw; }
    }
private:
    std::string source_, cache_;
    int backend_;
    void* graph_ = nullptr;
    std::vector<ONNXTensorElementDataType> types_;
    std::vector<std::vector<int64_t>> shapes_;
};
}
