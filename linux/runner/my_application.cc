#include "my_application.h"
#include "file_picker.h"
#include "desktop_media_controls.h"
#include "clipboard_revision.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* ime_channel;
  FlMethodChannel* file_picker_channel;
  FlMethodChannel* clipboard_revision_channel;
  LinuxDesktopMedia* desktop_media;
  gchar* saved_im_module;
  gboolean im_module_saved;
  gboolean text_input_active;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void on_first_frame(FlView*, gpointer data) {
  GtkWindow* window = GTK_WINDOW(data);
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
}

static void apply_linux_ime(MyApplication* self, gboolean active) {
  GtkSettings* settings = gtk_settings_get_default();
  if (!self->im_module_saved) {
    g_object_get(settings, "gtk-im-module", &self->saved_im_module, nullptr);
    self->im_module_saved = TRUE;
  }
  self->text_input_active = active;
  if (active) {
    g_object_set(settings, "gtk-im-module",
                 self->saved_im_module != nullptr ? self->saved_im_module : "",
                 nullptr);
  } else {
    // gtk-im-context-simple does not compose CJK, so letter shortcuts stay
    // raw while Chinese or English input is selected.
    g_object_set(settings, "gtk-im-module", "gtk-im-context-simple", nullptr);
  }
}

static void ime_method_call_cb(FlMethodChannel* channel,
                               FlMethodCall* method_call,
                               gpointer user_data) {
  (void)channel;
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "setTextInputActive") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    gboolean active = FALSE;
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      active = fl_value_get_bool(args);
    }
    apply_linux_ime(self, active);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static gboolean on_window_focus_in(GtkWidget* widget,
                                   GdkEventFocus* event,
                                   gpointer user_data) {
  (void)widget;
  (void)event;
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->text_input_active) {
    apply_linux_ime(self, FALSE);
  }
  return FALSE;
}

static void register_ime_gate(MyApplication* self, FlView* view) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "ImeShortcutGate");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->ime_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.example.video_player_app/ime_gate", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->ime_channel, ime_method_call_cb,
                                            self, nullptr);
  apply_linux_ime(self, FALSE);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Fluent Player");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Fluent Player");
  }

  gint width = 1280, height = 720;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0)
    monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    width = MIN(width, MAX(320, area.width * 85 / 100));
    height = MIN(height, MAX(240, area.height * 85 / 100));
  }
  gtk_window_set_default_size(window, width, height);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background;
  gdk_rgba_parse(&background, "#121212");
  fl_view_set_background_color(view, &background);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  register_ime_gate(self, view);
  self->clipboard_revision_channel = register_clipboard_revision(view);
  self->file_picker_channel = register_file_picker(view, window);
  self->desktop_media = register_desktop_media(view, window);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(on_window_focus_in),
                   self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
  // Realize without mapping, then show only after Flutter actually paints.
  // Mapping an empty 1280x720 surface and maximizing it used to race the first
  // OpenGL frame on VMs and fractional / multi-monitor desktops.
  g_signal_connect(view, "first-frame", G_CALLBACK(on_first_frame), window);
  gtk_widget_realize(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  unregister_desktop_media(self->desktop_media);
  self->desktop_media = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->saved_im_module, g_free);
  g_clear_object(&self->ime_channel);
  g_clear_object(&self->file_picker_channel);
  g_clear_object(&self->clipboard_revision_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
