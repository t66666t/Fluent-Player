// Dedicated audio loader. It never opens a text-translation GGUF context.
#include "cohere_worker.h"
#include "transcribe.h"
#include "json.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
using json = nlohmann::json;
namespace {
void checked(transcribe_status status) {
    if (status != TRANSCRIBE_OK) throw std::runtime_error(transcribe_status_string(status));
}
struct Owner {
    transcribe_model* model = nullptr;
    transcribe_session* session = nullptr;
    std::atomic<bool> cancelled{false};
    std::string response;
    ~Owner() { release(); }
    void release() {
        if (session) transcribe_session_free(session);
        session = nullptr;
        if (model) transcribe_model_free(model);
        model = nullptr;
    }
    void check() {
        if (cancelled.load()) throw std::runtime_error("Transcription cancelled");
    }
    json request(const json& message) {
        check();
        const auto op = message.at("op").get<std::string>();
        if (op == "capabilities") return {
            {"build", FLUENT_COHERE_BUILD_ID}, {"architecture", "cohere-asr"},
            {"devices", json::array()}, {"batchSize", 1}, {"nativeTimestamps", false}
        };
        if (op == "load") {
            if (message.value("kind", "") != "cohere-asr" || message.value("backend", "cpu") != "cpu")
                throw std::runtime_error("This Cohere component supports CPU audio recognition only");
            release();
            static std::once_flag initialize;
            std::call_once(initialize, [] {
                transcribe_backend_init_params params;
                transcribe_backend_init_params_init(&params);
                params.allowed_backends = TRANSCRIBE_BACKEND_MASK_CPU;
#ifdef FLUENT_COHERE_DESKTOP
                const auto directory = std::filesystem::current_path().u8string();
                params.artifact_dir = directory.c_str();
#endif
                checked(transcribe_init_backends_ex(&params));
            });
            transcribe_model_load_params load;
            transcribe_model_load_params_init(&load);
            load.backend = TRANSCRIBE_BACKEND_CPU;
            checked(transcribe_model_load_file(message.at("model").get<std::string>().c_str(), &load, &model));
            if (std::string(transcribe_model_arch_string(model)).find("cohere") == std::string::npos) {
                release();
                throw std::runtime_error("GGUF architecture does not match the Cohere audio loader");
            }
            transcribe_session_params config;
            transcribe_session_params_init(&config);
            config.n_threads = std::max(1, std::min(12, message.value("threads", 4)));
            checked(transcribe_session_init(model, &config, &session));
            transcribe_set_abort_callback(session, [](void* data) {
                return static_cast<Owner*>(data)->cancelled.load();
            }, this);
            check();
            return {{"backend", "CPU"}};
        }
        if (op != "decode" || !session) throw std::runtime_error("Cohere audio model is not loaded");
        auto path = std::filesystem::u8path(message.at("path").get<std::string>());
        const auto size = std::filesystem::file_size(path);
        if (!size || size % sizeof(float) || size > 9 * 16000 * sizeof(float))
            throw std::runtime_error("Expected at most 9 seconds of 16 kHz mono float32 PCM");
        std::vector<float> pcm(size / sizeof(float));
        std::ifstream input(path, std::ios::binary);
        if (!input.read(reinterpret_cast<char*>(pcm.data()), size)) throw std::runtime_error("Cannot read PCM");
        for (auto value : pcm) if (!std::isfinite(value)) throw std::runtime_error("Non-finite PCM");
        const auto language = message.at("language").get<std::string>();
        static const std::vector<std::string> languages = {
            "en","fr","de","es","it","pt","nl","pl","el","ar","ja","zh","vi","ko"
        };
        if (std::find(languages.begin(), languages.end(), language) == languages.end())
            throw std::runtime_error("Cohere needs a supported, identified audio language");
        transcribe_run_params run;
        transcribe_run_params_init(&run);
        run.language = language.c_str();
        run.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        checked(transcribe_run(session, pcm.data(), static_cast<int>(pcm.size()), &run));
        check();
        transcribe_timings timings;
        transcribe_timings_init(&timings);
        checked(transcribe_get_timings(session, &timings));
        return {{"result", {
            {"text", transcribe_full_text(session)}, {"lang", language},
            {"timingKind", "segment"}, {"tokens", json::array()},
            {"timestamps", json::array()}, {"gpuOperators", 0},
            {"computeMs", timings.mel_ms + timings.encode_ms + timings.decode_ms}
        }}};
    }
};
}
extern "C" void* fluent_cohere_create() { try { return new Owner(); } catch (...) { return nullptr; } }
extern "C" const char* fluent_cohere_request(void* handle, const char* input) {
    if (!handle || !input) return "{\"ok\":false,\"error\":\"Invalid audio owner\"}";
    auto& owner = *static_cast<Owner*>(handle);
    json response, id;
    try {
        auto message = json::parse(input); id = message.value("id", json());
        response = owner.request(message); response["ok"] = true;
    } catch (const std::exception& error) { response = {{"ok", false}, {"error", error.what()}}; }
      catch (...) { response = {{"ok", false}, {"error", "Cohere audio inference failed"}}; }
    if (!id.is_null()) response["id"] = id;
    owner.response = response.dump();
    return owner.response.c_str();
}
extern "C" void fluent_cohere_cancel(void* handle) { if (handle) static_cast<Owner*>(handle)->cancelled.store(true); }
extern "C" void fluent_cohere_destroy(void* handle) { delete static_cast<Owner*>(handle); }
#ifdef FLUENT_COHERE_DESKTOP
int main() {
    auto owner = fluent_cohere_create();
    if (!owner) return 1;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.size() > 1024 * 1024) break;
        std::cout << fluent_cohere_request(owner, line.c_str()) << std::endl;
    }
    fluent_cohere_destroy(owner);
    return 0;
}
#endif
