#ifndef SUBTITLE_CONTROLLER_PLUGIN_H_
#define SUBTITLE_CONTROLLER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

class SubtitleControllerPlugin {
 public:
  SubtitleControllerPlugin(flutter::PluginRegistrarWindows* registrar);
  ~SubtitleControllerPlugin();

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // SUBTITLE_CONTROLLER_PLUGIN_H_
