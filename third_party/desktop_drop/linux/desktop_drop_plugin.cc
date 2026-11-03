#include "include/desktop_drop/desktop_drop_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <stdlib.h>
#include <cstring>

// Based on desktop_drop 0.7.1 (Mixin, Apache-2.0). See LOCAL_CHANGES.md.
#define DESKTOP_DROP_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), desktop_drop_plugin_get_type(), DesktopDropPlugin))

struct _DesktopDropPlugin { GObject parent_instance; };
G_DEFINE_TYPE(DesktopDropPlugin, desktop_drop_plugin, g_object_get_type())

static gboolean isKDE = FALSE;
static gboolean ignoreNext = FALSE;

static GdkAtom text_target(GtkWidget* widget, GdkDragContext* context) {
  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_text_targets(targets, 0);
  const auto target = gtk_drag_dest_find_target(widget, context, targets);
  gtk_target_list_unref(targets);
  return target;
}

static bool has_uri_target(GdkDragContext* context) {
  return g_list_find(gdk_drag_context_list_targets(context),
                    GDK_ATOM_TO_POINTER(gdk_atom_intern_static_string("text/uri-list"))) != nullptr;
}

static FlValue* position(gint x, gint y) {
  auto* args = fl_value_new_map();
  fl_value_set_string_take(args, "x", fl_value_new_float(x));
  fl_value_set_string_take(args, "y", fl_value_new_float(y));
  return args;
}

static void send_text(FlMethodChannel* channel, gint x, gint y,
                      const gchar* text, const gchar* uri_text) {
  g_autoptr(FlValue) args = position(x, y);
  fl_value_set_string_take(args, "text", fl_value_new_string(text ? text : ""));
  auto* urls = fl_value_new_list();
  if (uri_text) {
    g_auto(GStrv) uris = g_uri_list_extract_uris(uri_text);
    for (gsize i = 0; uris && uris[i]; ++i) {
      if (!g_str_has_prefix(uris[i], "file:"))
        fl_value_append_take(urls, fl_value_new_string(uris[i]));
    }
  }
  fl_value_set_string_take(args, "urls", urls);
  fl_method_channel_invoke_method(channel, "performTextOperation", args, nullptr, nullptr, nullptr);
}

static void on_drag_data_received(GtkWidget* widget, GdkDragContext* context,
                                 gint x, gint y, GtkSelectionData* data, guint info,
                                 guint time, gpointer user_data) {
  auto* channel = static_cast<FlMethodChannel*>(user_data);
  const auto length = gtk_selection_data_get_length(data);
  if (length <= 0 || length > 4 * 1024 * 1024) {
    const auto* uris = static_cast<const gchar*>(
        g_object_get_data(G_OBJECT(context), "desktop-drop-uris"));
    if (length <= 0 && uris) {
      // A browser may advertise plain text but only supply its URL.
      send_text(channel, x, y, nullptr, uris);
      g_object_set_data(G_OBJECT(context), "desktop-drop-uris", nullptr);
      gtk_drag_finish(context, TRUE, FALSE, time);
      return;
    }
    gtk_drag_finish(context, FALSE, FALSE, time);
    return;
  }
  const auto target = gtk_selection_data_get_target(data);
  if (target == gdk_atom_intern_static_string("text/uri-list")) {
    g_autofree gchar* raw = g_strndup(
        reinterpret_cast<const gchar*>(gtk_selection_data_get_data(data)), length);
    if (!g_utf8_validate(raw, -1, nullptr)) {
      gtk_drag_finish(context, FALSE, FALSE, time);
      return;
    }
    g_auto(GStrv) uris = g_uri_list_extract_uris(raw);
    bool files = uris && uris[0];
    for (gsize i = 0; uris && uris[i]; ++i)
      files = files && g_str_has_prefix(uris[i], "file:");
    if (files) {
      g_autoptr(FlValue) args = fl_value_new_list();
      fl_value_append_take(args, fl_value_new_string(raw));
      const double point[] = {double(x), double(y)};
      fl_value_append_take(args, fl_value_new_float_list(point, 2));
      fl_method_channel_invoke_method(channel, "performOperation_linux", args, nullptr, nullptr, nullptr);
    } else {
      const auto plain = text_target(widget, context);
      if (plain != GDK_NONE) {
        // Read the browser's URL and its selected label separately.
        g_object_set_data_full(G_OBJECT(context), "desktop-drop-uris", g_strdup(raw), g_free);
        gtk_drag_get_data(widget, context, plain, time);
        return;
      }
      send_text(channel, x, y, nullptr, raw);
    }
  } else {
    g_autofree gchar* text = reinterpret_cast<gchar*>(gtk_selection_data_get_text(data));
    const auto* uris = static_cast<const gchar*>(
        g_object_get_data(G_OBJECT(context), "desktop-drop-uris"));
    if (!text && !uris) {
      gtk_drag_finish(context, FALSE, FALSE, time);
      return;
    }
    send_text(channel, x, y, text, uris);
    g_object_set_data(G_OBJECT(context), "desktop-drop-uris", nullptr);
  }
  // Copy even when dragging out of an editable browser element.
  gtk_drag_finish(context, TRUE, FALSE, time);
}

