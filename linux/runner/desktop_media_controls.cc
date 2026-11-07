#include "desktop_media_controls.h"
#include <gio/gio.h>
#include <unistd.h>
#include <string>

namespace {
constexpr const char* kPath = "/org/mpris/MediaPlayer2";
constexpr const char* kPlayer = "org.mpris.MediaPlayer2.Player";
constexpr const char* kRoot = "org.mpris.MediaPlayer2";
constexpr const char* kSchema = R"XML(<node>
<interface name='org.mpris.MediaPlayer2'>
 <method name='Raise'/><method name='Quit'/>
 <property name='CanQuit' type='b' access='read'/><property name='CanRaise' type='b' access='read'/>
 <property name='HasTrackList' type='b' access='read'/><property name='Identity' type='s' access='read'/>
 <property name='DesktopEntry' type='s' access='read'/>
 <property name='SupportedUriSchemes' type='as' access='read'/><property name='SupportedMimeTypes' type='as' access='read'/>
</interface>
<interface name='org.mpris.MediaPlayer2.Player'>
 <method name='Next'/><method name='Previous'/><method name='Pause'/><method name='PlayPause'/><method name='Stop'/><method name='Play'/>
 <method name='Seek'><arg direction='in' name='Offset' type='x'/></method>
 <method name='SetPosition'><arg direction='in' name='TrackId' type='o'/><arg direction='in' name='Position' type='x'/></method>
 <method name='OpenUri'><arg direction='in' name='Uri' type='s'/></method>
 <property name='PlaybackStatus' type='s' access='read'/><property name='Metadata' type='a{sv}' access='read'/>
 <property name='Rate' type='d' access='readwrite'/><property name='MinimumRate' type='d' access='read'/><property name='MaximumRate' type='d' access='read'/>
 <property name='Volume' type='d' access='readwrite'/><property name='Position' type='x' access='read'/>
 <property name='CanGoNext' type='b' access='read'/><property name='CanGoPrevious' type='b' access='read'/>
 <property name='CanPlay' type='b' access='read'/><property name='CanPause' type='b' access='read'/>
 <property name='CanSeek' type='b' access='read'/><property name='CanControl' type='b' access='read'/>
</interface></node>)XML";
}  // namespace

struct LinuxDesktopMedia {
  FlMethodChannel* channel = nullptr;
  FlValue* state = nullptr;
  GtkWindow* window = nullptr;
  GDBusConnection* bus = nullptr;
  GDBusNodeInfo* schema = nullptr;
  guint registration[2] = {}, owner = 0;
  std::string error;

