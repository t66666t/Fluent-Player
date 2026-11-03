#include "clipboard_revision.h"

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>
#include <string>

namespace {

struct ClipboardMetadata {
  GtkClipboard* clipboard;
  std::string scope;
  bool persistent;
  bool x11;
};

struct TimestampRequest {
  FlMethodCall* call;
  std::string scope;
  bool persistent;
};

void timestamp_received(GtkClipboard*, GtkSelectionData* data, gpointer user_data) {
  auto* request = static_cast<TimestampRequest*>(user_data);
  g_autoptr(FlValue) value = nullptr;
  if (gtk_selection_data_get_format(data) == 32 &&
      gtk_selection_data_get_length(data) >= static_cast<gint>(sizeof(guint32))) {
    guint32 timestamp = 0;
    std::memcpy(&timestamp, gtk_selection_data_get_data(data), sizeof(timestamp));
    if (timestamp != GDK_CURRENT_TIME) {
      value = fl_value_new_map();
      const std::string token = request->scope + "/" + std::to_string(timestamp);
      fl_value_set_string_take(value, "token", fl_value_new_string(token.c_str()));
      fl_value_set_string_take(value, "persistent", fl_value_new_bool(request->persistent));
    }
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(request->call, response, nullptr);
  g_object_unref(request->call);
  delete request;
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* metadata = static_cast<ClipboardMetadata*>(user_data);
  if (g_strcmp0(fl_method_call_get_name(call), "getRevision") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  if (!metadata->x11) {
    // Wayland can re-offer an unchanged selection on every focus change. Those
    // events cannot safely be treated as new copies. Use content fallback.
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  auto* request = new TimestampRequest{
      FL_METHOD_CALL(g_object_ref(call)), metadata->scope, metadata->persistent};
  gtk_clipboard_request_contents(metadata->clipboard,
      gdk_atom_intern_static_string("TIMESTAMP"), timestamp_received, request);
}

}  // namespace

FlMethodChannel* register_clipboard_revision(FlView* view) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(
          FL_PLUGIN_REGISTRY(view), "ClipboardRevision");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.example.video_player_app/clipboard_revision", FL_METHOD_CODEC(codec));
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(view));
  bool x11 = false;
#ifdef GDK_WINDOWING_X11
  x11 = GDK_IS_X11_DISPLAY(display);
#endif
  gchar* boot = nullptr;
  const bool persistent = g_file_get_contents(
      "/proc/sys/kernel/random/boot_id", &boot, nullptr, nullptr) != FALSE;
  g_autofree gchar* process_scope = g_uuid_string_random();
  const std::string scope = std::string("linux/x11/") +
      (persistent ? g_strstrip(boot) : process_scope) + "/" + gdk_display_get_name(display);
  g_free(boot);
  auto* metadata = new ClipboardMetadata{
      gtk_clipboard_get_for_display(display, GDK_SELECTION_CLIPBOARD),
      scope, persistent, x11};
  fl_method_channel_set_method_call_handler(channel, method_call, metadata,
      [](gpointer value) { delete static_cast<ClipboardMetadata*>(value); });
  return channel;
}
