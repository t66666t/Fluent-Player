const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname,
  '../lib/features/web_media/web_media_browser_controls.dart'), 'utf8');
const script = source.match(/const fluentBrowserBackScript = r'''([\s\S]*?)''';/)[1];

function fixture() {
  const listeners = [], pending = [], calls = [];
  const selection = {isCollapsed: true, rangeCount: 0,
    removeAllRanges() { this.rangeCount = 0; this.isCollapsed = true; }};
  const document = {activeElement: null, fullscreenElement: null,
    dialogs: [], popovers: [],
    querySelectorAll(selector) {
      return selector === ':popover-open' ? this.popovers : this.dialogs;
    }};
  const window = {getSelection: () => selection,
    addEventListener(name, callback, capture) {
      assert.equal(name, 'keydown');
      assert.notEqual(capture, true, 'page key handlers must run first');
      listeners.push(callback);
    },
    flutter_inappwebview: {callHandler(name) { calls.push(name); }}};
  const context = vm.createContext({window, document,
    queueMicrotask: callback => pending.push(callback)});
  vm.runInContext(script, context);
  return {window, document, selection, calls, context,
    key(overrides = {}) {
      const event = {key: 'Escape', defaultPrevented: false, ...overrides};
      listeners.forEach(callback => callback(event));
      return event;
    },
    flush() { pending.splice(0).forEach(callback => callback()); }};
}

test('Escape cancels text selection without navigating or claiming other keys', () => {
  const f = fixture();
  f.selection.isCollapsed = false;
  f.selection.rangeCount = 1;
  f.key({key: 'c', ctrlKey: true});
  assert.equal(f.selection.rangeCount, 1);
  f.key(); f.flush();
  assert.equal(f.selection.rangeCount, 0);
  assert.deepEqual(f.calls, []);
  f.key(); f.flush();
  assert.deepEqual(f.calls, ['fluentBrowserBack']);
});

test('input, contenteditable, shadow editors and child frames own Escape', () => {
  for (const active of [
    {tagName: 'INPUT'}, {tagName: 'TEXTAREA'}, {tagName: 'SELECT'},
    {isContentEditable: true}, {role: 'combobox'},
    {tagName: 'IFRAME'}, {tagName: 'FRAME'},
    {shadowRoot: {activeElement: {tagName: 'INPUT'}}},
  ]) {
    const f = fixture();
    active.getAttribute ??= name => active[name] ?? null;
    f.document.activeElement = active;
    f.key(); f.flush();
    assert.deepEqual(f.calls, []);
  }
});

test('page dialogs, popovers, fullscreen and IME Escape never go back', () => {
  for (const state of ['dialogs', 'popovers', 'fullscreenElement', 'webkitFullscreenElement', 'ime']) {
    const f = fixture();
    if (state === 'dialogs' || state === 'popovers') {
      f.document[state] = [{getClientRects: () => [{}]}];
    } else if (state !== 'ime') f.document[state] = {};
    f.key({isComposing: state === 'ime'}); f.flush();
    assert.deepEqual(f.calls, [], state);
  }
});

test('a later site handler can prevent navigation; modified/repeated Escape is untouched', () => {
  const f = fixture();
  const event = f.key();
  event.defaultPrevented = true; // e.g. site dismisses its own non-modal menu.
  f.flush();
  for (const modifier of ['repeat', 'ctrlKey', 'altKey', 'metaKey', 'shiftKey']) {
    f.key({[modifier]: true});
  }
  f.flush();
  assert.deepEqual(f.calls, []);
});

test('unsupported popovers, hidden dialogs and repeated script binding stay usable', () => {
  const f = fixture();
  f.document.querySelectorAll = selector => {
    if (selector === ':popover-open') throw new Error('unsupported selector');
    return [{getClientRects: () => []}];
  };
  vm.runInContext(script, f.context);
  f.key(); f.flush();
  assert.deepEqual(f.calls, ['fluentBrowserBack']);
});
