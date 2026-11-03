#include "subtitle_controller_plugin.h"

SubtitleControllerPlugin::SubtitleControllerPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.yourapp.subtitle_controller",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [&](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

SubtitleControllerPlugin::~SubtitleControllerPlugin() {}

void SubtitleControllerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("disableSubtitles") == 0) {
    result->Success(flutter::EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

void SubtitleControllerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<SubtitleControllerPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}
