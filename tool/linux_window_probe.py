"""X11 frame capture for CI, using the distro's python3-gi (no app code hooks)."""
import json
from pathlib import Path
import sys

import gi
gi.require_version('Gdk', '3.0')
gi.require_version('GdkX11', '3.0')
from gi.repository import Gdk, GdkX11

display = Gdk.Display.get_default()
window = GdkX11.X11Window.foreign_new_for_display(display, int(sys.argv[1]))
width, height = window.get_width(), window.get_height()
pixbuf = Gdk.pixbuf_get_from_window(window, 0, 0, width, height)
if pixbuf is None:
    raise RuntimeError('The application has no readable frame')
pixels, stride, channels = pixbuf.get_pixels(), pixbuf.get_rowstride(), pixbuf.get_n_channels()
colors = {bytes(pixels[y * stride + x * channels:y * stride + x * channels + 3])
          for y in range(height // 5, height * 4 // 5, max(1, height // 40))
          for x in range(width // 5, width * 4 // 5, max(1, width // 40))}
target = Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)
pixbuf.savev(str(target), 'png', [], [])
if len(colors) < 4:
    raise RuntimeError('The central application frame is blank or not painted')
print(json.dumps({'width': width, 'height': height, 'sampleColors': len(colors)}))
