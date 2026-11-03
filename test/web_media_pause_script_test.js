const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(
  path.join(__dirname, '../lib/features/web_media/web_media_scripts.dart'),
  'utf8',
);
const script = source.match(/const fluentMediaPauseScript = r'''([\s\S]*?)''';/)[1];

function root() {
  return {
    media: [],
    elements: [],
    frames: [],
    querySelectorAll(selector) {
      if (selector === 'video,audio') return this.media;
      if (selector === '*') return this.elements;
      if (selector === 'iframe,frame') return this.frames;
      throw new Error(`Unexpected selector: ${selector}`);
    },
  };
}

function media() {
  return { paused: false, calls: 0, pause() { this.paused = true; this.calls++; } };
}

function frame(parent) {
  const document = root();
  const listeners = [];
  const window = { addEventListener(type, handler) {
    assert.equal(type, 'message');
    listeners.push(handler);
  } };
  window.parent = parent ? parent.window : window;
  window.top = parent ? parent.window.top : window;
  const context = vm.createContext({ window, document });
  const result = { window, document, listeners, context };
  if (parent) {
    parent.document.frames.push({
      get contentDocument() { throw new Error('Cross-origin document is inaccessible'); },
      contentWindow: { postMessage(data, targetOrigin) {
        assert.equal(targetOrigin, '*');
        listeners.forEach(handler => handler({ data, source: parent.window }));
      } },
    });
  }
  vm.runInContext(script, context);
  return result;
}

test('pauses main, shadow and nested cross-origin frame media without reading frame documents', () => {
  const top = frame();
  const child = frame(top);
  const grandchild = frame(child);
  const tracks = [media(), media(), media(), media()];
  top.document.media.push(tracks[0]);
  child.document.media.push(tracks[1]);
  grandchild.document.media.push(tracks[2]);
  const shadow = root();
  shadow.media.push(tracks[3]);
  top.document.elements.push({ shadowRoot: shadow });
  top.window.__fluentPauseWebMedia();
  tracks.forEach(track => {
    assert.equal(track.paused, true);
    assert.equal(track.calls, 1);
  });
});

test('reinstall does not duplicate listeners; unrelated or child-to-parent messages do not pause', () => {
  const top = frame();
  const child = frame(top);
  const topMedia = media();
  const childMedia = media();
  top.document.media.push(topMedia);
  child.document.media.push(childMedia);
  vm.runInContext(script, top.context);
  vm.runInContext(script, child.context);
  assert.equal(top.listeners.length, 1);
  assert.equal(child.listeners.length, 1);
  child.listeners[0]({ data: '__fluent_pause_web_media_v1__', source: {} });
  child.listeners[0]({ data: 'an unrelated site message', source: top.window });
  top.listeners[0]({ data: '__fluent_pause_web_media_v1__', source: child.window });
  assert.equal(topMedia.calls, 0);
  assert.equal(childMedia.calls, 0);
  top.window.__fluentPauseWebMedia();
  assert.equal(topMedia.calls, 1);
  assert.equal(childMedia.calls, 1);
});
