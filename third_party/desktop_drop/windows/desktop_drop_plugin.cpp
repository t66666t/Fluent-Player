#include "include/desktop_drop/desktop_drop_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <algorithm>
#include <vector>

namespace {

    using FlutterMethodChannel = std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>;


    using namespace std::literals::string_literals;

    bool HasFormat(IDataObject* object, CLIPFORMAT format) {
        FORMATETC descriptor = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        return object && object->QueryGetData(&descriptor) == S_OK;
    }

    // Bound reads to the supplied allocation; malformed external data must not
    // make the receiver scan past its buffer. Never retain IDataObject in Dart.
    std::string ReadUnicode(IDataObject* object, CLIPFORMAT format) {
        FORMATETC descriptor = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM medium{};
        if (!object || FAILED(object->GetData(&descriptor, &medium))) return {};
        std::string result;
        const auto capacity = GlobalSize(medium.hGlobal) / sizeof(wchar_t);
        const auto* data = static_cast<const wchar_t*>(GlobalLock(medium.hGlobal));
        if (data && capacity <= 1024 * 1024) {
            const auto end = std::find(data, data + capacity, L'\0');
            const int length = static_cast<int>(end - data);
            const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                data, length, nullptr, 0, nullptr, nullptr);
            if (size > 0) {
                result.resize(size);
                WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                    data, length, result.data(), size, nullptr, nullptr);
            }
        }
        if (data) GlobalUnlock(medium.hGlobal);
        ReleaseStgMedium(&medium);
        return result;
    }

    CLIPFORMAT UrlFormat() {
        static const auto format = static_cast<CLIPFORMAT>(
            RegisterClipboardFormatW(L"UniformResourceLocatorW"));
        return format;
    }

    std::string ws2s(const std::wstring &wstr) {
        if (wstr.empty()) {
            return {};
        }
        size_t pos;
        size_t begin = 0;
        std::string ret;

        int size;
        pos = wstr.find(static_cast<wchar_t>(0), begin);
        while (pos != std::wstring::npos && begin < wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], pos - begin);
            size = WideCharToMultiByte(CP_UTF8,
                                       WC_ERR_INVALID_CHARS,
                                       &segment[0],
                                       (int) segment.size(),
                                       nullptr,
                                       0,
                                       nullptr,
                                       nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
            ret.append({0});
            begin = pos + 1;
            pos = wstr.find(static_cast<wchar_t>(0), begin);
        }
        if (begin <= wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], wstr.length() - begin);
            size =
                    WideCharToMultiByte(CP_UTF8,
                                        WC_ERR_INVALID_CHARS,
                                        &segment[0],
                                        (int) segment.size(),
                                        nullptr,
                                        0,
                                        nullptr,
                                        nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
        }

        return ret;
    }


    class DesktopDropTarget : public IDropTarget {
    public:

        DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle);

        HRESULT DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragLeave() override;

        HRESULT Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT QueryInterface(const IID &riid, void **ppvObject) override;

        ULONG AddRef() override;

        ULONG Release() override;

        virtual ~DesktopDropTarget();

    private:
        FlutterMethodChannel channel_;
        HWND window_handle_;
        LONG ref_count_;
        bool need_revoke_ole_initialize_;
        bool text_drag_ = false;
        bool supported_drag_ = false;
    };

    class DesktopDropPlugin : public flutter::Plugin {

    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

        explicit DesktopDropPlugin(DesktopDropTarget *target);

        ~DesktopDropPlugin() override;

    private:

        DesktopDropTarget *target_;

    };

    DesktopDropPlugin::DesktopDropPlugin(DesktopDropTarget *target) : target_(target) {
        target_->AddRef();
    }

    DesktopDropPlugin::~DesktopDropPlugin() {
        target_->Release();
    }


    // static
    void DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarWindows *registrar) {
        auto channel =
                std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                        registrar->messenger(), "desktop_drop",
                        &flutter::StandardMethodCodec::GetInstance());

        HWND hwnd = nullptr;
        if (registrar->GetView()) {
            hwnd = registrar->GetView()->GetNativeWindow();
        }

        if (hwnd == nullptr) {
            // no window, no drop.
            return;
        }

        channel->SetMethodCallHandler([](const auto &call, auto result) {
            result->NotImplemented();
        });

        auto drop_target = new DesktopDropTarget(std::move(channel), hwnd);

        auto plugin = std::make_unique<DesktopDropPlugin>(drop_target);

        registrar->AddPlugin(std::move(plugin));
    }


    DesktopDropTarget::DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle) : channel_(
            std::move(channel)), window_handle_(window_handle), ref_count_(0), need_revoke_ole_initialize_(false) {
        auto ret = RegisterDragDrop(window_handle_, this);
        if (ret == E_OUTOFMEMORY) {
            OleInitialize(nullptr);
            ret = RegisterDragDrop(window_handle_, this);
            if (ret == 0) {
                need_revoke_ole_initialize_ = true;
            }
        }

        if (ret != 0) {
            std::cout << "RegisterDragDrop failed: " << ret << std::endl;
        }
    }

    HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        const bool files = HasFormat(pDataObj, CF_HDROP);
        text_drag_ = !files && (HasFormat(pDataObj, CF_UNICODETEXT) || HasFormat(pDataObj, UrlFormat()));
        supported_drag_ = files || text_drag_;
        if (!supported_drag_) {
            *pdwEffect = DROPEFFECT_NONE;
            return S_OK;
        }
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        if (text_drag_) {
            *pdwEffect &= DROPEFFECT_COPY;
            channel_->InvokeMethod("textEntered", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableMap{{flutter::EncodableValue("x"), flutter::EncodableValue(double(point.x))},
                    {flutter::EncodableValue("y"), flutter::EncodableValue(double(point.y))}}));
            return S_OK;
        }
        channel_->InvokeMethod("entered", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        if (!supported_drag_) {
            *pdwEffect = DROPEFFECT_NONE;
            return S_OK;
        }
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        if (text_drag_) {
            *pdwEffect &= DROPEFFECT_COPY;
            channel_->InvokeMethod("textUpdated", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableMap{{flutter::EncodableValue("x"), flutter::EncodableValue(double(point.x))},
                    {flutter::EncodableValue("y"), flutter::EncodableValue(double(point.y))}}));
            return S_OK;
        }
        channel_->InvokeMethod("updated", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragLeave() {
        channel_->InvokeMethod(text_drag_ ? "textExited" : "exited", std::make_unique<flutter::EncodableValue>());
        text_drag_ = supported_drag_ = false;
        return 0;
    }

    HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {

        if (text_drag_) {
            const DWORD allowed = *pdwEffect & DROPEFFECT_COPY;
            *pdwEffect = DROPEFFECT_NONE;
            POINT point = {pt.x, pt.y};
            ScreenToClient(window_handle_, &point);
            const auto text = ReadUnicode(pDataObj, CF_UNICODETEXT);
            const auto url = ReadUnicode(pDataObj, UrlFormat());
            if (allowed && (!text.empty() || !url.empty())) {
                flutter::EncodableList urls;
                if (!url.empty()) urls.emplace_back(url);
                channel_->InvokeMethod("performTextOperation", std::make_unique<flutter::EncodableValue>(
                    flutter::EncodableMap{
                        {flutter::EncodableValue("x"), flutter::EncodableValue(double(point.x))},
                        {flutter::EncodableValue("y"), flutter::EncodableValue(double(point.y))},
                        {flutter::EncodableValue("text"), flutter::EncodableValue(text)},
                        {flutter::EncodableValue("urls"), flutter::EncodableValue(urls)}}));
                *pdwEffect = DROPEFFECT_COPY;
            } else {
                channel_->InvokeMethod("textExited", std::make_unique<flutter::EncodableValue>());
            }
            text_drag_ = supported_drag_ = false;
            return S_OK;
        }
        if (!supported_drag_) {
            *pdwEffect = DROPEFFECT_NONE;
            return S_OK;
        }

        flutter::EncodableList list = {};

        // construct a FORMATETC object
        FORMATETC fmtetc = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM stgmed;

        // See if the dataobject contains any TEXT stored as a HGLOBAL
        if (pDataObj->QueryGetData(&fmtetc) == S_OK) {
            // Yippie! the data is there, so go get it!
            if (pDataObj->GetData(&fmtetc, &stgmed) == S_OK) {
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }

                // release the data using the COM API
                ReleaseStgMedium(&stgmed);
            }
        }
        channel_->InvokeMethod("performOperation", std::make_unique<flutter::EncodableValue>(list));
        supported_drag_ = false;
        return 0;
    }

    HRESULT DesktopDropTarget::QueryInterface(const IID &iid, void **ppvObject) {
        if (iid == IID_IDropTarget || iid == IID_IUnknown) {
            AddRef();
            *ppvObject = this;
            return S_OK;
        } else {
            *ppvObject = nullptr;
            return E_NOINTERFACE;
        }
    }

    ULONG DesktopDropTarget::AddRef() {
        return InterlockedIncrement(&ref_count_);
    }

    ULONG DesktopDropTarget::Release() {
        LONG count = InterlockedDecrement(&ref_count_);

        if (count == 0) {
            delete this;
            return 0;
        } else {
            return count;
        }
    }

    DesktopDropTarget::~DesktopDropTarget() {
        RevokeDragDrop(window_handle_);
        if (need_revoke_ole_initialize_) {
            OleUninitialize();
        }
    }

}  // namespace

void DesktopDropPluginRegisterWithRegistrar(
        FlutterDesktopPluginRegistrarRef registrar) {
    DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarManager::GetInstance()
                    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));

}
