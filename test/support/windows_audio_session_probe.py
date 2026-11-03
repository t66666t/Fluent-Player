"""Read a test process's WASAPI sessions; never change device/session state."""
import ctypes as c
import json
import sys
import uuid


class Guid(c.Structure):
    _fields_ = [('data', c.c_ubyte * 16)]

    @classmethod
    def make(cls, value):
        return cls.from_buffer_copy(uuid.UUID(value).bytes_le)


def invoke(pointer, slot, types, *arguments):
    table = c.cast(pointer, c.POINTER(c.POINTER(c.c_void_p))).contents
    function = c.WINFUNCTYPE(c.c_long, c.c_void_p, *types)(table[slot])
    return function(pointer, *arguments)


def session_states(process_id):
    ole = c.OleDLL('ole32')
    ole.CoInitializeEx.argtypes = [c.c_void_p, c.c_ulong]
    ole.CoInitializeEx.restype = c.c_long
    ole.CoCreateInstance.argtypes = [
        c.POINTER(Guid), c.c_void_p, c.c_ulong,
        c.POINTER(Guid), c.POINTER(c.c_void_p),
    ]
    ole.CoCreateInstance.restype = c.c_long
    initialized = ole.CoInitializeEx(None, 0) >= 0
    references = []

    def receive(operation):
        pointer = c.c_void_p()
        result = operation(c.byref(pointer))
        if result < 0:
            raise OSError(f'Audio session query failed: {result & 0xffffffff:08x}')
        references.append(pointer)
        return pointer

    try:
        enumerator = receive(lambda output: ole.CoCreateInstance(
            c.byref(Guid.make('bcde0395-e52f-467c-8e3d-c4579291692e')), None, 23,
            c.byref(Guid.make('a95664d2-9614-4f35-a746-de8db63617e6')), output))
        device = receive(lambda output: invoke(
            enumerator, 4, [c.c_int, c.c_int, c.POINTER(c.c_void_p)], 0, 1, output))
        manager = receive(lambda output: invoke(
            device, 3, [c.POINTER(Guid), c.c_ulong, c.c_void_p, c.POINTER(c.c_void_p)],
            c.byref(Guid.make('77aa99a0-1bd6-484f-8bc7-2c654c9a9b6f')), 23, None, output))
        sessions = receive(lambda output: invoke(
            manager, 5, [c.POINTER(c.c_void_p)], output))
        count = c.c_int()
        if invoke(sessions, 3, [c.POINTER(c.c_int)], c.byref(count)) < 0:
            raise OSError('Audio session count unavailable')
        states = []
        for index in range(count.value):
            session = receive(lambda output: invoke(
                sessions, 4, [c.c_int, c.POINTER(c.c_void_p)], index, output))
            control = receive(lambda output: invoke(
                session, 0, [c.POINTER(Guid), c.POINTER(c.c_void_p)],
                c.byref(Guid.make('bfb7ff88-7239-4fc9-8fa2-07c950be9c6d')), output))
            owner = c.c_ulong()
            if invoke(control, 14, [c.POINTER(c.c_ulong)], c.byref(owner)) < 0:
                continue
            if owner.value == process_id:
                state = c.c_int()
                if invoke(control, 3, [c.POINTER(c.c_int)], c.byref(state)) >= 0:
                    states.append({0: 'inactive', 1: 'active', 2: 'expired'}[state.value])
        return states
    finally:
        for pointer in reversed(references):
            invoke(pointer, 2, [])
        if initialized:
            ole.CoUninitialize()


if __name__ == '__main__':
    print(json.dumps(session_states(int(sys.argv[1]))))
