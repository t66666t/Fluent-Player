#include "flutter_inappwebview_windows_plugin.h"

#include <flutter/plugin_registrar_windows.h>
#include <map>

#include "cookie_manager.h"
#include "headless_in_app_webview/headless_in_app_webview_manager.h"
#include "in_app_browser/in_app_browser_manager.h"
#include "in_app_webview/in_app_webview_manager.h"
#include "webview_environment/webview_environment_manager.h"

#pragma comment(lib, "Shlwapi.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

namespace flutter_inappwebview_plugin
{
  namespace {
    std::map<flutter::PluginRegistrarWindows*, FlutterInappwebviewWindowsPlugin*> registeredPlugins;
  }
  // static
  void FlutterInappwebviewWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar)
  {
    auto plugin = std::make_unique<FlutterInappwebviewWindowsPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  FlutterInappwebviewWindowsPlugin::FlutterInappwebviewWindowsPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar)
  {
    registeredPlugins[registrar] = this;
    webViewEnvironmentManager = std::make_unique<WebViewEnvironmentManager>(this);
    inAppWebViewManager = std::make_unique<InAppWebViewManager>(this);
    inAppBrowserManager = std::make_unique<InAppBrowserManager>(this);
    headlessInAppWebViewManager = std::make_unique<HeadlessInAppWebViewManager>(this);
    cookieManager = std::make_unique<CookieManager>(this);
  }

  FlutterInappwebviewWindowsPlugin::~FlutterInappwebviewWindowsPlugin()
  {
    PrepareForShutdown();
    registeredPlugins.erase(registrar);
  }

  void FlutterInappwebviewWindowsPlugin::PrepareForShutdown(flutter::PluginRegistrarWindows* registrar)
  {
    const auto found = registeredPlugins.find(registrar);
    if (found != registeredPlugins.end()) found->second->PrepareForShutdown();
  }

  void FlutterInappwebviewWindowsPlugin::PrepareForShutdown()
  {
    if (prepared_for_shutdown_) return;
    prepared_for_shutdown_ = true;
    // Browser/headless views also borrow the manager's compositor and graphics
    // context. Release their surfaces before shutting down that shared runtime.
    headlessInAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    inAppWebViewManager = nullptr;
    cookieManager = nullptr;
    webViewEnvironmentManager = nullptr;
  }
}
