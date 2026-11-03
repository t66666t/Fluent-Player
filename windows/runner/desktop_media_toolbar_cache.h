#ifndef RUNNER_DESKTOP_MEDIA_TOOLBAR_CACHE_H_
#define RUNNER_DESKTOP_MEDIA_TOOLBAR_CACHE_H_

#include <windows.h>
#include <shobjidl.h>

#include <array>
#include <cwchar>
#include <optional>

// Runner-internal publication state, separate from the Shell transport so
// success, retry and Explorer recreation can be checked without a real taskbar.
class ToolbarUpdateCache {
 public:
  using Buttons = std::array<THUMBBUTTON, 6>;

  template <typename Submit>
  void Publish(const Buttons& buttons, Submit&& submit) {
    if (added_ && last_ && Equal(*last_, buttons)) return;
    const HRESULT result = submit(added_);
    // A failed Shell call must remain retryable on the next position update.
    if (SUCCEEDED(result)) {
      last_ = buttons;
      added_ = true;
    }
  }

  void Invalidate() {
    added_ = false;
    last_.reset();
  }

 private:
  static bool Equal(const Buttons& left, const Buttons& right) {
    for (size_t i = 0; i < left.size(); ++i) {
      const auto& a = left[i];
      const auto& b = right[i];
      // THUMBBUTTON contains padding; compare fields rather than raw bytes.
      if (a.dwMask != b.dwMask || a.iId != b.iId ||
          a.iBitmap != b.iBitmap || a.hIcon != b.hIcon ||
          std::wcscmp(a.szTip, b.szTip) != 0 || a.dwFlags != b.dwFlags) {
        return false;
      }
    }
    return true;
  }

  bool added_ = false;
  std::optional<Buttons> last_;
};

#endif
