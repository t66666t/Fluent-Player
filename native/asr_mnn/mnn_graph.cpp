#include "mnn_graph.h"
#include "../ocr/ocr_accelerator.h"
#include <MNN/Interpreter.hpp>
#include <MNN/expr/Module.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/ExecutorScope.hpp>
#include "cli.hpp"
#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#if defined(_WIN32)
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

namespace {
namespace fs = std::filesystem;
using namespace MNN::Express;
thread_local std::string error;
constexpr size_t kTensorBytes = 192 * 1024 * 1024;
class Owner {
public:
    Owner() : thread_([this] {
        for (;;) {
            std::function<void()> work;
            { std::unique_lock<std::mutex> lock(mutex_);
              ready_.wait(lock, [&] { return !queue_.empty(); });
              work = std::move(queue_.front()); queue_.pop_front(); }
            work();
        }
    }) {}
    template<class F> auto run(F f) -> decltype(f()) {
        auto task = std::make_shared<std::packaged_task<decltype(f())()>>(std::move(f));
        auto result = task->get_future();
        { std::lock_guard<std::mutex> lock(mutex_); queue_.push_back([task] { (*task)(); }); }
        ready_.notify_one(); return result.get();
    }
private:
    std::mutex mutex_;
    std::condition_variable ready_;
    std::deque<std::function<void()>> queue_;
    std::thread thread_;
};
Owner& owner() { static auto* value = new Owner; return *value; }
template<class F, class T> T guard(F f, T failure) {
    try { error.clear(); return owner().run(std::move(f)); }
    catch (const std::exception& e) { error = e.what(); }
    catch (...) { error = "ASR GPU runtime failure"; }
    return failure;
}
size_t count(const int64_t* shape, int rank, size_t bytes = 4) {
    if ((rank > 0 && !shape) || rank < 0 || rank > 8) throw std::runtime_error("ASR tensor rank is invalid");
    size_t n = 1;
    for (int i = 0; i < rank; ++i) {
        if (shape[i] < 0 || shape[i] > std::numeric_limits<int>::max() ||
            (n && size_t(shape[i]) > kTensorBytes / bytes / n))
            throw std::runtime_error("ASR tensor exceeds its allocation limit");
        n *= size_t(shape[i]);
    }
    return n;
}
class FileLock {
public:
    explicit FileLock(const fs::path& path) {
#if defined(_WIN32)
        file_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file_ == INVALID_HANDLE_VALUE || !LockFileEx(file_, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &offset_))
            throw std::runtime_error("Cannot lock ASR compilation cache");
#else
        file_ = open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (file_ < 0 || flock(file_, LOCK_EX)) throw std::runtime_error("Cannot lock ASR compilation cache");
#endif
    }
    ~FileLock() {
#if defined(_WIN32)
        UnlockFileEx(file_, 0, 1, 0, &offset_); CloseHandle(file_);
#else
        flock(file_, LOCK_UN); close(file_);
#endif
    }
private:
#if defined(_WIN32)
    HANDLE file_ = INVALID_HANDLE_VALUE;
    OVERLAPPED offset_{};
#else
    int file_ = -1;
#endif
};
std::string compile(const char* sourceName, const char* cacheName) {
    const auto source = fs::u8path(sourceName), cache = fs::u8path(cacheName);
    fs::create_directories(cache);
    FileLock lock(cache / "compile.lock");
    const auto model = cache / (source.filename().u8string() + ".mnn");
    const auto receipt = fs::path(model).concat(".source");
    const auto identity = std::string(FluentMnnVersion()) + ":" + std::to_string(fs::file_size(source)) +
        ":" + std::to_string(static_cast<long long>(fs::last_write_time(source).time_since_epoch().count()));
    std::ifstream input(receipt);
    std::string previous((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (previous == identity && fs::exists(model) && fs::file_size(model) > 8) return model.u8string();
    // These exports are <2 GB. A larger/external-weight graph requires a
    // separately verified conversion contract, rather than truncating offsets.
    if (fs::file_size(source) > 1800ULL * 1024 * 1024)
        throw std::runtime_error("This ASR export requires an external-weight GPU adapter");
    auto temporary = fs::path(model).concat(".tmp");
    modelConfig config;
    config.model = modelConfig::ONNX;
    config.modelFile = source.u8string(); config.MNNModel = temporary.u8string();
    config.bizCode = "fluent-asr-fp32-v1";
    config.saveHalfFloat = false; config.weightQuantBits = 0;
    config.useGeluApproximation = false; config.alignDenormalizedValue = false;
    config.allowCustomOp = false; config.keepInputFormat = true;
    if (!MNN::Cli::convertModel(config) || !fs::exists(temporary) || fs::file_size(temporary) <= 8)
        throw std::runtime_error("ASR ONNX operators are not supported by this GPU adapter");
    // The lock covers replacement on Windows too; interruption leaves no valid
    // receipt, so the next use recompiles instead of trusting a partial file.
    std::error_code ignored; fs::remove(model, ignored);
    fs::rename(temporary, model);
    std::ofstream output(receipt, std::ios::trunc); output << identity;
    if (!output) throw std::runtime_error("Cannot save ASR compilation receipt");
    return model.u8string();
}
struct Tensor {
    int type;
    std::vector<int64_t> shape;
    std::vector<uint8_t> data;
};
using Result = std::vector<Tensor>;
class Graph {
public:
    Graph(const char* source, const char* cache, int backend) : backend_(backend) {
        MNN::BackendConfig cpu;
        cpu.precision = MNN::BackendConfig::Precision_High;
        executor_ = Executor::newExecutor(MNN_FORWARD_CPU, cpu, 1);
        ExecutorScope scope(executor_);
        const auto path = compile(source, cache);
        precision_.precision = MNN::BackendConfig::Precision_High;
        precision_.power = MNN::BackendConfig::Power_Normal;
        MNN::ScheduleConfig config;
        config.type = static_cast<MNNForwardType>(backend);
        config.backupType = MNN_FORWARD_CPU;
        config.numThread = MNN_GPU_TUNING_NONE | (backend == 3 ? MNN_GPU_MEMORY_BUFFER : 0);
        config.backendConfig = &precision_;
        runtime_.reset(Executor::RuntimeManager::createRuntimeManager(config), Executor::RuntimeManager::destroy);
        if (!runtime_) throw std::runtime_error("ASR GPU runtime unavailable");
        int actual[2] = {-1, -1};
        runtime_->getInfo(MNN::Interpreter::BACKENDS, actual);
        if (actual[0] != backend) throw std::runtime_error("ASR GPU backend was not selected");
        runtime_->setMode(MNN::Interpreter::Session_Debug);
        executor_->setCallBack([](const std::vector<MNN::Tensor*>&, const MNN::OperatorInfo*) { return true; },
            [this](const std::vector<MNN::Tensor*>& tensors, const MNN::OperatorInfo*) {
            if (std::any_of(tensors.begin(), tensors.end(), [](const MNN::Tensor* t) {
                return t && t->deviceId() != 0;
            })) ++accelerated;
            return true;
        });
        uint64_t device = 14695981039346656037ULL;
        for (unsigned char c : fluent_ocr::gpuDevice(backend)) { device ^= c; device *= 1099511628211ULL; }
        runtime_->setCache(path + ".gpu-" + std::to_string(backend) + "-" + std::to_string(device) + ".cache");
        Module::Config options;
        options.shapeMutable = true; options.rearrange = false;
        module_.reset(Module::load({}, {}, path.c_str(), runtime_, &options), Module::destroy);
        if (!module_ || !module_->getInfo()) throw std::runtime_error("Cannot load ASR GPU graph");
        module_->setIsTraining(false);
        if (module_->getInfo()->inputNames.size() > 64 || module_->getInfo()->outputNames.size() > 64)
            throw std::runtime_error("ASR graph has too many tensors");
    }
    ~Graph() { ExecutorScope scope(executor_); inputs_.clear(); module_.reset(); runtime_.reset(); }
    Result* run(const char* const* names, const FluentMnnTensor* tensors, int n,
                const char* const* outputNames, int outputCount) {
        ExecutorScope scope(executor_);
        const auto& expected = module_->getInfo()->inputNames;
        if (!names || !tensors || n < 1 || n > 64 || n != int(expected.size()) ||
            !outputNames || outputCount < 1 || outputCount > 64)
            throw std::runtime_error("ASR GPU tensor contract mismatch");
        std::vector<VARP> input;
        bool resized = false;
        for (const auto& name : expected) {
            int at = 0; while (at < n && (!names[at] || name != names[at])) ++at;
            if (at == n) throw std::runtime_error("Missing named ASR GPU input");
            const auto& tensor = tensors[at];
            const size_t length = count(tensor.shape, tensor.rank, tensor.type == 7 ? 8 : 4);
            if (!tensor.data && length) throw std::runtime_error("Missing ASR GPU input data");
            const auto type = tensor.type == 1 ? halide_type_of<float>() : halide_type_of<int32_t>();
            if (tensor.type != 1 && tensor.type != 6 && tensor.type != 7 && tensor.type != 9)
                throw std::runtime_error("Unsupported ASR GPU input type");
            std::vector<int> dimensions(tensor.shape, tensor.shape + tensor.rank);
            auto& value = inputs_[name];
            if (!value.get() || !value->getInfo() || value->getInfo()->dim != dimensions || value->getInfo()->type != type) {
                value = _Input(dimensions, NCHW, type);
                resized = true;
            }
            if (tensor.type == 1 || tensor.type == 6) {
                auto* data = value->writeMap<void>();
                if (!data && length) throw std::runtime_error("Cannot allocate ASR input");
                if (length) std::memcpy(data, tensor.data, length * 4);
            } else {
                auto* data = value->writeMap<int32_t>();
                if (!data && length) throw std::runtime_error("Cannot allocate ASR integer input");
                for (size_t i = 0; i < length; ++i) {
                    const int64_t v = tensor.type == 7 ? static_cast<const int64_t*>(tensor.data)[i]
                        : static_cast<const uint8_t*>(tensor.data)[i];
                    if (v < INT32_MIN || v > INT32_MAX) throw std::runtime_error("ASR integer input cannot be represented exactly");
                    data[i] = int32_t(v);
                }
            }
            input.push_back(value);
        }
        const auto outputs = module_->onForward(input);
        const auto& resultNames = module_->getInfo()->outputNames;
        if (outputs.size() != resultNames.size()) throw std::runtime_error("Missing ASR GPU outputs");
        std::unique_ptr<Result> result(new Result);
        size_t total = 0;
        for (int i = 0; i < outputCount; ++i) {
            auto found = std::find(resultNames.begin(), resultNames.end(), outputNames[i]);
            if (found == resultNames.end()) throw std::runtime_error("Missing named ASR GPU output");
            auto value = outputs[found - resultNames.begin()];
            if (!value.get() || !value->getInfo()) throw std::runtime_error("Invalid ASR GPU output");
            if (value->getInfo()->order == NC4HW4) value = _Convert(value, NCHW);
            const auto* info = value->getInfo();
            Tensor out;
            out.shape.assign(info->dim.begin(), info->dim.end());
            const auto length = count(out.shape.data(), int(out.shape.size()));
            out.type = info->type == halide_type_of<float>() ? 1 : info->type == halide_type_of<int32_t>() ? 6 : 0;
            if (!out.type || (total += length * 4) > kTensorBytes)
                throw std::runtime_error("ASR GPU output type or memory limit exceeded");
            const auto* data = value->readMap<void>();
            if (!data && length) throw std::runtime_error("ASR GPU execution failed");
            out.data.resize(length * 4);
            if (length) std::memcpy(out.data.data(), data, out.data.size());
            result->push_back(std::move(out));
        }
        float memory = 0;
        runtime_->getInfo(MNN::Interpreter::MEMORY, &memory);
        if (memory > 2048) throw std::runtime_error("ASR GPU graph exceeds its memory budget");
        if (resized) runtime_->updateCache();
        executor_->setCallBack({}, {});
        if (!accelerated) throw std::runtime_error("ASR graph executed no verified GPU kernels");
        return result.release();
    }
    int accelerated = 0;
private:
    int backend_;
    MNN::BackendConfig precision_;
    std::shared_ptr<Executor> executor_;
    std::shared_ptr<Executor::RuntimeManager> runtime_;
    std::shared_ptr<Module> module_;
    std::map<std::string, VARP> inputs_;
};
}
ASR_MNN_API int FluentMnnAbi() { return 1; }
ASR_MNN_API const char* FluentMnnVersion() { return "mnn-asr-3.6.1-fp32-buffer-v1"; }
ASR_MNN_API const char* FluentMnnError() { return error.c_str(); }
ASR_MNN_API int FluentMnnProbe(int backend) {
    return guard([&] {
        if (backend != 1 && backend != 3 && backend != 7) return 0;
        if (fluent_ocr::gpuDevice(backend).empty()) return 0;
        MNN::ScheduleConfig config;
        config.type = static_cast<MNNForwardType>(backend);
        config.numThread = MNN_GPU_TUNING_NONE | (backend == 3 ? MNN_GPU_MEMORY_BUFFER : 0);
        return MNN::Interpreter::createRuntime({config}).first.count(config.type) ? 1 : 0;
    }, 0);
}
ASR_MNN_API const char* FluentMnnDevice(int backend) {
    thread_local std::string name;
    name = guard([&] { return fluent_ocr::gpuDevice(backend); }, std::string{});
    return name.c_str();
}
ASR_MNN_API void* FluentMnnOpen(const char* source, const char* cache, int backend) {
    return guard([&]() -> void* {
        if (!source || !cache || (backend != 1 && backend != 3 && backend != 7))
            throw std::runtime_error("Invalid ASR GPU settings");
        return new Graph(source, cache, backend);
    }, static_cast<void*>(nullptr));
}
ASR_MNN_API void FluentMnnClose(void* session) { owner().run([&] { delete static_cast<Graph*>(session); }); }
ASR_MNN_API void* FluentMnnRun(void* session, const char* const* names,
    const FluentMnnTensor* inputs, int count, const char* const* outputs, int outputCount) {
    return guard([&]() -> void* {
        if (!session) throw std::runtime_error("ASR GPU graph is closed");
        return static_cast<Graph*>(session)->run(names, inputs, count, outputs, outputCount);
    }, static_cast<void*>(nullptr));
}
ASR_MNN_API int FluentMnnRead(void* result, int index, FluentMnnTensor* tensor) {
    auto* values = static_cast<Result*>(result);
    if (!values || !tensor || index < 0 || index >= int(values->size())) return 0;
    const auto& value = values->at(index);
    *tensor = {value.type, int(value.shape.size()), value.shape.data(), value.data.data()};
    return 1;
}
ASR_MNN_API void FluentMnnFree(void* result) { delete static_cast<Result*>(result); }
ASR_MNN_API int FluentMnnAccelerated(void* session) { return static_cast<Graph*>(session)->accelerated; }
