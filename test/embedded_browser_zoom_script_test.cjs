const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname,
  '../lib/widgets/embedded_browser_view.dart'), 'utf8');
const script = source.match(/const embeddedBrowserZoomScript = r'''([\s\S]*?)''';/)[1];

function fixture(content, readyState = 'complete') {
  let meta = content == null ? null : {name: 'viewport', content};
  const observers = [], listeners = {};
  const head = {
    querySelector() { return meta; },
    appendChild(node) { meta = node; },
  };
  const document = {
    head, readyState,
    createElement() { return {name: '', content: ''}; },
    addEventListener(type, callback) { listeners[type] = callback; },
  };
  const window = {};
  class MutationObserver {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(target, options) {
      assert.equal(target, head);
      assert.equal(options.characterData, undefined);
      assert.deepEqual(Array.from(options.attributeFilter), ['content', 'name']);
    }
  }
  const context = vm.createContext({document, window, MutationObserver});
  vm.runInContext(script, context);
  return {document, observers, listeners, context, get meta() { return meta; }};
}

test('pinch override preserves desktop layout and initial scale while unlocking zoom', () => {
  const f = fixture('width=1280, initial-scale=0.5, user-scalable=no, maximum-scale=1, minimum-scale=1');
  assert.match(f.meta.content, /width=1280/);
  assert.match(f.meta.content, /initial-scale=0.5/);
  assert.match(f.meta.content, /user-scalable=yes/);
  assert.match(f.meta.content, /minimum-scale=0.25/);
  assert.match(f.meta.content, /maximum-scale=5/);
  const previous = f.meta.content;
  for (let i = 0; i < 20; i++) f.observers[0].callback();
  assert.equal(f.meta.content, previous);
  vm.runInContext(script, f.context);
  assert.equal(f.observers.length, 1);
});

test('late page metadata cannot lock native zoom again', () => {
  const f = fixture(null, 'loading');
  assert.match(f.meta.content, /width=device-width/);
  f.listeners.DOMContentLoaded();
  f.meta.content = 'width=device-width, user-scalable=0, maximum-scale=1';
  f.observers[0].callback();
  assert.match(f.meta.content, /user-scalable=yes/);
  assert.doesNotMatch(f.meta.content, /maximum-scale=1/);
});
