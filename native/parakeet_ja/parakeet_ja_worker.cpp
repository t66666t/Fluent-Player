#include "parakeet_ja_worker.h"
#include "parakeet.h"
#include "json.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef GGML_BACKEND_DL
#include "ggml-backend.h"
extern "C" ggml_backend_reg_t fluent_qwen_load_cpu(const char*);
#endif
extern "C" void fluent_parakeet_abort(parakeet_context*, bool (*)(void*), void*);
using json = nlohmann::json;
namespace {
struct Owner {
    parakeet_context* model = nullptr;
    std::atomic<bool> cancelled{false};
    std::string response;
    ~Owner() { if (model) parakeet_free(model); }
    void check() { if (cancelled.load()) throw std::runtime_error("Transcription cancelled"); }
    struct Transcript {
        std::string text;
        std::vector<parakeet_token_data> tokens;
        int recoveryWindows = 0;
    };
    Transcript decode(const float* audio, int count, int64_t offset = 0) {
        std::unique_ptr<parakeet_result,decltype(&parakeet_result_free)> result(
            parakeet_transcribe_ex(model,audio,count,offset),parakeet_result_free);
        check();
        if (!result || !result->text) throw std::runtime_error("Japanese Parakeet audio inference failed");
        Transcript output; output.text=result->text;
        if (result->n_tokens>0) output.tokens.assign(result->tokens,result->tokens+result->n_tokens);
        return output;
    }
    Transcript recognize(const std::vector<float>& audio) {
        auto first=decode(audio.data(),static_cast<int>(audio.size()));
        if (audio.size()<4*16000 || first.tokens.empty()) return first;
        // A transducer can emit an initial subword and then skip an earlier
        // utterance. Look at native acoustic time gaps, never at OCR text.
        int64_t cursor=0, gap0=0, gap1=0;
        for (const auto& token:first.tokens) {
            if (std::string(token.text).find_first_not_of(" \t\r\n")==std::string::npos) continue;
            if (token.t0-cursor>gap1-gap0) {gap0=cursor;gap1=token.t0;}
            cursor=std::max(cursor,token.t1);
        }
        const auto duration=static_cast<int64_t>(audio.size()*100/16000);
        if (duration-cursor>gap1-gap0) {gap0=cursor;gap1=duration;}
        if (gap1-gap0<150) return first;
        const int low=std::max(120*160,static_cast<int>(gap0*160));
        const int high=std::min(static_cast<int>(audio.size())-120*160,static_cast<int>(gap1*160));
        if (high-low<3200) return first;
        int cut=low+1600; double least=std::numeric_limits<double>::infinity();
        // Prefer a 200 ms acoustic pause. One bounded retry splits the entire
        // range, so a stray first token cannot be interleaved into a new phrase.
        for (int at=low;at+3200<=high;at+=320) {
            double energy=0;
            for(int j=at;j<at+3200;j++) energy+=static_cast<double>(audio[j])*audio[j];
            if(energy<least){least=energy;cut=at+1600;}
        }
        check();
        auto left=decode(audio.data(),cut);
        auto right=decode(audio.data()+cut,static_cast<int>(audio.size())-cut,cut/160);
        // A failed/empty recovery cannot erase the recognized first pass.
        if(left.text.empty() || right.text.empty()) return first;
        Transcript combined;
        combined.text=left.text+right.text;
        combined.tokens=std::move(left.tokens);
        combined.tokens.insert(combined.tokens.end(),right.tokens.begin(),right.tokens.end());
        combined.recoveryWindows=2;
        return combined;
    }
    json request(const json& message) {
        check();
        const auto op = message.at("op").get<std::string>();
        if (op == "capabilities") return {{"build",FLUENT_PARAKEET_JA_BUILD_ID},{"devices",json::array()},{"nativeTimestamps",true},{"batchSize",1}};
        if (op == "load") {
            if (message.value("kind", "") != "parakeet-ja" || message.value("backend", "cpu") != "cpu")
                throw std::runtime_error("This Japanese Parakeet component supports CPU recognition only");
            if (model) parakeet_free(model); model = nullptr;
#ifdef GGML_BACKEND_DL
            static std::once_flag once;
            std::call_once(once, [] { fluent_qwen_load_cpu(std::filesystem::current_path().u8string().c_str()); });
#endif
            auto params = parakeet_context_default_params();
            params.use_gpu = false; params.n_threads = std::max(1,std::min(12,message.value("threads",4))); params.verbosity = 0;
            model = parakeet_init_from_file(message.at("model").get<std::string>().c_str(),params);
            if (!model) throw std::runtime_error("Cannot load the Japanese Parakeet audio model");
            if (!parakeet_vocab_is_japanese(model)) throw std::runtime_error("The Parakeet model does not contain a Japanese vocabulary");
            fluent_parakeet_abort(model, [](void* value) {return static_cast<Owner*>(value)->cancelled.load();}, this);
            check(); return {{"backend","CPU"}};
        }
        if (op != "decode" || !model) throw std::runtime_error("Japanese Parakeet is not loaded");
        auto path=std::filesystem::u8path(message.at("path").get<std::string>());
        const auto size=std::filesystem::file_size(path);
        if (!size || size%sizeof(float) || size>9*16000*sizeof(float)) throw std::runtime_error("Expected at most 9 seconds of 16 kHz float32 audio");
        std::vector<float> audio(size/sizeof(float)); std::ifstream input(path,std::ios::binary);
        if (!input.read(reinterpret_cast<char*>(audio.data()),size)) throw std::runtime_error("Cannot read PCM");
        for (auto value:audio) if (!std::isfinite(value)) throw std::runtime_error("Non-finite PCM");
        parakeet_set_ctc_mode(model,message.value("ctc",true));
        const auto result=recognize(audio);
        json tokens=json::array(),starts=json::array(),durations=json::array();
        bool valid=true; int64_t previous=0;
        for (const auto& token:result.tokens) {
            if (token.t0<previous || token.t0<0 || token.t1<token.t0 || token.t1>static_cast<int64_t>(audio.size()*100/16000+8)) {valid=false;break;}
            previous=token.t0;
            tokens.push_back(token.text);starts.push_back(token.t0/100.0);durations.push_back((token.t1-token.t0)/100.0);
        }
        if (!valid) {tokens=json::array();starts=json::array();durations=json::array();}
        return {{"result",{{"text",result.text},{"lang","ja"},{"timingKind",valid?"token":"segment"},{"tokens",tokens},{"timestamps",starts},{"durations",durations},{"gpuOperators",0},{"recoveryWindows",result.recoveryWindows}}}};
    }
};
}
extern "C" void* fluent_parakeet_ja_create() {try{return new Owner();}catch(...){return nullptr;}}
extern "C" const char* fluent_parakeet_ja_request(void* handle,const char* input) {
    if (!handle || !input) return "{\"ok\":false,\"error\":\"Invalid audio owner\"}";
    auto& owner=*static_cast<Owner*>(handle);json result,id;
    try {auto value=json::parse(input);id=value.value("id",json());result=owner.request(value);result["ok"]=true;}
    catch(const std::exception& error){result={{"ok",false},{"error",error.what()}};}
    catch(...){result={{"ok",false},{"error","Japanese Parakeet inference failed"}};}
    if (!id.is_null())result["id"]=id; owner.response=result.dump();return owner.response.c_str();
}
extern "C" void fluent_parakeet_ja_cancel(void* handle){if(handle)static_cast<Owner*>(handle)->cancelled.store(true);}
extern "C" void fluent_parakeet_ja_destroy(void* handle){delete static_cast<Owner*>(handle);}
#ifdef FLUENT_PARAKEET_JA_DESKTOP
int main(){auto owner=fluent_parakeet_ja_create();if(!owner)return 1;std::string line;while(std::getline(std::cin,line)){if(line.size()>1024*1024)break;std::cout<<fluent_parakeet_ja_request(owner,line.c_str())<<std::endl;}fluent_parakeet_ja_destroy(owner);}
#endif
