#ifndef RUNNER_DESKTOP_MEDIA_CONTROLS_H_
#define RUNNER_DESKTOP_MEDIA_CONTROLS_H_
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
struct LinuxDesktopMedia;
LinuxDesktopMedia* register_desktop_media(FlView* view, GtkWindow* window);
void unregister_desktop_media(LinuxDesktopMedia* media);
#endif
