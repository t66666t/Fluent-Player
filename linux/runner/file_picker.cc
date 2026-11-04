#include "file_picker.h"

#include <cstring>

namespace {
const gchar* string_arg(FlValue* args, const gchar* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value) : nullptr;
}

gboolean bool_arg(FlValue* args, const gchar* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

void respond(GtkDialog* dialog, gint response, gpointer data) {
  FlMethodCall* call = FL_METHOD_CALL(data);
  g_autoptr(FlValue) paths = fl_value_new_list();
  if (response == GTK_RESPONSE_ACCEPT) {
    GSList* files = gtk_file_chooser_get_filenames(GTK_FILE_CHOOSER(dialog));
    for (GSList* item = files; item != nullptr; item = item->next) {
      fl_value_append_take(paths, fl_value_new_string(static_cast<gchar*>(item->data)));
    }
    g_slist_free_full(files, g_free);
  }
  fl_method_call_respond_success(call, paths, nullptr);
  gtk_widget_destroy(GTK_WIDGET(dialog));
  g_object_unref(call);
}

void choose(FlMethodChannel*, FlMethodCall* call, gpointer parent) {
  if (g_strcmp0(fl_method_call_get_name(call), "choose") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    fl_method_call_respond_error(call, "invalid_arguments", "Expected chooser options", nullptr, nullptr);
    return;
  }
  const gchar* action_name = string_arg(args, "action");
  GtkFileChooserAction action;
  if (g_strcmp0(action_name, "open") == 0) action = GTK_FILE_CHOOSER_ACTION_OPEN;
  else if (g_strcmp0(action_name, "save") == 0) action = GTK_FILE_CHOOSER_ACTION_SAVE;
  else if (g_strcmp0(action_name, "directory") == 0) action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
  else {
    fl_method_call_respond_error(call, "invalid_action", "Unknown chooser action", nullptr, nullptr);
    return;
  }
  // A GTK dialog works without org.freedesktop.portal.FileChooser. Use an
  // asynchronous response callback instead of nesting gtk_dialog_run in Flutter.
  const gchar* title = string_arg(args, "title");
  if (title == nullptr) {
    title = action == GTK_FILE_CHOOSER_ACTION_SAVE ? "保存文件" :
        action == GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER ? "选择目录" : "打开文件";
  }
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      title, GTK_WINDOW(parent), action,
      "_Cancel", GTK_RESPONSE_CANCEL,
      action == GTK_FILE_CHOOSER_ACTION_SAVE ? "_Save" : "_Open", GTK_RESPONSE_ACCEPT,
      nullptr);
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
  gtk_file_chooser_set_local_only(chooser, TRUE);
  gtk_file_chooser_set_select_multiple(chooser,
      action == GTK_FILE_CHOOSER_ACTION_OPEN && bool_arg(args, "multiple"));
  if (action == GTK_FILE_CHOOSER_ACTION_SAVE)
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
  const gchar* folder = string_arg(args, "directory");
  if (folder != nullptr && g_path_is_absolute(folder)) gtk_file_chooser_set_current_folder(chooser, folder);
  const gchar* name = string_arg(args, "name");
  if (action == GTK_FILE_CHOOSER_ACTION_SAVE && name != nullptr) gtk_file_chooser_set_current_name(chooser, name);
  FlValue* extensions = fl_value_lookup_string(args, "extensions");
  if (extensions != nullptr && fl_value_get_type(extensions) == FL_VALUE_TYPE_LIST &&
      fl_value_get_length(extensions) > 0 && action != GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER) {
    GtkFileFilter* filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Supported files");
    for (size_t i = 0; i < fl_value_get_length(extensions); ++i) {
      FlValue* extension = fl_value_get_list_value(extensions, i);
      if (fl_value_get_type(extension) != FL_VALUE_TYPE_STRING) continue;
      const gchar* text = fl_value_get_string(extension);
      if (strchr(text, '/') != nullptr || strchr(text, '\\') != nullptr) continue;
      g_autofree gchar* pattern = g_strdup_printf("*.%s", text);
      gtk_file_filter_add_pattern(filter, pattern);
    }
    gtk_file_chooser_add_filter(chooser, filter);
    GtkFileFilter* all = gtk_file_filter_new();
    gtk_file_filter_set_name(all, "All files");
    gtk_file_filter_add_pattern(all, "*");
    gtk_file_chooser_add_filter(chooser, all);
  }
  g_signal_connect(dialog, "response", G_CALLBACK(respond), g_object_ref(call));
  gtk_widget_show(dialog);
}
}  // namespace

FlMethodChannel* register_file_picker(FlView* view, GtkWindow* window) {
  g_autoptr(FlPluginRegistrar) registrar = fl_plugin_registry_get_registrar_for_plugin(
      FL_PLUGIN_REGISTRY(view), "FluentFilePicker");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "io.github.t66666t.FluentPlayer/files", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, choose, window, nullptr);
  return channel;
}