static gboolean on_drag_drop(GtkWidget* widget, GdkDragContext* context,
                             gint x, gint y, guint time, gpointer user_data) {
  if (!(gdk_drag_context_get_actions(context) & GDK_ACTION_COPY)) return FALSE;
  const auto target = gtk_drag_dest_find_target(widget, context, nullptr);
  if (target == GDK_NONE) return FALSE;
  gtk_drag_get_data(widget, context, target, time);
  return TRUE;
}

static gboolean on_drag_motion(GtkWidget* widget, GdkDragContext* context,
                               gint x, gint y, guint time, gpointer user_data) {
  if (ignoreNext) { ignoreNext = FALSE; return FALSE; }
  auto* channel = static_cast<FlMethodChannel*>(user_data);
  if (!has_uri_target(context)) {
    g_autoptr(FlValue) args = position(x, y);
    fl_method_channel_invoke_method(channel, "textUpdated", args, nullptr, nullptr, nullptr);
  } else {
    const double point[] = {double(x), double(y)};
    g_autoptr(FlValue) args = fl_value_new_float_list(point, 2);
    fl_method_channel_invoke_method(channel, "updated", args, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static void on_drag_leave(GtkWidget* widget, GdkDragContext* context, guint time, gpointer user_data) {
  auto* channel = static_cast<FlMethodChannel*>(user_data);
  fl_method_channel_invoke_method(channel, "textExited", nullptr, nullptr, nullptr, nullptr);
  fl_method_channel_invoke_method(channel, "exited", nullptr, nullptr, nullptr, nullptr);
}

static gboolean on_focus_in_event(GtkWidget* widget, GdkEventFocus* event, gpointer user_data) {
  if (isKDE) ignoreNext = TRUE;
  return FALSE;
}

static void desktop_drop_plugin_class_init(DesktopDropPluginClass* klass) {}
static void desktop_drop_plugin_init(DesktopDropPlugin* self) {
  const auto* environment = getenv("XDG_CURRENT_DESKTOP");
  if (environment) {
    g_autofree gchar* lower = g_ascii_strdown(environment, -1);
    isKDE = strstr(lower, "kde") != nullptr || strstr(lower, "plasma") != nullptr;
  }
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  fl_method_call_respond_not_implemented(call, nullptr);
}

void desktop_drop_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto* plugin = DESKTOP_DROP_PLUGIN(g_object_new(desktop_drop_plugin_get_type(), nullptr));
  auto* view = GTK_WIDGET(fl_plugin_registrar_get_view(registrar));
  gtk_drag_dest_set(view, static_cast<GtkDestDefaults>(GTK_DEST_DEFAULT_MOTION | GTK_DEST_DEFAULT_HIGHLIGHT),
                    nullptr, 0, GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(view);
  gtk_drag_dest_add_text_targets(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "desktop_drop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                           g_object_ref(plugin), g_object_unref);
  g_signal_connect(view, "drag-motion", G_CALLBACK(on_drag_motion), channel);
  g_signal_connect(view, "drag-drop", G_CALLBACK(on_drag_drop), channel);
  g_signal_connect(view, "drag-data-received", G_CALLBACK(on_drag_data_received), channel);
  g_signal_connect(view, "drag-leave", G_CALLBACK(on_drag_leave), channel);
  g_signal_connect(view, "focus-in-event", G_CALLBACK(on_focus_in_event), nullptr);
  g_object_unref(plugin);
}
