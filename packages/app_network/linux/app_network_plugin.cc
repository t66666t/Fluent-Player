#include "include/app_network/app_network_plugin.h"
#include <gio/gio.h>

struct AppNetworkState {
  FlEventChannel* events;
  GNetworkMonitor* monitor;
  gulong monitor_handler;
  gboolean listening;
};

static void network_changed(GNetworkMonitor*, gboolean, gpointer opaque) {
  auto* state = static_cast<AppNetworkState*>(opaque);
  if (state->listening) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    fl_event_channel_send(state->events, value, nullptr, nullptr);
  }
}
static FlMethodErrorResponse* listen(FlEventChannel*, FlValue*, gpointer opaque) {
  static_cast<AppNetworkState*>(opaque)->listening = TRUE; return nullptr;
}
static FlMethodErrorResponse* cancel(FlEventChannel*, FlValue*, gpointer opaque) {
  static_cast<AppNetworkState*>(opaque)->listening = FALSE; return nullptr;
}
static void release(gpointer opaque) {
  auto* state = static_cast<AppNetworkState*>(opaque);
  g_signal_handler_disconnect(state->monitor, state->monitor_handler);
  g_object_unref(state->monitor);
  g_object_unref(state->events);
  delete state;
}
static void resolved(GObject* resolver, GAsyncResult* result, gpointer opaque) {
  auto* call = FL_METHOD_CALL(opaque);
  g_autoptr(GError) error = nullptr;
  g_auto(GStrv) proxies = g_proxy_resolver_lookup_finish(G_PROXY_RESOLVER(resolver), result, &error);
  if (error || !proxies) {
    fl_method_call_respond_error(call, "PROXY_RESOLUTION_FAILED", "无法读取系统代理", nullptr, nullptr);
  } else {
    g_autoptr(FlValue) values = fl_value_new_list();
    for (gchar** proxy = proxies; *proxy; ++proxy) {
      fl_value_append_take(values, fl_value_new_string(g_str_has_prefix(*proxy, "direct://") ? "DIRECT" : *proxy));
    }
    if (fl_value_get_length(values) == 0) fl_value_append_take(values, fl_value_new_string("DIRECT"));
    fl_method_call_respond_success(call, values, nullptr);
  }
  g_object_unref(call);
}
static void method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "resolveProxy") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr); return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* url = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "url") : nullptr;
  if (!url || fl_value_get_type(url) != FL_VALUE_TYPE_STRING) {
    fl_method_call_respond_error(call, "INVALID_URL", "缺少网址", nullptr, nullptr); return;
  }
  // GIO chooses the installed system resolver (e.g. libproxy/GNOME), with the
  // documented dummy/direct resolver when no desktop proxy backend is installed.
  GProxyResolver* resolver = g_proxy_resolver_get_default();
  g_proxy_resolver_lookup_async(resolver, fl_value_get_string(url), nullptr, resolved, g_object_ref(call));
}
void app_network_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) methods = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
    "com.example.video_player_app/network", FL_METHOD_CODEC(codec));
  auto* state = new AppNetworkState{};
  state->events = fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
    "com.example.video_player_app/network_events", FL_METHOD_CODEC(codec));
  state->monitor = G_NETWORK_MONITOR(g_object_ref(g_network_monitor_get_default()));
  state->monitor_handler = g_signal_connect(state->monitor, "network-changed", G_CALLBACK(network_changed), state);
  fl_event_channel_set_stream_handlers(state->events, listen, cancel, state, nullptr);
  fl_method_channel_set_method_call_handler(methods, method, state, release);
}
