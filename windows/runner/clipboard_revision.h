#ifndef RUNNER_CLIPBOARD_REVISION_H_
#define RUNNER_CLIPBOARD_REVISION_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

// Metadata only. The existing Flutter clipboard API remains the text reader.
class ClipboardRevisionBridge {
 public:
  explicit ClipboardRevisionBridge(flutter::BinaryMessenger* messenger);
  ~ClipboardRevisionBridge();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::string scope_;
  bool persistent_ = false;
};

#endif  // RUNNER_CLIPBOARD_REVISION_H_