  bool flag(const char* name) const {
    FlValue* value = state ? fl_value_lookup_string(state, name) : nullptr;
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
  }
  const char* text(const char* name) const {
    FlValue* value = state ? fl_value_lookup_string(state, name) : nullptr;
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
  }
  gint64 number(const char* name) const {
    FlValue* value = state ? fl_value_lookup_string(state, name) : nullptr;
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_INT ? fl_value_get_int(value) : 0;
  }
  double decimal(const char* name, double fallback) const {
    FlValue* value = state ? fl_value_lookup_string(state, name) : nullptr;
    return value && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT ? fl_value_get_float(value) : fallback;
  }
  bool enabled() const { return flag("active") && flag("systemEnabled"); }
  void send(const char* command, const char* field = nullptr, double value = 0) {
    if (!enabled() || !flag("canPlay")) return;
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "command", fl_value_new_string(command));
    fl_value_set_string_take(args, "source", fl_value_new_string("system"));
    if (field) fl_value_set_string_take(args, field, fl_value_new_float(value));
    fl_method_channel_invoke_method(channel, "command", args, nullptr, nullptr, nullptr);
  }
  GVariant* property(const gchar* interface, const gchar* name) const {
    const std::string key(name);
    if (g_str_equal(interface, kRoot)) {
      if (key == "Identity") return g_variant_new_string("Fluent Player");
      if (key == "DesktopEntry") return g_variant_new_string(APPLICATION_ID);
      if (key == "SupportedUriSchemes" || key == "SupportedMimeTypes") return g_variant_new_strv(nullptr, 0);
      return g_variant_new_boolean(key == "CanRaise");
    }
    const bool control = enabled() && flag("canPlay");
    if (key == "PlaybackStatus") return g_variant_new_string(!enabled() ? "Stopped" : flag("playing") ? "Playing" : "Paused");
    if (key == "CanGoNext") return g_variant_new_boolean(control && flag("canNext"));
    if (key == "CanGoPrevious") return g_variant_new_boolean(control && flag("canPrevious"));
    if (key == "CanControl" || key == "CanPlay" || key == "CanPause") return g_variant_new_boolean(control);
    if (key == "CanSeek") return g_variant_new_boolean(FALSE);
    if (key == "Rate") return g_variant_new_double(decimal("rate", 1));
    if (key == "MinimumRate") return g_variant_new_double(0.25);
    if (key == "MaximumRate") return g_variant_new_double(5);
    if (key == "Volume") return g_variant_new_double(decimal("volume", 1));
    if (key == "Position") return g_variant_new_int64(number("positionMs") * 1000);
    if (key == "Metadata") {
      GVariantBuilder metadata;
      g_variant_builder_init(&metadata, G_VARIANT_TYPE("a{sv}"));
      if (enabled()) {
        g_autofree gchar* hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, text("itemId"), -1);
        const std::string track = std::string(kPath) + "/track/" + hash;
        g_variant_builder_add(&metadata, "{sv}", "mpris:trackid", g_variant_new_object_path(track.c_str()));
        g_variant_builder_add(&metadata, "{sv}", "mpris:length", g_variant_new_int64(number("durationMs") * 1000));
        g_variant_builder_add(&metadata, "{sv}", "xesam:title", g_variant_new_string(text("title")));
        const gchar* artists[] = {text("subtitle"), nullptr};
        g_variant_builder_add(&metadata, "{sv}", "xesam:artist", g_variant_new_strv(artists, -1));
        if (*text("artworkUri")) g_variant_builder_add(&metadata, "{sv}", "mpris:artUrl", g_variant_new_string(text("artworkUri")));
      }
      return g_variant_builder_end(&metadata);
    }
    return nullptr;
  }
  FlValue* status() const {
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "systemMedia", fl_value_new_bool(bus && registration[0] && registration[1]));
    fl_value_set_string_take(map, "taskbar", fl_value_new_bool(FALSE));
    // Desktop shortcut configuration belongs to the compositor (Wayland/X11).
    fl_value_set_string_take(map, "globalHotkeys", fl_value_new_bool(FALSE));
    fl_value_set_string_take(map, "error", fl_value_new_string(error.c_str()));
    return map;
  }
  void update() {
    if (!bus || !registration[0] || !registration[1]) return;
    if (enabled() && !owner) {
      const auto name = std::string("org.mpris.MediaPlayer2.") + APPLICATION_ID + ".instance" + std::to_string(getpid());
      owner = g_bus_own_name_on_connection(bus, name.c_str(), G_BUS_NAME_OWNER_FLAGS_NONE, nullptr, nullptr, nullptr, nullptr);
    } else if (!enabled() && owner) { g_bus_unown_name(owner); owner = 0; }
    GVariantBuilder changed;
    g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
    for (const auto name : {"PlaybackStatus", "Metadata", "Rate", "Volume", "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanControl"}) {
      g_variant_builder_add(&changed, "{sv}", name, property(kPlayer, name));
    }
    g_dbus_connection_emit_signal(bus, nullptr, kPath, "org.freedesktop.DBus.Properties", "PropertiesChanged",
        g_variant_new("(sa{sv}as)", kPlayer, &changed, nullptr), nullptr);
  }
};

