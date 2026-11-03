// Application adapter around pinned CrispASR/ggml (MIT) and Qwen (Apache-2.0).
// Transcription follows the completed low-level CLI path, not the upstream
// qwen3_asr_transcribe placeholder. Only source-language ASR is performed here.
#include "qwen_worker.h"
#include "qwen3_asr.h"
#include "ecapa_lid.h"
#include "core/bpe.h"
#include "core/gguf_loader.h"
#include "core/qwen3_prompt.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "gguf.h"
#include "json.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
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
#ifdef _WIN32
#include <windows.h>
#endif

extern "C" char* fluent_asr_text_tokenize(const char*, const char*);
extern "C" void fluent_asr_text_free(char*);
// Added by the narrowly checked source preparation patch.
extern "C" const char* fluent_qwen_backend_name(qwen3_asr_context*);
extern "C" void fluent_qwen_set_abort(qwen3_asr_context*, bool (*)(void*), void*);
extern "C" uint64_t fluent_qwen_gpu_ops(qwen3_asr_context*);
#ifdef GGML_BACKEND_DL
extern "C" ggml_backend_reg_t fluent_qwen_load_cpu(const char*);
#endif
using json = nlohmann::json;
template<class T> using malloc_ptr = std::unique_ptr<T, decltype(&std::free)>;

