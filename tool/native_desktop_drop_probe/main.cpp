// Exercises the shipped OLE receiver without moving a pointer or opening UI.
#include <windows.h>
#include <map>
#include <stdexcept>
#include <iostream>
#include <cstring>
#include <shellapi.h>
#include <shlobj.h>
#include "../../third_party/desktop_drop/windows/desktop_drop_plugin.cpp"

class Messenger final : public flutter::BinaryMessenger {
 public:
  mutable std::vector<std::pair<std::string, flutter::EncodableValue>> calls;
  void Send(const std::string&, const uint8_t* data, size_t size,
            flutter::BinaryReply reply = nullptr) const override {
    const auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(data, size);
    if (!call) throw std::runtime_error("Invalid method-channel message");
    calls.emplace_back(call->method_name(), call->arguments() ? *call->arguments() : flutter::EncodableValue());
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler) override {}
};

class Data final : public IDataObject {
 public:
  std::map<CLIPFORMAT, std::vector<uint8_t>> formats;
  void text(CLIPFORMAT format, const std::wstring& value, bool terminate = true) {
    auto& bytes = formats[format];
    bytes.resize((value.size() + (terminate ? 1 : 0)) * sizeof(wchar_t));
    std::memcpy(bytes.data(), value.data(), value.size() * sizeof(wchar_t));
  }
  HRESULT QueryInterface(REFIID iid, void** result) override {
    if (iid == IID_IDataObject || iid == IID_IUnknown) { *result = this; return S_OK; }
    *result = nullptr; return E_NOINTERFACE;
  }
  ULONG AddRef() override { return 1; }
  ULONG Release() override { return 1; }
  HRESULT GetData(FORMATETC* format, STGMEDIUM* result) override {
    if (QueryGetData(format) != S_OK) return DV_E_FORMATETC;
    const auto& bytes = formats.at(format->cfFormat);
    result->tymed = TYMED_HGLOBAL;
    result->hGlobal = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.size());
    result->pUnkForRelease = nullptr;
    if (!result->hGlobal) return E_OUTOFMEMORY;
    auto* buffer = GlobalLock(result->hGlobal);
    std::memcpy(buffer, bytes.data(), bytes.size());
    GlobalUnlock(result->hGlobal);
    return S_OK;
  }
  HRESULT QueryGetData(FORMATETC* format) override {
    return (format->tymed & TYMED_HGLOBAL) && formats.count(format->cfFormat) ? S_OK : DV_E_FORMATETC;
  }
  HRESULT GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  HRESULT SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
};

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

int main() {
  try {
    const auto initialized = OleInitialize(nullptr);
    require(SUCCEEDED(initialized), "OLE initialization failed");
    HWND window = CreateWindowW(L"STATIC", L"drop test", WS_OVERLAPPEDWINDOW,
                                 100, 100, 500, 400, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    require(window != nullptr, "Hidden receiver window failed");
    Messenger messenger;
    auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        &messenger, "desktop_drop", &flutter::StandardMethodCodec::GetInstance());
    auto* target = new DesktopDropTarget(std::move(channel), window);
    target->AddRef();
    POINT client{41, 73};
    ClientToScreen(window, &client);
    POINTL point{client.x, client.y};
    auto drop = [&](Data& data, DWORD allowed = DROPEFFECT_COPY | DROPEFFECT_MOVE) {
      messenger.calls.clear();
      auto effect = allowed;
      target->DragEnter(&data, 0, point, &effect);
      effect = allowed;
      target->DragOver(0, point, &effect);
      effect = allowed;
      target->Drop(&data, 0, point, &effect);
      return effect;
    };
    auto payload = [&]() -> const flutter::EncodableMap& {
      require(messenger.calls.back().first == "performTextOperation", "Text went through file protocol");
      const auto& args = std::get<flutter::EncodableMap>(messenger.calls.back().second);
      require(std::get<double>(args.at(flutter::EncodableValue("x"))) == 41, "Incorrect client x");
      require(std::get<double>(args.at(flutter::EncodableValue("y"))) == 73, "Incorrect client y");
      return args;
    };
    Data unicode;
    unicode.text(CF_UNICODETEXT, L"中文标题😀\r\n第二行");
    require(drop(unicode) == DROPEFFECT_COPY, "Text drop did not copy");
    require(std::get<std::string>(payload().at(flutter::EncodableValue("text"))) == u8"中文标题😀\r\n第二行", "Unicode changed");

    Data browser;
    browser.text(CF_UNICODETEXT, L"网页标题");
    browser.text(UrlFormat(), L"https://example.com/watch?v=123");
    require(drop(browser) == DROPEFFECT_COPY, "Browser URL rejected");
    const auto& args = payload();
    require(std::get<std::string>(args.at(flutter::EncodableValue("text"))) == u8"网页标题", "Lost browser label");
    require(std::get<std::string>(std::get<flutter::EncodableList>(args.at(flutter::EncodableValue("urls"))).at(0)) == "https://example.com/watch?v=123", "Lost browser URL");

    Data url_only;
    url_only.text(UrlFormat(), L"https://example.com/url-only");
    require(drop(url_only) == DROPEFFECT_COPY, "URL-only drop rejected");
    require(std::get<std::string>(payload().at(flutter::EncodableValue("text"))).empty(), "URL-only text unexpected");

    Data bounded;
    bounded.text(CF_UNICODETEXT, L"unterminated", false);
    require(drop(bounded) == DROPEFFECT_COPY, "Bounded text rejected");
    require(std::get<std::string>(payload().at(flutter::EncodableValue("text"))) == "unterminated", "Unterminated buffer was not bounded");

    require(drop(unicode, DROPEFFECT_MOVE) == DROPEFFECT_NONE, "Source text could be deleted by a move");
    require(messenger.calls.back().first == "textExited", "Rejected move not cleaned up");
    Data unsupported;
    require(drop(unsupported) == DROPEFFECT_NONE, "Unsupported drag accepted");

    Data files;
    const std::wstring filename = L"D:\\video.mp4";
    auto& bytes = files.formats[CF_HDROP];
    bytes.resize(sizeof(DROPFILES) + (filename.size() + 2) * sizeof(wchar_t));
    auto* descriptor = reinterpret_cast<DROPFILES*>(bytes.data());
    descriptor->pFiles = sizeof(DROPFILES);
    descriptor->fWide = TRUE;
    std::memcpy(bytes.data() + sizeof(DROPFILES), filename.data(), filename.size() * sizeof(wchar_t));
    files.text(CF_UNICODETEXT, L"D:\\video.mp4");
    drop(files);
    require(messenger.calls.back().first == "performOperation", "Files were misclassified as text");
    const auto& paths = std::get<flutter::EncodableList>(messenger.calls.back().second);
    require(paths.size() == 1 && std::get<std::string>(paths.at(0)) == "D:\\video.mp4", "File import changed");
    target->Release();
    DestroyWindow(window);
    OleUninitialize();
    std::cout << "PASS: Unicode, URL+label, URL-only, bounded buffers, copy-only, unsupported data, files, client coordinates\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