namespace {
void dbus_method(GDBusConnection*, const gchar*, const gchar*, const gchar* interface, const gchar* method,
                 GVariant*, GDBusMethodInvocation* invocation, gpointer data) {
  auto* self = static_cast<LinuxDesktopMedia*>(data);
  const std::string name(method);
  if (g_str_equal(interface, kRoot)) {
    if (name == "Raise") gtk_window_present(self->window);
    else { g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_NOT_SUPPORTED, "Quit is not supported"); return; }
  } else if (name == "OpenUri") {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_NOT_SUPPORTED, "OpenUri is not supported"); return;
  } else {
    if (name == "Next" && self->flag("canNext")) self->send("next");
    else if (name == "Previous" && self->flag("canPrevious")) self->send("previous");
    else if (name == "PlayPause") self->send("playPause");
    else if (name == "Play") self->send("play");
    else if (name == "Pause") self->send("pause");
    else if (name == "Stop") self->send("stop");
    // Seek/SetPosition deliberately do nothing while CanSeek is false.
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
}
GVariant* dbus_get(GDBusConnection*, const gchar*, const gchar*, const gchar* interface, const gchar* name, GError**, gpointer data) {
  return static_cast<LinuxDesktopMedia*>(data)->property(interface, name);
}
gboolean dbus_set(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* name, GVariant* value, GError** error, gpointer data) {
  auto* self = static_cast<LinuxDesktopMedia*>(data);
  const double number = g_variant_get_double(value);
  if (g_str_equal(name, "Rate") && number >= 0.25 && number <= 5) self->send("setRate", "rate", number);
  else if (g_str_equal(name, "Volume") && number >= 0) self->send("setVolume", "volume", number > 1 ? 1 : number);
  else { g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Unsupported property value"); return FALSE; }
  return TRUE;
}
const GDBusInterfaceVTable kVtable = {dbus_method, dbus_get, dbus_set, {nullptr}};
void method_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<LinuxDesktopMedia*>(data);
  const std::string method(fl_method_call_get_name(call));
  if (method == "initialize") {
    if (!self->bus) {
      g_autoptr(GError) error = nullptr;
      self->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
      if (self->bus) {
        self->schema = g_dbus_node_info_new_for_xml(kSchema, &error);
        if (self->schema) for (int i = 0; i < 2; ++i) {
          self->registration[i] = g_dbus_connection_register_object(self->bus, kPath, self->schema->interfaces[i], &kVtable, self, nullptr, &error);
          if (error) break;
        }
      }
      if (error) self->error = error->message;
    }
  } else if (method == "update") {
    FlValue* args = fl_method_call_get_args(call);
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      if (self->state) fl_value_unref(self->state);
      self->state = fl_value_ref(args);
      self->update();
    }
  } else if (method == "dispose") {
    if (self->state) fl_value_unref(self->state);
    self->state = nullptr;
    self->update();
  } else { fl_method_call_respond_not_implemented(call, nullptr); return; }
  g_autoptr(FlValue) status = self->status();
  fl_method_call_respond_success(call, status, nullptr);
}
}  // namespace

LinuxDesktopMedia* register_desktop_media(FlView* view, GtkWindow* window) {
  auto* self = new LinuxDesktopMedia();
  self->window = window;
  g_autoptr(FlPluginRegistrar) registrar = fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "DesktopMediaControls");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "com.example.video_player_app/desktop_media", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call, self, nullptr);
  return self;
}

void unregister_desktop_media(LinuxDesktopMedia* self) {
  if (!self) return;
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr, nullptr);
  if (self->owner) g_bus_unown_name(self->owner);
  if (self->bus) for (const auto id : self->registration) if (id) g_dbus_connection_unregister_object(self->bus, id);
  if (self->state) fl_value_unref(self->state);
  if (self->schema) g_dbus_node_info_unref(self->schema);
  g_clear_object(&self->bus);
  g_clear_object(&self->channel);
  delete self;
}
