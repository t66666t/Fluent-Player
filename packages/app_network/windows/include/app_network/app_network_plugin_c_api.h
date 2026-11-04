#ifndef APP_NETWORK_PLUGIN_C_API_H_
#define APP_NETWORK_PLUGIN_C_API_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define APP_NETWORK_EXPORT __declspec(dllexport)
#else
#define APP_NETWORK_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
APP_NETWORK_EXPORT void AppNetworkPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
