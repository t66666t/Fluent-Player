"""Opt-in native mpv seek probe, isolated from flutter_tester's FFI runtime."""
import ctypes
import json
import os
import sys
import time

library, url, target, options = sys.argv[1:]
target = float(target)
dll_directory = os.add_dll_directory(os.path.dirname(library))
mpv = ctypes.CDLL(library)
mpv.mpv_create.restype = ctypes.c_void_p
mpv.mpv_initialize.argtypes = [ctypes.c_void_p]
mpv.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
mpv.mpv_set_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
mpv.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
mpv.mpv_get_property_string.restype = ctypes.c_void_p
mpv.mpv_free.argtypes = [ctypes.c_void_p]
mpv.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
mpv.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
handle = mpv.mpv_create()

def prop(name):
    pointer = mpv.mpv_get_property_string(handle, name.encode())
    if not pointer:
        return ""
    try:
        return ctypes.string_at(pointer).decode()
    finally:
        mpv.mpv_free(pointer)

def command(*arguments):
    values = (ctypes.c_char_p * (len(arguments) + 1))()
    for index, argument in enumerate(arguments):
        values[index] = str(argument).encode()
    result = mpv.mpv_command(handle, values)
    if result < 0:
        raise RuntimeError(f"command failed: {arguments[0]} ({result})")

try:
    settings = {"vo": "null", "ao": "null", "config": "no", "terminal": "no", "pause": "yes", **json.loads(options)}
    for name, value in settings.items():
        result = mpv.mpv_set_option_string(handle, name.encode(), str(value).encode())
        if result < 0:
            raise RuntimeError(f"option rejected: {name} ({result})")
    if mpv.mpv_initialize(handle) < 0:
        raise RuntimeError("mpv initialization failed")
    command("loadfile", url)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if float(prop("duration") or 0) > target:
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("media open timed out")
    print(json.dumps({"event": "seek-start"}), flush=True)
    sys.stdin.readline()
    started = time.monotonic()
    command("seek", target, "absolute+exact")
    mpv.mpv_set_property_string(handle, b"pause", b"no")
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        position = float(prop("time-pos") or 0)
        if target + 1 <= position <= target + 10:
            print(json.dumps({"event": "result", "seekMs": round((time.monotonic() - started) * 1000), "position": position, "streamPos": prop("stream-pos"), "duration": prop("duration")}), flush=True)
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("seek did not advance to target: " + str({key: prop(key) for key in ["time-pos", "duration", "pause", "idle-active", "eof-reached", "paused-for-cache", "seeking", "seekable"]}))
finally:
    mpv.mpv_terminate_destroy(handle)
