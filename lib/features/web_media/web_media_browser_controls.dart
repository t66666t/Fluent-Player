import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Keep the installed engine version while changing its device identity.
String webMediaBrowserUserAgent(String native, {required bool desktop}) {
  if (desktop) {
    if (!RegExp(r'Android|Mobile|iPhone|iPad').hasMatch(native)) return native;
    if (native.contains('Chrome/')) {
      return native
          .replaceFirst(RegExp(r'\([^)]*\)'), '(Windows NT 10.0; Win64; x64)')
          .replaceAll(' Mobile', '')
          .replaceAll(RegExp(r' Version/[^ ]+'), '');
    }
    return native
        .replaceFirst(
          RegExp(r'\([^)]*\)'),
          '(Macintosh; Intel Mac OS X 10_15_7)',
        )
        .replaceAll(RegExp(r' Mobile/[^ ]+'), '');
  }
  if (RegExp(r'Android|iPhone').hasMatch(native)) return native;
  if (native.contains('Chrome/')) {
    return native
        .replaceFirst(RegExp(r'\([^)]*\)'), '(Linux; Android 13; Mobile)')
        .replaceFirst(' Safari/', ' Mobile Safari/');
  }
  return native
      .replaceFirst(
        RegExp(r'\([^)]*\)'),
        '(iPhone; CPU iPhone OS 16_0 like Mac OS X)',
      )
      .replaceFirst(' Safari/', ' Mobile/15E148 Safari/');
}

InAppWebViewSettings webMediaBrowserDisplaySettings({
  required bool desktop,
  required String nativeAgent,
}) => InAppWebViewSettings(
  userAgent: webMediaBrowserUserAgent(nativeAgent, desktop: desktop),
  preferredContentMode: desktop
      ? UserPreferredContentMode.DESKTOP
      : UserPreferredContentMode.MOBILE,
  useWideViewPort: desktop,
  loadWithOverviewMode: desktop,
  supportZoom: true,
);

/// Native WebViews keep their own selection, editing and popup key handling.
/// Only an Escape left unclaimed by the document may navigate the browser.
const fluentBrowserBackScript = r'''
(() => {
  if (window.__fluentBrowserBackInstalled) return;
  window.__fluentBrowserBackInstalled = true;
  const ownsEscape = () => {
    if (document.fullscreenElement || document.webkitFullscreenElement) return true;
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) {
      active = active.shadowRoot.activeElement;
    }
    // Includes a hardware keyboard on a phone and a touch-focused desktop
    // editor. An iframe handles Escape in its own document, including origins
    // whose selection the outer document is not allowed to inspect.
    if (active && (active.isContentEditable ||
        /^(INPUT|TEXTAREA|SELECT|IFRAME|FRAME)$/.test(active.tagName) ||
        /^(textbox|combobox|listbox)$/.test(active.getAttribute('role') || ''))) return true;
    const visible = node => node.getClientRects().length > 0;
    if (Array.from(document.querySelectorAll('dialog[open], [role="dialog"][aria-modal="true"]')).some(visible)) return true;
    try {
      if (Array.from(document.querySelectorAll(':popover-open')).some(visible)) return true;
    } catch (_) {} // Older WebViews do not have the popover selector.
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed && selection.rangeCount > 0) {
      selection.removeAllRanges();
      return true;
    }
    return false;
  };
  window.__fluentBrowserOwnsEscape = ownsEscape;
  window.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || event.repeat || event.isComposing || event.defaultPrevented ||
        event.ctrlKey || event.altKey || event.metaKey || event.shiftKey) return;
    if (ownsEscape()) return;
    // The site may have a later listener on window. Wait until dispatch is
    // complete so its preventDefault() can still keep navigation on the page.
    queueMicrotask(() => {
      if (event.defaultPrevented) return;
      if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return;
      window.flutter_inappwebview.callHandler('fluentBrowserBack');
    });
  });
})();
''';

/// Flutter chrome uses the same guard when it, rather than the native page,
/// owns keyboard focus. Missing/unresponsive page code must not navigate.
const fluentBrowserEscapeGuardScript =
    'window.__fluentBrowserOwnsEscape ? window.__fluentBrowserOwnsEscape() : true';

/// A desktop request also needs a desktop viewport on a phone, even when the
/// website's original meta tag says width=device-width.
const fluentBrowserDesktopViewportScript = r'''
(() => {
  const apply = () => {
    if (!document.head) return;
    let meta = document.querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'viewport';
      document.head.appendChild(meta);
    }
    meta.content = 'width=1280';
  };
  apply();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', apply, {once: true});
  }
})();
''';
