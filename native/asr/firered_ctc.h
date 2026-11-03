#pragma once
// FireRedASR2 encoder + CTC export (2026-02-25), not the AED/LLM export.
// Uses the pinned sherpa frontend and ORT; does not change their public ABI.
// Export reference: k2-fsa/sherpa-onnx, offline-fire-red-asr-ctc-model.cc
// and offline-recognizer-ctc-impl.h (Apache-2.0, Xiaomi Corporation).
#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <sstream>
#include "onnxruntime_cxx_api.h"
#include "sherpa-onnx/csrc/offline-stream.h"
#include "sherpa-onnx/csrc/offline-ctc-greedy-search-decoder.h"
#include "sherpa-onnx/csrc/session.h"
#include "sherpa-onnx/csrc/symbol-table.h"

namespace fluent_asr {
class FireRedCtc {
 public:
  FireRedCtc(const std::filesystem::path& directory, bool floating,
             const std::string& backend, int threads)
      : symbols_((directory / "tokens.txt").u8string()),
        env_(ORT_LOGGING_LEVEL_ERROR),
        session_(env_, (directory / (floating ? "model.onnx" : "model.int8.onnx")).c_str(),
                 sherpa_onnx::GetSessionOptionsImpl(threads, backend)) {
    auto metadata = session_.GetModelMetadata();
    auto value = [&](const char* key) {
      auto p = metadata.LookupCustomMetadataMapAllocated(key, allocator_);
      if (!p) throw std::runtime_error(std::string("Missing FireRedASR2 metadata: ") + key);
      return std::string(p.get());
    };
    if (value("model_type") != "fire-red-asr-2-ctc")
      throw std::runtime_error("Expected FireRedASR2 CTC export, not AED/LLM");
    auto subsampling = metadata.LookupCustomMetadataMapAllocated("subsampling_factor", allocator_);
    subsampling_ = subsampling ? std::stoi(subsampling.get()) : 4;
    if (subsampling_ != 4) throw std::runtime_error("Unregistered FireRedASR2 frame stride");
    mean_ = Vector(value("cmvn_mean"));
    inv_std_ = Vector(value("cmvn_inv_stddev"));
    if (mean_.size() != 80 || inv_std_.size() != 80 ||
        !symbols_.Contains("<blank>") || symbols_["<blank>"] != 0)
      throw std::runtime_error("Invalid FireRedASR2 CMVN/vocabulary");
    if (session_.GetInputCount() != 2 || session_.GetOutputCount() != 2)
      throw std::runtime_error("Unexpected FireRedASR2 input/output layout");
    for (size_t i = 0; i < 2; ++i) {
      input_names_.push_back(session_.GetInputNameAllocated(i, allocator_).get());
      output_names_.push_back(session_.GetOutputNameAllocated(i, allocator_).get());
    }
    const auto input_type = session_.GetInputTypeInfo(0);
    const auto length_type = session_.GetInputTypeInfo(1);
    const auto output_type = session_.GetOutputTypeInfo(0);
    const auto output_length_type = session_.GetOutputTypeInfo(1);
    const auto input = input_type.GetTensorTypeAndShapeInfo();
    const auto lengths = length_type.GetTensorTypeAndShapeInfo();
    const auto output = output_type.GetTensorTypeAndShapeInfo();
    const auto output_lengths = output_length_type.GetTensorTypeAndShapeInfo();
    if (input.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        input.GetShape().size() != 3 || input.GetShape().back() != 80 ||
        lengths.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 ||
        lengths.GetShape().size() != 1 ||
        output.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        output.GetShape().size() != 3 || output.GetShape().back() != symbols_.NumSymbols() ||
        output_lengths.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 ||
        output_lengths.GetShape().size() != 1)
      throw std::runtime_error("Incompatible FireRedASR2 tensor contract");
  }

  sherpa_onnx::OfflineRecognitionResult Decode(const std::vector<float>& samples) {
    sherpa_onnx::FeatureExtractorConfig feature;
    feature.sampling_rate = 16000;
    feature.feature_dim = 80;
    feature.normalize_samples = false;  // FireRed expects 16-bit amplitude.
    feature.high_freq = 0;
    feature.snip_edges = true;
    feature.dither = 0;
    sherpa_onnx::OfflineStream stream(feature);
    stream.AcceptWaveform(16000, samples.data(), static_cast<int32_t>(samples.size()));
    auto features = stream.GetFrames();
    int64_t frames = static_cast<int64_t>(features.size() / 80);
    if (frames < 7) return {};  // Two valid subsampling convolutions.
    for (size_t i = 0; i < features.size(); ++i)
      features[i] = (features[i] - mean_[i % 80]) * inv_std_[i % 80];
    auto memory = Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);
    std::array<int64_t, 3> shape{1, frames, 80};
    int64_t one = 1;
    std::array<Ort::Value, 2> inputs{
      Ort::Value::CreateTensor<float>(memory, features.data(), features.size(), shape.data(), shape.size()),
      Ort::Value::CreateTensor<int64_t>(memory, &frames, 1, &one, 1)};
    std::array<const char*, 2> input_names{input_names_[0].c_str(), input_names_[1].c_str()};
    std::array<const char*, 2> output_names{output_names_[0].c_str(), output_names_[1].c_str()};
    auto output = session_.Run({}, input_names.data(), inputs.data(), inputs.size(),
                               output_names.data(), output_names.size());
    const auto output_shape = output[0].GetTensorTypeAndShapeInfo().GetShape();
    const auto length = output[1].GetTensorData<int64_t>()[0];
    if (output_shape.size() != 3 || output_shape[0] != 1 ||
        output_shape[2] != symbols_.NumSymbols() || length < 0 || length > output_shape[1])
      throw std::runtime_error("Invalid FireRedASR2 output length");
    sherpa_onnx::OfflineCtcGreedySearchDecoder decoder(0);
    auto decoded = decoder.Decode(std::move(output[0]), std::move(output[1]));
    sherpa_onnx::OfflineRecognitionResult result;
    for (size_t i = 0; i < decoded[0].tokens.size(); ++i) {
      const int32_t id = decoded[0].tokens[i];
      if (!symbols_.Contains(id)) throw std::runtime_error("Unknown FireRedASR2 output token");
      auto token = symbols_[id];
      // SymbolTable converts the SentencePiece boundary marker to a space.
      result.text += token;
      result.tokens.push_back(std::move(token));
      result.timestamps.push_back(decoded[0].timestamps[i] * .01f * subsampling_);
    }
    if (!result.text.empty() && result.text.front() == ' ') result.text.erase(0, 1);
    return result;
  }

 private:
  static std::vector<float> Vector(std::string text) {
    std::replace(text.begin(), text.end(), ',', ' ');
    std::istringstream input(text);
    std::vector<float> result;
    float value;
    while (input >> value) {
      if (!std::isfinite(value)) throw std::runtime_error("Invalid FireRedASR2 CMVN value");
      result.push_back(value);
    }
    if (!input.eof()) throw std::runtime_error("Invalid FireRedASR2 CMVN encoding");
    return result;
  }
  sherpa_onnx::SymbolTable symbols_;
  Ort::Env env_;
  Ort::AllocatorWithDefaultOptions allocator_;
  Ort::Session session_;
  std::vector<float> mean_, inv_std_;
  std::vector<std::string> input_names_, output_names_;
  int subsampling_ = 4;
};
}  // namespace fluent_asr
