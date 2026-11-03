"""Prepare Linux-only plugin lists without changing Flutter output or Pub cache."""
import argparse
from pathlib import Path
import re


def configure(source, destination):
    cmake = (source / 'generated_plugins.cmake').read_text(encoding='utf-8')
    registrant = (source / 'generated_plugin_registrant.cc').read_text(encoding='utf-8')
    # Linux uses FFmpegUtils / Process, with FFmpeg & ffprobe shipped alongside
    # the app. The FFmpegKit prebuilt targets another distribution's SONAMEs.
    if re.search(r'^\s+ffmpeg_kit_flutter_new\s*$', cmake, re.M):
        cmake = re.sub(r'^\s+ffmpeg_kit_flutter_new\s*\n', '', cmake, flags=re.M)
        registrant, includes = re.subn(r'^#include <ffmpeg_kit_flutter_new/[^>]+>\n', '', registrant, flags=re.M)
        registrant, registrations = re.subn(
            r'  g_autoptr\(FlPluginRegistrar\) ffmpeg_kit_flutter_new_registrar =\n'
            r'      fl_plugin_registry_get_registrar_for_plugin\(registry, "[^"]+"\);\n'
            r'  \w+_register_with_registrar\(ffmpeg_kit_flutter_new_registrar\);\n', '', registrant)
        if includes != 1 or registrations != 1:
            raise ValueError('Flutter FFmpegKit registration format changed; update the Linux adapter')
    if 'ffmpeg_kit_flutter_new' in cmake or 'ffmpeg_kit_flutter_new' in registrant:
        raise ValueError('FFmpegKit still appears in the Linux native plugin graph')
    registrant = registrant.replace('#include "generated_plugin_registrant.h"',
                                    '#include "flutter/generated_plugin_registrant.h"')
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'plugins.cmake').write_text(cmake, encoding='utf-8', newline='\n')
    (destination / 'plugin_registrant.cc').write_text(registrant, encoding='utf-8', newline='\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    configure(args.source, args.destination)
