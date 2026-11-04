#include "ocr_accelerator.h"
#include <algorithm>
#include <memory>
#include <sstream>
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#if !defined(__APPLE__)
#define VK_NO_PROTOTYPES
#include "backend/vulkan/vulkan/vulkan_core.h"
#endif
namespace {
struct Library {
    explicit Library(const std::vector<const char*>& names) {
        for (const char* name : names) {
#if defined(_WIN32)
            value = LoadLibraryExA(name, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
#else
            value = dlopen(name, RTLD_NOW | RTLD_LOCAL);
#endif
            if (value) break;
        }
    }
    ~Library() {
        if (!value) return;
#if defined(_WIN32)
        FreeLibrary(static_cast<HMODULE>(value));
#else
        dlclose(value);
#endif
    }
    void* symbol(const char* name) const {
        if (!value) return nullptr;
#if defined(_WIN32)
        return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(value), name));
#else
        return dlsym(value, name);
#endif
    }
    void* value = nullptr;
};
std::string openClDevice() {
    Library library({
#if defined(_WIN32)
        "OpenCL.dll"
#elif defined(__ANDROID__)
        "libOpenCL.so", "libGLES_mali.so", "libmali.so", "libOpenCL-pixel.so"
#elif defined(__APPLE__)
        "/System/Library/Frameworks/OpenCL.framework/OpenCL"
#else
        "libOpenCL.so.1", "libOpenCL.so"
#endif
    });
    auto platforms = reinterpret_cast<int (*)(uint32_t, void**, uint32_t*)>(library.symbol("clGetPlatformIDs"));
    auto devices = reinterpret_cast<int (*)(void*, uint64_t, uint32_t, void**, uint32_t*)>(library.symbol("clGetDeviceIDs"));
    auto info = reinterpret_cast<int (*)(void*, uint32_t, size_t, void*, size_t*)>(library.symbol("clGetDeviceInfo"));
    if (!platforms || !devices || !info) return {};
    uint32_t count = 0;
    if (platforms(0, nullptr, &count) != 0 || count < 1 || count > 64) return {};
    std::vector<void*> available(count);
    if (platforms(count, available.data(), nullptr) != 0) return {};
    // Match MNN's system selection: first platform, first real GPU device.
    void* device = nullptr;
    if (devices(available[0], 1ULL << 2, 1, &device, nullptr) != 0 || !device) return {};
    std::string result;
    for (uint32_t key : {0x102bU, 0x102cU, 0x102dU}) {
        char text[512] = {};
        if (info(device, key, sizeof(text) - 1, text, nullptr) != 0) return {};
        if (!result.empty()) result += '\n';
        result += text;
    }
    return result;
}
std::string vulkanDevice() {
#if defined(__APPLE__)
    return {};
#else
    Library library({
#if defined(_WIN32)
        "vulkan-1.dll"
#else
        "libvulkan.so.1", "libvulkan.so"
#endif
    });
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(library.symbol("vkGetInstanceProcAddr"));
    if (!get) return {};
    auto create = reinterpret_cast<PFN_vkCreateInstance>(get(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return {};
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "Fluent OCR device detection";
    app.apiVersion = VK_API_VERSION_1_0;
    VkInstanceCreateInfo settings{};
    settings.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    settings.pApplicationInfo = &app;
    VkInstance instance = VK_NULL_HANDLE;
    if (create(&settings, nullptr, &instance) != VK_SUCCESS || !instance) return {};
    auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(get(instance, "vkDestroyInstance"));
    auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(get(instance, "vkEnumeratePhysicalDevices"));
    auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(get(instance, "vkGetPhysicalDeviceProperties"));
    std::string result;
    uint32_t count = 0;
    if (destroy && enumerate && properties && enumerate(instance, &count, nullptr) == VK_SUCCESS && count > 0 && count <= 128) {
        std::vector<VkPhysicalDevice> devices(count);
        if (enumerate(instance, &count, devices.data()) == VK_SUCCESS) {
            VkPhysicalDeviceProperties device{};
            properties(devices.front(), &device);
            if (device.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) {
                std::ostringstream text;
                text << device.deviceName << '\n' << device.vendorID << ':' << device.deviceID << ':' << device.driverVersion;
                result = text.str();
            }
        }
    }
    if (destroy) destroy(instance, nullptr);
    return result;
#endif
}
}
namespace fluent_ocr {
std::string gpuDevice(int backend) {
    if (backend == 3) return openClDevice();
    if (backend == 7) return vulkanDevice();
    if (backend == 1) return "Apple GPU";
    if (backend == 100) return "Qualcomm Adreno";
    if (backend == 101) return "Qualcomm Hexagon";
    return {};
}
}
OCR_API const char* fluent_ocr_device(int backend) {
    thread_local std::string result;
    try { result = fluent_ocr::gpuDevice(backend); }
    catch (...) { result.clear(); }
    return result.c_str();
}
