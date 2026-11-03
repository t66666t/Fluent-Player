#include "ocr_accelerator.h"
#include <MNN/Interpreter.hpp>
#include <MNN/Tensor.hpp>
#include <MNN/expr/Module.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/ExecutorScope.hpp>
#include "cli.hpp"
#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <thread>

namespace {
thread_local std::string lastError;
std::mutex converterMutex;
using namespace fluent_ocr;
// Dart isolates can resume on a different VM thread after an await. Keep GPU
// executors, compiler state and vendor contexts on one native owner thread for
// their entire create/run/destroy lifetime, including capability checks.
class NativeExecutor {
public:
    NativeExecutor() : thread_([this] {
        while (true) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                ready_.wait(lock, [&] { return !tasks_.empty(); });
                task = std::move(tasks_.front());
                tasks_.pop_front();
            }
            task();
        }
    }) {}
    template<class F> auto run(F action) -> decltype(action()) {
        using R = decltype(action());
        if (std::this_thread::get_id() == thread_.get_id()) return action();
        auto task = std::make_shared<std::packaged_task<R()>>(std::move(action));
        auto future = task->get_future();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            tasks_.emplace_back([task] { (*task)(); });
        }
        ready_.notify_one();
        return future.get();
    }
private:
    std::mutex mutex_;
    std::condition_variable ready_;
    std::deque<std::function<void()>> tasks_;
    std::thread thread_;
};
NativeExecutor& nativeExecutor() {
    // Process lifetime: unloading a driver or joining a stalled vendor thread
    // at exit would defeat the host's bounded process-cancellation protocol.
    static auto* executor = new NativeExecutor;
    return *executor;
}
class MnnSession final : public Session {
public:
    MnnSession(const char* path, int backend, int threads) : backend_(backend) {
        MNN::BackendConfig cpu;
        cpu.precision = MNN::BackendConfig::Precision_High;
        executor_ = MNN::Express::Executor::newExecutor(MNN_FORWARD_CPU, cpu, 1);
        MNN::Express::ExecutorScope scope(executor_);
        // Preserve FP32 weights and arithmetic across vendor drivers. CPU
        // comparison is still mandatory for each model and input shape.
        precision_.precision = MNN::BackendConfig::Precision_High;
        precision_.power = MNN::BackendConfig::Power_Normal;
        precision_.memory = MNN::BackendConfig::Memory_Normal;
        MNN::ScheduleConfig config;
        config.type = static_cast<MNNForwardType>(backend);
        config.backupType = MNN_FORWARD_CPU;
        config.numThread = backend == 0 ? std::max(1, threads)
            : MNN_GPU_TUNING_NONE | (backend == 3 ? MNN_GPU_MEMORY_BUFFER : 0);
        config.backendConfig = &precision_;
        runtime_.reset(MNN::Express::Executor::RuntimeManager::createRuntimeManager(config),
            MNN::Express::Executor::RuntimeManager::destroy);
        if (!runtime_) throw std::runtime_error("Requested GPU runtime is unavailable");
        int actual[2] = {-1, -1};
        // Upstream 3.6.1 fills BACKENDS but returns false for this enum.
        runtime_->getInfo(MNN::Interpreter::BACKENDS, actual);
        if (backend != 0 && actual[0] != backend)
            throw std::runtime_error("Requested GPU backend was not selected");
        if (backend != 0) {
            uint64_t fingerprint = 14695981039346656037ULL;
            for (unsigned char c : gpuDevice(backend)) {
                fingerprint ^= c;
                fingerprint *= 1099511628211ULL;
            }
            runtime_->setCache(std::string(path) + ".gpu-fp32-buffer-" +
                std::to_string(backend) + "-" + std::to_string(fingerprint) + ".cache");
        }
        MNN::Express::Module::Config moduleConfig;
        moduleConfig.shapeMutable = true;
        moduleConfig.rearrange = false;
        module_.reset(MNN::Express::Module::load({}, {}, path, runtime_, &moduleConfig),
            MNN::Express::Module::destroy);
        if (!module_ || !module_->getInfo() || module_->getInfo()->inputNames.size() != 1 ||
            module_->getInfo()->outputNames.size() != 1)
            throw std::runtime_error("OCR graph must have one input and output");
        module_->setIsTraining(false);
    }
    ~MnnSession() override {
        MNN::Express::ExecutorScope scope(executor_);
        input_ = nullptr;
        module_.reset();
        runtime_.reset();
    }
    Result* run(const float* data, const int64_t* shape, int rank) override {
        MNN::Express::ExecutorScope scope(executor_);
        const size_t count = elements(shape, rank, 64 * 1024 * 1024 / sizeof(float));
        if (!data) throw std::runtime_error("Missing OCR input");
        std::vector<int> dimensions(shape, shape + rank);
        const bool resized = dimensions != shape_ || input_.get() == nullptr;
        if (resized) {
            input_ = MNN::Express::_Input(dimensions, MNN::Express::NCHW, halide_type_of<float>());
            shape_ = dimensions;
        }
        float* input = input_->writeMap<float>();
        if (!input) throw std::runtime_error("Cannot allocate OCR module input");
        std::memcpy(input, data, count * sizeof(float));
        auto outputs = module_->onForward({input_});
        if (outputs.size() != 1 || !outputs[0].get()) throw std::runtime_error("Missing OCR module output");
        auto output = outputs[0];
        auto info = output->getInfo();
        if (!info || info->type != halide_type_of<float>()) throw std::runtime_error("OCR output must be float32");
        if (info->order == MNN::Express::NC4HW4) {
            output = MNN::Express::_Convert(output, MNN::Express::NCHW);
            info = output->getInfo();
        }
        if (!info) throw std::runtime_error("Missing OCR module output dimensions");
        std::unique_ptr<Result> result(new Result);
        result->shape.assign(info->dim.begin(), info->dim.end());
        const size_t n = elements(result->shape.data(), int(result->shape.size()), kMaxOutputBytes / sizeof(float));
        const float* values = output->readMap<float>();
        if (!values) throw std::runtime_error("OCR GPU execution failed");
        float memoryMb = 0;
        if (runtime_->getInfo(MNN::Interpreter::MEMORY, &memoryMb) && memoryMb > 512)
            throw std::runtime_error("OCR GPU session exceeds its memory budget");
        result->data.assign(values, values + n);
        if (resized && backend_ != 0) runtime_->updateCache();
        return result.release();
    }
private:
    int backend_;
    MNN::BackendConfig precision_;
    std::shared_ptr<MNN::Express::Executor> executor_;
    std::shared_ptr<MNN::Express::Executor::RuntimeManager> runtime_;
    std::shared_ptr<MNN::Express::Module> module_;
    MNN::Express::VARP input_;
    std::vector<int> shape_;
};
template<class F, class T> T guarded(F action, T failed) {
    try { lastError.clear(); return nativeExecutor().run(std::move(action)); }
    catch (const std::exception& e) { lastError = e.what(); }
    catch (...) { lastError = "Unknown OCR accelerator failure"; }
    return failed;
}
}
OCR_API int fluent_ocr_abi() { return 1; }
OCR_API const char* fluent_ocr_version() { return "mnn-3.6.1-fp32-buffer-v1;qnn-ort-1.23.2-v1"; }
OCR_API const char* fluent_ocr_error() { return lastError.c_str(); }
OCR_API int fluent_ocr_probe(int backend) {
    return guarded([&] {
        if (backend == 100 || backend == 101) return probeQnn(backend) ? 1 : 0;
        if ((backend == 3 || backend == 7) && gpuDevice(backend).empty()) return 0;
        MNN::ScheduleConfig config;
        config.type = static_cast<MNNForwardType>(backend);
        config.numThread = MNN_GPU_TUNING_NONE | (backend == 3 ? MNN_GPU_MEMORY_BUFFER : 0);
        auto runtime = MNN::Interpreter::createRuntime({config});
        return runtime.first.count(config.type) ? 1 : 0;
    }, 0);
}
OCR_API int fluent_ocr_convert(const char* source, const char* destination) {
    return guarded([&] {
        if (!source || !destination) throw std::runtime_error("Missing OCR model paths");
        std::lock_guard<std::mutex> lock(converterMutex);
        modelConfig config;
        config.model = modelConfig::ONNX;
        config.modelFile = source;
        config.MNNModel = destination;
        config.bizCode = "fluent-ocr-fp32-v1";
        config.saveHalfFloat = false;
        config.weightQuantBits = 0;
        config.useGeluApproximation = false;
        config.alignDenormalizedValue = false;
        config.allowCustomOp = false;
        config.keepInputFormat = true;
        return MNN::Cli::convertModel(config) ? 1 : 0;
    }, 0);
}
OCR_API void* fluent_ocr_create(const char* path, int backend, int threads) {
    return guarded([&]() -> void* {
        if (!path || threads < 1 || threads > 64) throw std::runtime_error("Invalid OCR session settings");
        if (backend == 100 || backend == 101) return createQnn(path, backend, threads);
        if (backend != 0 && backend != 1 && backend != 3 && backend != 7) throw std::runtime_error("Unsupported OCR GPU backend");
        return new MnnSession(path, backend, threads);
    }, static_cast<void*>(nullptr));
}
OCR_API void fluent_ocr_destroy(void* session) {
    nativeExecutor().run([&] { delete static_cast<Session*>(session); });
}
OCR_API void* fluent_ocr_run(void* session, const float* input, const int64_t* shape, int rank) {
    return guarded([&]() -> void* {
        if (!session) throw std::runtime_error("OCR session is closed");
        return static_cast<Session*>(session)->run(input, shape, rank);
    }, static_cast<void*>(nullptr));
}
OCR_API int fluent_ocr_result_rank(void* result) { return int(static_cast<Result*>(result)->shape.size()); }
OCR_API const int64_t* fluent_ocr_result_shape(void* result) { return static_cast<Result*>(result)->shape.data(); }
OCR_API float* fluent_ocr_result_data(void* result) { return static_cast<Result*>(result)->data.data(); }
OCR_API void fluent_ocr_result_destroy(void* result) { delete static_cast<Result*>(result); }
