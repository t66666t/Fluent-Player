// The original DRM methods stand in for the blocking Widevine binder call in
// the K80 Pro ANR. A protection test must prove these methods are NEVER called.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');
const source = fs.readFileSync(path.join(__dirname,
  '../lib/features/douyin_download/douyin_page_policy.dart'), 'utf8');
const policy = source.match(/const String douyinMediaPolicyScript = r'''([\s\S]*?)''';/)[1];

function fixture(background = false) {
  const native = {eme: 0, encrypted: 0, clear: 0, keys: 0, legacy: 0, play: 0, type: 0};
  class Capabilities {
    decodingInfo(configuration) {
      assert.equal(this, navigator.mediaCapabilities);
      if (configuration?.keySystemConfiguration) {
        native.encrypted++;
        throw new Error('Widevine must not be contacted');
      }
      native.clear++;
      return Promise.resolve({supported: true, smooth: true, powerEfficient: false});
    }
  }
  class Navigator {
    requestMediaKeySystemAccess() { native.eme++; throw new Error('Widevine must not be contacted'); }
  }
  const navigator = new Navigator();
  navigator.mediaCapabilities = new Capabilities();
  class Media {
    play() { native.play++; return Promise.resolve('ordinary-video'); }
    canPlayType(type) { native.type++; return type === 'video/mp4' ? 'probably' : ''; }
    setMediaKeys() { native.keys++; throw new Error('Encrypted-media client must not be initialized'); }
    webkitGenerateKeyRequest() { native.legacy++; throw new Error('Widevine must not be contacted'); }
  }
  class WebKitMediaKeys {
    static isTypeSupported() { native.legacy++; throw new Error('Widevine must not be contacted'); }
  }
  const context = vm.createContext({navigator, HTMLMediaElement: Media, WebKitMediaKeys,
    MediaSource: {isTypeSupported: type => type.startsWith('video/mp4') || type.startsWith('audio/mp4')},
    document: {createElement: () => new Media()},
    DOMException, __douyinBackgroundCapture: background});
  context.window = context;
  vm.runInContext(policy, context);
  return {context, navigator, native, media: new Media(), snapshot: context.__douyinMediaPolicy.snapshot};
}

test('key-system probes reject before any native Widevine call, including prototype calls', async () => {
  const f = fixture();
  for (const key of ['com.widevine.alpha', 'org.w3.clearkey', 'unknown']) {
    await assert.rejects(f.navigator.requestMediaKeySystemAccess(key, []), {name: 'NotSupportedError'});
  }
  const proto = Object.getPrototypeOf(f.navigator);
  await assert.rejects(proto.requestMediaKeySystemAccess.call(f.navigator, 'com.widevine.alpha', []), {name: 'NotSupportedError'});
  assert.equal(f.native.eme, 0);
  assert.equal(f.snapshot().eme, 4);
});

test('decodingInfo never enters native capability negotiation and retains clear codec support', async () => {
  const f = fixture();
  const result = await f.navigator.mediaCapabilities.decodingInfo({
    type: 'media-source', video: {contentType: 'video/mp4'},
    keySystemConfiguration: {keySystem: 'com.widevine.alpha'},
  });
  assert.equal(result.supported, false);
  assert.equal(result.keySystemAccess, null);
  assert.equal(f.native.encrypted, 0);
  const clear = await f.navigator.mediaCapabilities.decodingInfo({type: 'media-source', video: {contentType: 'video/mp4'}});
  assert.equal(clear.supported, true);
  assert.equal(f.native.clear, 0);
  assert.equal(f.snapshot().clearCapabilities, 1);
  assert.equal(clear.smooth, false);
  assert.equal(clear.powerEfficient, false);
  assert.equal((await f.navigator.mediaCapabilities.decodingInfo({type: 'file', video: {contentType: 'video/mp4'}})).supported, true);
  assert.equal((await f.navigator.mediaCapabilities.decodingInfo({type: 'media-source', video: {contentType: 'video/unknown'}})).supported, false);
});

test('even setMediaKeys(null) avoids initializing the encrypted-media client', async () => {
  const f = fixture();
  await f.media.setMediaKeys(null);
  await assert.rejects(f.media.setMediaKeys({}), {name: 'NotSupportedError'});
  assert.equal(f.native.keys, 0);
  assert.equal(f.snapshot().mediaKeys, 2);
});

test('legacy DRM probes are denied while ordinary playback and codec checks work', async () => {
  const f = fixture();
  assert.equal(f.media.canPlayType('video/mp4', 'com.widevine.alpha'), '');
  assert.equal(f.context.WebKitMediaKeys.isTypeSupported('com.widevine.alpha', 'video/mp4'), false);
  assert.throws(() => f.media.webkitGenerateKeyRequest('com.widevine.alpha'), {name: 'NotSupportedError'});
  assert.equal(f.native.legacy, 0);
  assert.equal(f.media.canPlayType('video/mp4'), 'probably');
  assert.equal(await f.media.play(), 'ordinary-video');
  assert.equal(f.native.type, 1);
  assert.equal(f.native.play, 1);
});

test('a normal player can fall back from unsupported DRM to ordinary media', async () => {
  const f = fixture();
  const supported = await f.navigator.requestMediaKeySystemAccess('com.widevine.alpha', [])
    .then(() => true, () => false);
  if (!supported) await f.media.play();
  assert.equal(f.native.eme, 0);
  assert.equal(f.native.play, 1);
});

test('headless parsing denies site-initiated play without invoking a decoder', async () => {
  const f = fixture(true);
  await assert.rejects(f.media.play(), {name: 'NotAllowedError'});
  await assert.rejects(Object.getPrototypeOf(f.media).play.call(f.media), {name: 'NotAllowedError'});
  assert.equal(f.native.play, 0);
  assert.equal(f.snapshot().backgroundPlay, 2);
  assert.equal(f.snapshot().background, true);
});

test('reinjecting is idempotent, and page assignments cannot restore a native probe', async () => {
  const f = fixture();
  const method = f.navigator.requestMediaKeySystemAccess;
  vm.runInContext(policy, f.context);
  vm.runInContext('navigator.requestMediaKeySystemAccess = () => "restored"', f.context);
  assert.equal(f.navigator.requestMediaKeySystemAccess, method);
  await assert.rejects(f.navigator.requestMediaKeySystemAccess('com.widevine.alpha'), {name: 'NotSupportedError'});
  assert.equal(f.snapshot().eme, 1);
});

test('each iframe has its own early policy and reports no credentials or URLs', async () => {
  const top = fixture(), child = fixture();
  await assert.rejects(child.navigator.requestMediaKeySystemAccess('com.widevine.alpha'), {name: 'NotSupportedError'});
  assert.equal(child.native.eme, 0);
  assert.equal(top.snapshot().eme, 0);
  assert.deepEqual(Object.keys(child.snapshot()).sort(), [
    'background', 'backgroundPlay', 'clearCapabilities', 'eme', 'encryptedCapabilities', 'legacy', 'mediaKeys', 'version',
  ]);
});

test('engines without encrypted-media APIs still load without adding fake APIs', () => {
  const context = vm.createContext({navigator: {}, DOMException});
  context.window = context;
  vm.runInContext(policy, context);
  assert.equal(context.navigator.requestMediaKeySystemAccess, undefined);
  assert.equal(context.__douyinMediaPolicy.version, 1);
});