namespace {
const char* build_id = FLUENT_QWEN_BUILD_ID;
std::once_flag cpu_once, gpu_once;
void initialize(bool gpu=true) {
#ifdef GGML_BACKEND_DL
    auto load=[](bool want_gpu) {
        // The private helper's working directory is set by its transport.
        // A CPU retry never initializes a failed GPU driver.
        for(const auto& file:std::filesystem::directory_iterator(std::filesystem::current_path())) {
            auto name=file.path().filename().u8string();
            auto stem=name.rfind("lib",0)==0 ? name.substr(3) : name;
            bool cpu=stem.rfind("ggml-cpu",0)==0;
            bool module=stem.rfind("ggml-",0)==0 && stem.rfind("ggml-base",0)!=0;
            auto extension=file.path().extension().string();
            if(module && cpu!=want_gpu && (extension==".dll" || extension==".so" || extension==".dylib"))
                ggml_backend_load(file.path().u8string().c_str());
        }
    };
    std::call_once(cpu_once,[]{fluent_qwen_load_cpu(std::filesystem::current_path().u8string().c_str());});
    if(gpu) std::call_once(gpu_once,[&]{load(true);});
#else
    // Static CPU calls use ggml-cpu directly. Constructing the global device
    // registry also probes linked GPU backends, so defer it until GPU is used.
    if(gpu) std::call_once(gpu_once,[]{ggml_backend_load_all();});
#endif
}
std::string trim(std::string s) {
    auto begin = s.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) return "";
    return s.substr(begin, s.find_last_not_of(" \t\r\n") - begin + 1);
}
std::string language_name(const std::string& code) {
    static const std::map<std::string, std::string> names = {
        {"zh","Chinese"},{"en","English"},{"ja","Japanese"},{"ko","Korean"},{"yue","Cantonese"},
        {"ar","Arabic"},{"de","German"},{"fr","French"},{"es","Spanish"},{"pt","Portuguese"},
        {"id","Indonesian"},{"it","Italian"},{"ru","Russian"},{"th","Thai"},{"vi","Vietnamese"},
        {"tr","Turkish"},{"hi","Hindi"},{"ms","Malay"},{"nl","Dutch"},{"sv","Swedish"},
        {"da","Danish"},{"fi","Finnish"},{"pl","Polish"},{"cs","Czech"},{"fil","Filipino"},
        {"fa","Persian"},{"el","Greek"},{"hu","Hungarian"},{"mk","Macedonian"},{"ro","Romanian"}};
    if (code.empty() || code == "auto") return "";
    auto at = names.find(code);
    if (at == names.end()) throw std::runtime_error("Unsupported Qwen ASR language");
    return at->second;
}
std::vector<float> audio_file(const json& request) {
    auto path = std::filesystem::u8path(request.at("path").get<std::string>());
    auto size = std::filesystem::file_size(path);
    if (!size || size % sizeof(float) || size > 25 * 16000 * sizeof(float))
        throw std::runtime_error("Expected at most 25 seconds of 16 kHz mono float32 PCM");
    std::vector<float> samples(size / sizeof(float));
    std::ifstream input(path, std::ios::binary);
    if (!input.read(reinterpret_cast<char*>(samples.data()), size)) throw std::runtime_error("Cannot read PCM");
    for (float sample : samples) if (!std::isfinite(sample)) throw std::runtime_error("Non-finite PCM");
    return samples;
}
void validate_architecture(const std::string& file, const std::string& kind) {
    gguf_init_params params{true, nullptr};
    auto context = gguf_init_from_file(file.c_str(), params);
    if (!context) throw std::runtime_error("Invalid GGUF audio model");
    auto key = gguf_find_key(context, "general.architecture");
    const char* expected = kind == "lid" ? "ecapa-tdnn-lid" : "qwen3asr";
    bool valid = key >= 0 && gguf_get_kv_type(context, key) == GGUF_TYPE_STRING &&
        std::strcmp(gguf_get_val_str(context, key), expected) == 0;
    gguf_free(context);
    if (!valid) throw std::runtime_error("GGUF architecture does not match the audio loader");
}
struct Owner {
    qwen3_asr_context* model = nullptr;
    ecapa_lid_context* lid = nullptr;
    std::string kind, language, hotwords, backend, response;
    std::atomic<bool> cancelled{false};
    ~Owner() { release(); }
    void release() {
        if (model) qwen3_asr_free(model);
        if (lid) ecapa_lid_free(lid);
        model = nullptr; lid = nullptr; kind.clear();
    }
    void check() const { if (cancelled.load()) throw std::runtime_error("cancelled"); }
    static bool abort(void* data) { return static_cast<Owner*>(data)->cancelled.load(); }
    int token(const char* text) {
        int n = 0;
        malloc_ptr<int32_t> ids(qwen3_asr_tokenize(model, text, &n), std::free);
        if (!ids || n != 1) throw std::runtime_error("Invalid Qwen special token");
        return ids.get()[0];
    }
    json transcribe(const std::vector<float>& samples) {
        check();
        const auto gpu_before=fluent_qwen_gpu_ops(model);
        int mel_bins = 0, frames = 0, encoded = 0, dimension = 0;
        malloc_ptr<float> mel(qwen3_asr_compute_mel(model, samples.data(), (int)samples.size(), &mel_bins, &frames), std::free);
        if (!mel || mel_bins != 128) throw std::runtime_error("Qwen mel computation failed");
        check();
        malloc_ptr<float> audio(qwen3_asr_run_encoder(model, mel.get(), mel_bins, frames, &encoded, &dimension), std::free);
        mel.reset();
        if (!audio || encoded <= 0 || dimension <= 0) throw std::runtime_error("Qwen audio encoder failed");
        check();
        std::string prefill = language_name(language);
        if (!prefill.empty()) prefill = "language " + prefill + "<asr_text>";
        std::string prompt = core_qwen3_prompt::build(encoded, "", "", prefill, hotwords);
        int prompt_size = 0;
        malloc_ptr<int32_t> ids(qwen3_asr_tokenize(model, prompt.c_str(), &prompt_size), std::free);
        if (!ids || prompt_size < encoded || prompt_size > 3500) throw std::runtime_error("Invalid Qwen prompt length");
        malloc_ptr<float> embeds(qwen3_asr_embed_tokens(model, ids.get(), prompt_size), std::free);
        if (!embeds) throw std::runtime_error("Qwen prompt embedding failed");
        int pad = token("<|audio_pad|>"), eos = token("<|im_end|>"), inserted = 0;
        for (int i = 0; i < prompt_size; ++i) if (ids.get()[i] == pad) {
            if (inserted >= encoded) throw std::runtime_error("Too many Qwen audio placeholders");
            std::memcpy(embeds.get() + (size_t)i * dimension, audio.get() + (size_t)inserted++ * dimension, dimension * sizeof(float));
        }
        if (inserted != encoded) throw std::runtime_error("Qwen audio placeholder count mismatch");
        audio.reset();
        if (!qwen3_asr_kv_init(model, 4096)) throw std::runtime_error("Qwen KV allocation failed");
        qwen3_asr_kv_reset(model);
        int count = 0, vocabulary = 0;
        check();
        malloc_ptr<float> logits(qwen3_asr_run_llm_kv(model, embeds.get(), prompt_size, 0, &count, &vocabulary), std::free);
        embeds.reset();
        std::string generated;
        bool completed = false;
        for (int step = 0; step < 512; ++step) {
            check();
            if (!logits || count < 1 || vocabulary < 1) throw std::runtime_error("Qwen decode failed");
            float* last = logits.get() + (size_t)(count - 1) * vocabulary;
            int next = (int)(std::max_element(last, last + vocabulary) - last);
            logits.reset();
            if (next == eos) { completed = true; break; }
            const char* piece = qwen3_asr_token_text(model, next);
            if (!piece) throw std::runtime_error("Invalid Qwen output token");
            generated += core_bpe::token_bytes_to_utf8(piece);
            int32_t id = next;
            malloc_ptr<float> embedding(qwen3_asr_embed_tokens(model, &id, 1), std::free);
            if (!embedding) throw std::runtime_error("Qwen token embedding failed");
            logits.reset(qwen3_asr_run_llm_kv(model, embedding.get(), 1, prompt_size + step, &count, &vocabulary));
        }
        check();
        if (!completed) throw std::runtime_error("Qwen output token limit; retry with a shorter audio segment");
        // Parse the structured prefix as a whole; English language names can
        // occupy several BPE tokens. Never consume a literal spoken 'language'.
        std::string detected = language == "auto" ? "" : language;
        if (prefill.empty()) {
            auto delimiter = generated.find("<asr_text>");
            if (delimiter != std::string::npos) {
                auto prefix = trim(generated.substr(0, delimiter));
                if (prefix.rfind("language ", 0) == 0) detected = trim(prefix.substr(9));
                generated.erase(0, delimiter + std::strlen("<asr_text>"));
            }
        }
        if (generated.find("<|audio_") != std::string::npos || generated.find("<|im_") != std::string::npos)
            throw std::runtime_error("Qwen returned unexpected control tokens");
        return {{"text", trim(generated)}, {"lang", detected}, {"tokens", json::array()},
                {"timestamps", json::array()}, {"timingKind", "segment"}, {"backend", backend},
                {"gpuOperators",fluent_qwen_gpu_ops(model)-gpu_before}};
    }
    json request(const json& message) {
        const auto op = message.at("op").get<std::string>();
        if (op == "close" || op == "release") { release(); return json::object(); }
        if (op == "tokenize") {
            std::unique_ptr<char, decltype(&fluent_asr_text_free)> value(
                fluent_asr_text_tokenize(message.at("text").get<std::string>().c_str(), message.at("language").get<std::string>().c_str()), fluent_asr_text_free);
            if (!value) throw std::runtime_error("Native tokenizer failed");
            auto parsed = json::parse(value.get());
            if (parsed.contains("error")) throw std::runtime_error(parsed.at("error").get<std::string>());
            return parsed;
        }
        if (op == "capabilities") {
            initialize();
            json devices = json::array();
            for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
                auto device = ggml_backend_dev_get(i);
                devices.push_back({{"name", ggml_backend_dev_name(device)}, {"description", ggml_backend_dev_description(device)},
                    {"gpu", ggml_backend_dev_type(device) != GGML_BACKEND_DEVICE_TYPE_CPU}});
            }
            return {{"build",build_id},{"devices",devices},{"textProcessingVersion",1}};
        }
        if (op == "load") {
            release(); cancelled.store(false); initialize(message.value("kind", "asr")!="lid" && message.value("backend","cpu")!="cpu");
            kind = message.value("kind", "asr");
            language = message.value("language", "auto");
            hotwords = message.value("hotwords", "");
            if (hotwords.size() > 16384) throw std::runtime_error("Hotword context is too large");
            auto file = message.at("model").get<std::string>();
            validate_architecture(file, kind);
            int threads = std::clamp(message.value("threads", 2), 1, 64);
            if (kind == "lid") {
                lid = ecapa_lid_init(file.c_str(), threads);
                if (!lid) throw std::runtime_error("Language identification model load failed");
                backend = "CPU";
            } else {
                if (kind != "asr" && kind != "aligner") throw std::runtime_error("Invalid Qwen model kind");
                auto params = qwen3_asr_context_default_params();
                params.n_threads = threads; params.verbosity = 0;
                params.use_gpu = message.value("backend", "cpu") != "cpu";
                const auto selected = message.value("backend", "cpu");
                params.backend_kind = selected == "vulkan" ? 2 : selected == "cuda" ? 3 : selected == "metal" ? 4 : 0;
                model = qwen3_asr_init_from_file(file.c_str(), params);
                if (!model) throw std::runtime_error("Qwen audio model load failed");
                auto head = qwen3_asr_lm_head_dim(model);
                if ((kind == "aligner") != (head == 5000)) { release(); throw std::runtime_error("ASR and aligner weights are not interchangeable"); }
                fluent_qwen_set_abort(model, Owner::abort, this);
                backend = fluent_qwen_backend_name(model);
            }
            return {{"backend",backend},{"build",build_id}};
        }
        check();
        auto samples = audio_file(message);
        if (op == "features" && model) {
            // Maintainer parity probe; the application never requests features.
            if (samples.size() > 2 * 16000) throw std::runtime_error("Feature probe is limited to two seconds");
            int bins=0, frames=0;
            malloc_ptr<float> values(qwen3_asr_compute_mel(model,samples.data(),(int)samples.size(),&bins,&frames),std::free);
            if(!values || bins!=128 || frames<=0) throw std::runtime_error("Audio feature computation failed");
            return {{"melBins",bins},{"frames",frames},{"values",std::vector<float>(values.get(),values.get()+(size_t)bins*frames)}};
        }
        if (op == "decode" && kind == "asr" && model) return {{"result",transcribe(samples)}};
        if (op == "identify" && kind == "lid" && lid) {
            float confidence = 0;
            // Limit fallback LID work and memory, without resampling coordinates.
            int n = std::min((int)samples.size(), 6 * 16000);
            const char* result = ecapa_lid_detect(lid, samples.data() + (samples.size() - n) / 2, n, &confidence);
            check();
            if (!result || !std::isfinite(confidence)) throw std::runtime_error("Language identification failed");
            return {{"language",result},{"confidence",confidence}};
        }
        if (op == "align" && kind == "aligner" && model) {
            const auto gpu_before=fluent_qwen_gpu_ops(model);
            auto words = message.at("words").get<std::vector<std::string>>();
            if (words.empty() || words.size() > 512) throw std::runtime_error("Invalid alignment unit count");
            std::vector<const char*> pointers;
            for (const auto& word : words) {
                if (word.empty() || word.size() > 1024 || word.find('<') != std::string::npos) throw std::runtime_error("Invalid alignment text unit");
                pointers.push_back(word.c_str());
            }
            std::vector<int64_t> starts(words.size()), ends(words.size());
            int status = qwen3_asr_align_words(model, samples.data(), (int)samples.size(), pointers.data(), (int)words.size(), starts.data(), ends.data());
            check();
            if (status) throw std::runtime_error("Qwen forced alignment failed: " + std::to_string(status));
            json times = json::array();
            for (size_t i = 0; i < words.size(); ++i) times.push_back({{"startMs",starts[i]},{"endMs",ends[i]}});
            return {{"times",times},{"backend",backend},{"gpuOperators",fluent_qwen_gpu_ops(model)-gpu_before}};
        }
        throw std::runtime_error("Operation does not match the loaded model");
    }
};
}
extern "C" void* fluent_qwen_create() { try { return new Owner(); } catch (...) { return nullptr; } }
extern "C" const char* fluent_qwen_request(void* handle, const char* input) {
    if (!handle || !input) return "{\"ok\":false,\"error\":\"Invalid native handle\"}";
    auto& owner = *static_cast<Owner*>(handle);
    json response; json id;
    try {
        auto message = json::parse(input); id = message.value("id",json());
        response = owner.request(message); response["ok"] = true;
    } catch (const std::exception& error) { response = {{"ok",false},{"error",error.what()}}; }
      catch (...) { response = {{"ok",false},{"error","Native audio worker failed"}}; }
    if (!id.is_null()) response["id"] = id;
    owner.response = response.dump();
    return owner.response.c_str();
}
extern "C" void fluent_qwen_cancel(void* handle) { if (handle) static_cast<Owner*>(handle)->cancelled.store(true); }
extern "C" void fluent_qwen_destroy(void* handle) { delete static_cast<Owner*>(handle); }

#ifdef FLUENT_QWEN_DESKTOP
int main() {
    auto handle = fluent_qwen_create();
    if (!handle) return 1;
    std::string line;
    while (std::getline(std::cin,line)) {
        if (line.size() > 1024 * 1024) { std::cout << "{\"ok\":false,\"error\":\"Request too large\"}" << std::endl; break; }
        std::cout << fluent_qwen_request(handle,line.c_str()) << std::endl;
    }
    fluent_qwen_destroy(handle);
    return 0;
}
#endif
