# Windows composition shutdown

The local JavaScript null-response and composition lifetime fixes are retained.
Community media observation is removed; see LOCAL_CHANGES.md for the aligned
platform-interface migration and disabled network-capture APIs.

The plugin's shared compositor, graphics context, dispatcher queue and WinRT
helper used to survive until DLL static destruction. They are now released by
the final WebView manager on its platform thread while COM and a message pump
still exist. The Windows runner invokes a per-registrar, idempotent exported
`PrepareForShutdown` before resetting its Flutter controller: the engine's
messenger must still be valid when channels unregister, rather than waiting for
Flutter's later plugin-destructor phase. Browser/headless surfaces are destroyed
first. This preparation runs both for HWND destruction and from the derived
Flutter window destructor: `window_manager.destroy` can post `WM_QUIT` directly,
so waiting for `WM_DESTROY` would miss that normal exit path. The compositor is
closed before the graphics context; dispatcher shutdown is awaited while
dispatching messages before releasing the queue and its WinRT helper.

Before that message pump starts, the disposing manager disconnects its method
handler and clears its own plugin pointer, rejecting new creates and in-flight
creation completions without invalidating another manager's shared runtime.
View method/event handlers and other channel delegates unregister before their
owners are released, so queued Dart messages cannot re-enter freed view objects.
Asynchronous environment creation in texture, headless and browser owners also
captures a weak lifetime token and checks it before accessing its owner. Late
completions close their returned controller without touching a destroyed owner
or replying through a destroyed engine. Channel replacement releases the old
delegate before registering another handler under the same name.

The Windows runner's COM apartment also outlives its Flutter window/engine.
This removes teardown work from Windows' loader lock instead of suppressing an
exception or terminating the process early.

Microsoft documents the asynchronous completion and thread event-loop contract
for [DispatcherQueueController.ShutdownQueueAsync](https://learn.microsoft.com/en-us/uwp/api/windows.system.dispatcherqueuecontroller.shutdownqueueasync).
The isolated application validation entry is `scripts/windows_exit_validation.dart`.
