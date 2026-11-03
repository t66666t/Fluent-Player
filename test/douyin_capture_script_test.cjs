// Run with: node --test test/douyin_capture_script_test.cjs
// Execute the actual injected JavaScript against page APIs, without a browser
// login, network requests, or dependencies outside the Node standard library.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../lib/features/douyin_download/douyin_capture_script.dart'), 'utf8');
const capture = source.match(/const String douyinCaptureScript = r'''([\s\S]*?)''';/)[1];
const drain = source.match(/const String douyinDrainScript = r'''([\s\S]*?)''';/)[1];
const id = '7421000123456789012';
function aweme(itemId = id) {
  return {
    awemeId: itemId, desc: '湖边日落', author: {nickName: '旅人'}, createTime: 1728326400,
    statistics: {diggCount: 12},
    video: {
      duration: 12345,
      bitRate: [{bitRate: 3500000, FPS: 60, isH265: 1, playAddr: {
        width: 1080, height: 1920, dataSize: 5000000,
        urlList: ['https://v3.douyinvod.com/a.mp4?token=a%2Fb', 'https://v9.douyinvod.com/b.mp4']
      }}], originCover: {urlList: ['https://p3.douyinpic.com/a.jpg']}
    }
  };
}

function page({url = `https://www.douyin.com/video/${id}`, hydration, videos = [], challenges = [], title = '', globals = {}, responseFactory} = {}) {
  const listeners = {};
  const timers = [];
  let now = 0;
  const document = {
    readyState: 'complete',
    title,
    getElementById: key => key === 'RENDER_DATA' && hydration ? {textContent: encodeURIComponent(JSON.stringify(hydration))} : null,
    querySelectorAll: selector => selector === 'video' ? videos : challenges,
    querySelector: () => ({content: '网页中的标题'}),
    addEventListener: (type, callback) => {listeners[type] = callback;}
  };
  Object.defineProperty(document, 'cookie', {get() {throw new Error('Capture must never access cookies');}});
  let nextResponse = null;
  let calls = 0;
  const originalFetch = function() {
    calls++;
    return Promise.resolve(responseFactory ? responseFactory(nextResponse) : {ok: true, headers: {get: () => null}, clone: () => ({text: async () => JSON.stringify(nextResponse)})});
  };
  class Xhr {
    constructor() {this.listeners = []; this.status = 200; this.responseType = 'json';}
    open(...args) {this.openArgs = args; return 42;}
    addEventListener(type, callback) {if (type === 'load') this.listeners.push(callback);}
    respond(value) {this.response = value; for (const callback of this.listeners) callback.call(this);}
  }
  const context = vm.createContext({URL, location: new URL(url), document, fetch: originalFetch, XMLHttpRequest: Xhr,
    TextDecoder, performance: {now: () => now},
    addEventListener: (type, callback) => {listeners[type] = callback;},
    setTimeout: (callback, delay = 0) => timers.push({callback, due: now + delay}), ...globals});
  context.window = context;
  vm.runInContext(capture, context);
  return {
    context,
    calls: () => calls,
    drain: () => JSON.parse(vm.runInContext(drain, context)),
    reinject: () => vm.runInContext(capture, context),
    emit: type => listeners[type]?.(),
    scan() {
      now += 1600;
      context.__douyinDownloadCapture.scan();
    },
    advance(milliseconds) {
      const until = now + milliseconds;
      while (timers.some(timer => timer.due <= until)) {
        timers.sort((a, b) => a.due - b.due);
        const timer = timers.shift();
        now = timer.due;
        timer.callback();
      }
      now = until;
    },
    flushTimers() {
      while (timers.length) {
        timers.sort((a, b) => a.due - b.due);
        const timer = timers.shift();
        now = Math.max(now, timer.due);
        timer.callback();
      }
    },
    timerCount: () => timers.length,
    async fetch(url, response) {
      nextResponse = response;
      await context.fetch(url);
      await new Promise(resolve => setImmediate(resolve));
    },
  };
}

test('reads URI-encoded hydration, normalizes camelCase, and drains once', () => {
  const browser = page({hydration: {loaderData: {'video_(id)/page': {videoInfoRes: {item_list: [aweme()]}}}}});
  const data = browser.drain();
  assert.equal(data.pageUrl, `https://www.douyin.com/video/${id}`);
  assert.equal(data.login, null);
  assert.equal(data.items.length, 1);
  const item = data.items[0];
  assert.equal(item.aweme_id, id);
  assert.equal(item.author.nickname, '旅人');
  assert.equal(item.video.bit_rate[0].play_addr.data_size, 5000000);
  assert.equal(item.video.bit_rate[0].play_addr.url_list[0], 'https://v3.douyinvod.com/a.mp4?token=a%2Fb');
  assert.equal(item.video.bit_rate[0].is_h265, 1);
  assert.equal(item.video.origin_cover.url_list[0], 'https://p3.douyinpic.com/a.jpg');
  assert.deepEqual(browser.drain().items, []);
  assert.equal(browser.calls(), 0);
});

test('API captures notify the native bridge promptly, coalesced and deduplicated', async () => {
  const signals = [];
  const browser = page({globals: {
    flutter_inappwebview: {callHandler: (...args) => {signals.push(args); return Promise.resolve();}},
  }});
  await browser.fetch('/aweme/v1/web/aweme/post/', {aweme_list: [aweme(), aweme('7421000123456789013')]});
  assert.equal(signals.length, 0);
  browser.advance(32);
  assert.deepEqual(signals, [['douyinCaptureAvailable']]);
  assert.equal(browser.drain().items.length, 2);
  await browser.fetch('/aweme/v1/web/aweme/post/', {aweme_list: [aweme()]});
  browser.advance(50);
  assert.equal(signals.length, 1, 'duplicate data must not wake Flutter');
});

test('queued hydration notifies when the native bridge becomes ready', () => {
  const browser = page({hydration: {aweme_detail: aweme()}});
  let signals = 0;
  browser.context.flutter_inappwebview = {callHandler: () => {signals++;}};
  browser.emit('flutterInAppWebViewPlatformReady');
  browser.advance(32);
  assert.equal(signals, 1);
  assert.equal(browser.drain().items.length, 1);
});

test('a media event inside the throttle interval captures new props within 250ms', () => {
  const media = {__reactProps$player: {}, getBoundingClientRect: () => ({width: 500, height: 600})};
  const browser = page({url: 'https://www.douyin.com/', videos: [media]});
  media.__reactProps$player = {videoInfo: aweme()};
  for (let i = 0; i < 100; i++) browser.emit('loadedmetadata');
  assert.equal(browser.timerCount(), 1);
  browser.advance(199);
  assert.deepEqual(browser.drain().items, []);
  browser.advance(1);
  assert.equal(browser.drain().items[0].aweme_id, id);
});

test('active player is scanned ahead of preloaded and offscreen players', () => {
  const videos = Array.from({length: 5}, (_, i) => ({
    paused: i !== 4,
    __reactProps$player: {videoInfo: aweme((7421000123456789010n + BigInt(i)).toString())},
    getBoundingClientRect: () => ({width: 500, height: 600, top: i === 0 ? 1000 : 0, bottom: i === 0 ? 1600 : 600, left: 0, right: 500}),
  }));
  const browser = page({url: 'https://www.douyin.com/', videos, globals: {innerHeight: 900, innerWidth: 500}});
  const found = browser.drain().items.map(item => item.aweme_id);
  assert.equal(found[0], '7421000123456789014');
  assert.ok(!found.includes('7421000123456789010'));
});

test('background parsing can read hydration while a headless document is hidden', () => {
  const browser = page({hydration: {aweme_detail: aweme()}, globals: {__douyinBackgroundCapture: true}});
  browser.context.document.hidden = true;
  browser.drain();
  browser.context.document.getElementById = key => key === 'RENDER_DATA'
    ? {textContent: JSON.stringify({aweme_detail: aweme('7421000123456789013')})} : null;
  browser.scan();
  assert.equal(browser.drain().items[0].aweme_id, '7421000123456789013');
  browser.context.__douyinDownloadCapture.setActive(false);
  browser.context.document.querySelectorAll = () => {throw new Error('paused background parser must not scan');};
  browser.scan();
});

test('old authentication failures are not replayed after a successful website login', async () => {
  const browser = page();
  await browser.fetch('/aweme/v1/web/aweme/detail/', {status_code: 2483, status_msg: '请先登录'});
  assert.equal(browser.drain().login, false);
  assert.equal(browser.drain().login, null);
  await browser.fetch('/aweme/v1/web/user/profile/self/', {status_code: 0, user: {uid: '12345'}});
  assert.equal(browser.drain().login, true);
  assert.equal(browser.drain().login, null);
});

test('a visible verification challenge wakes the bridge without video metadata', () => {
  let signals = 0;
  const browser = page({
    url: 'https://v.douyin.com/short/',
    challenges: [{getBoundingClientRect: () => ({width: 320, height: 180})}],
    globals: {flutter_inappwebview: {callHandler: () => {signals++;}}},
  });
  browser.advance(32);
  assert.equal(signals, 1);
  const data = browser.drain();
  assert.equal(data.verificationRequired, true);
  assert.equal(data.login, null);
  assert.deepEqual(data.items, []);
  assert.equal(browser.drain().verificationRequired, false, 'do not replay an old challenge event');
  browser.reinject();
  browser.advance(250);
  assert.equal(signals, 1, 'an unchanged challenge must not flood the bridge');
});

test('a challenge inserted after load is reported by the next drain', () => {
  const challenges = [];
  const browser = page({challenges});
  assert.equal(browser.drain().verificationRequired, false);
  challenges.push({getBoundingClientRect: () => ({width: 320, height: 180})});
  assert.equal(browser.drain().verificationRequired, true);
});

test('hidden challenge SDK containers do not interrupt a usable page', () => {
  const browser = page({hydration: {aweme_detail: aweme()}, challenges: [
    {getBoundingClientRect: () => ({width: 0, height: 0})},
    {getBoundingClientRect: () => ({width: 320, height: 180})},
  ], globals: {getComputedStyle: () => ({visibility: 'hidden'})}});
  const data = browser.drain();
  assert.equal(data.verificationRequired, false);
  assert.equal(data.items.length, 1);
});

test('explicit verification page titles are detected without reading the page body', () => {
  assert.equal(page({title: '安全验证 - 抖音'}).drain().verificationRequired, true);
  const browser = page({title: '安全验证教程 - 抖音', hydration: {aweme_detail: {
    ...aweme(), desc: '请完成验证，安全验证教程',
  }}});
  Object.defineProperty(browser.context.document, 'body', {get() {throw new Error('must not scan page text');}});
  assert.equal(browser.drain().verificationRequired, false);
});

test('API verification errors notify promptly without treating captions or SMS login as challenges', async () => {
  let signals = 0;
  const browser = page({globals: {flutter_inappwebview: {callHandler: () => {signals++;}}}});
  await browser.fetch('/aweme/v1/web/aweme/detail/', {status_msg: '请完成安全验证'});
  browser.advance(32);
  assert.equal(signals, 1);
  assert.equal(browser.drain().verificationRequired, true);
  const ordinary = page();
  await ordinary.fetch('/aweme/v1/web/aweme/detail/', {status_msg: '请登录获取验证码', aweme_detail: {
    ...aweme(), desc: '安全验证',
  }});
  assert.equal(ordinary.drain().verificationRequired, false);
  await ordinary.fetch('/aweme/v1/web/aweme/detail/', {status_code: 0, status_msg: '安全验证成功'});
  assert.equal(ordinary.drain().verificationRequired, false);
});

test('hydration added at DOMContentLoaded does not wait for the slow polling path', () => {
  const browser = page({globals: {document: {
    readyState: 'loading', getElementById: () => null,
    querySelectorAll: () => [], querySelector: () => null,
    addEventListener(type, callback) {this[type] = callback;},
  }}});
  browser.context.document.getElementById = key => key === 'RENDER_DATA'
    ? {textContent: JSON.stringify({aweme_detail: aweme()})} : null;
  browser.context.document.DOMContentLoaded();
  browser.advance(200);
  assert.equal(browser.drain().items[0].aweme_id, id);
});

test('cyclic/shared React props are visited once across all players and ancestors', () => {
  let visits = 0;
  const leaf = {};
  Object.defineProperty(leaf, 'probe', {enumerable: true, get() {visits++; return {};}});
  let shared = leaf;
  for (let i = 0; i < 10; i++) shared = {a: shared, b: shared, c: shared};
  shared.loop = shared;
  const props = {graph: shared, videoInfo: aweme()};
  const parent = {__reactProps$shared: props};
  const media = {parentElement: parent, __reactProps$shared: props,
    getBoundingClientRect: () => ({width: 500, height: 600})};
  const browser = page({url: 'https://www.douyin.com/', videos: [media, media, media]});
  assert.equal(visits, 1);
  assert.equal(browser.drain().items[0].aweme_id, id);
  for (let i = 0; i < 50; i++) {browser.drain(); browser.emit('playing');}
  assert.equal(visits, 1, 'polling and playback events must not synchronously rescan React');
  browser.scan();
  assert.equal(visits, 2);
});

test('unchanged hydration is parsed once; changed hydration can supply a later video', () => {
  let parses = 0;
  const browser = page({hydration: {aweme_detail: aweme()}, globals: {
    JSON: {stringify: JSON.stringify, parse(raw) {parses++; return JSON.parse(raw);}},
  }});
  const initialParses = parses;
  browser.drain();
  for (let i = 0; i < 20; i++) {browser.scan(); browser.drain();}
  assert.equal(parses, initialParses);
  browser.context.document.getElementById = key => key === 'RENDER_DATA'
    ? {textContent: JSON.stringify({aweme_detail: aweme('7421000123456789013')})} : null;
  browser.scan();
  assert.equal(browser.drain().items[0].aweme_id, '7421000123456789013');
});

test('suspended capture does no DOM scanning and playback events coalesce', () => {
  let queries = 0;
  const browser = page();
  browser.context.document.querySelectorAll = selector => {if (selector === 'video') queries++; return [];};
  browser.context.__douyinDownloadCapture.setActive(false);
  browser.scan();
  browser.drain();
  browser.emit('playing');
  assert.equal(queries, 0);
  browser.context.__douyinDownloadCapture.setActive(true);
  for (let i = 0; i < 100; i++) browser.emit('playing');
  assert.equal(browser.timerCount(), 1);
  browser.flushTimers();
  assert.equal(queries, 1);
});

test('chunked API responses are cancelled at the byte limit, without buffering all text', async () => {
  let reads = 0, cancels = 0, releases = 0;
  const browser = page({responseFactory: () => ({
    ok: true, headers: {get: () => null}, clone: () => ({body: {getReader: () => ({
      async read() {reads++; return {done: false, value: new Uint8Array(1024 * 1024)};},
      async cancel() {cancels++;}, releaseLock() {releases++;},
    })}}),
  })});
  await browser.fetch('/aweme/v1/web/aweme/detail/', null);
  assert.equal(reads, 5);
  assert.equal(cancels, 1);
  assert.equal(releases, 1);
  assert.deepEqual(browser.drain().items, []);
});

test('large capture batches cross the bridge in bounded chunks without losing items', async () => {
  const browser = page();
  const items = Array.from({length: 90}, (_, i) => ({...aweme((7421000123456789000n + BigInt(i)).toString()),
    desc: 'x'.repeat(5000), video: {...aweme().video, play_addr: {url_list: ['https://v3.douyinvod.com/' + 'x'.repeat(5000)]}},
  }));
  await browser.fetch('/aweme/v1/web/aweme/post/', {aweme_list: items});
  const first = browser.drain();
  assert.ok(JSON.stringify(first).length < 513 * 1024);
  assert.ok(first.items.length > 0 && first.items.length < 90);
  const all = [...first.items, ...browser.drain().items];
  assert.equal(new Set(all.map(item => item.aweme_id)).size, 90);
});

test('wraps fetch idempotently and ignores unrelated or untrusted responses', async () => {
  const browser = page();
  const wrapper = browser.context.fetch;
  browser.reinject();
  assert.equal(browser.context.fetch, wrapper);
  await browser.fetch('https://evil.example/aweme/v1/web/aweme/detail/', {aweme_detail: aweme()});
  await browser.fetch('https://www.douyin.com/unrelated/', {aweme_list: [aweme()]});
  assert.deepEqual(browser.drain().items, []);
  await browser.fetch('https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=' + id, {aweme_detail: aweme()});
  assert.equal(browser.drain().items[0].aweme_id, id);
  assert.equal(browser.calls(), 3);
});

test('captures XHR response reuse without adding duplicate listeners', () => {
  const browser = page();
  const xhr = new browser.context.XMLHttpRequest();
  assert.equal(xhr.open('GET', '/aweme/v1/web/aweme/post/'), 42);
  xhr.respond({aweme_list: [aweme()]});
  assert.equal(browser.drain().items.length, 1);
  xhr.open('GET', '/aweme/v1/web/aweme/post/');
  assert.equal(xhr.listeners.length, 1);
  xhr.respond({aweme_list: [aweme('7421000123456789013')]});
  assert.equal(browser.drain().items[0].aweme_id, '7421000123456789013');
});

test('reports only explicit login signals, never infers success from public video APIs', async () => {
  const browser = page();
  await browser.fetch('/aweme/v1/web/aweme/detail/', {status_code: 8, status_msg: '重试'});
  assert.equal(browser.drain().login, null);
  await browser.fetch('/aweme/v1/web/aweme/detail/', {status_code: 2483});
  assert.equal(browser.drain().login, false);
  await browser.fetch('/aweme/v1/web/user/profile/self/', {status_code: 0, user: {uid: '123'}});
  assert.equal(browser.drain().login, true);
});

test('skips ads, photo posts and related recommendations; bounds queue', async () => {
  const browser = page();
  await browser.fetch('/aweme/v1/web/aweme/post/', {aweme_list: [
    {...aweme(), is_ads: true}, {...aweme(), awemeType: 68},
  ], recommendations: [aweme()]});
  assert.deepEqual(browser.drain().items, []);
  const items = Array.from({length: 120}, (_, i) => aweme((7421000123456789000n + BigInt(i)).toString()));
  await browser.fetch('/aweme/v1/web/aweme/post/', {aweme_list: items});
  assert.equal(browser.drain().items.length, 100);
});

test('DOM fallback ties one visible HTTP video to a detail route only', () => {
  const videos = [{currentSrc: 'https://v3.douyinvod.com/dom.mp4', videoWidth: 720, videoHeight: 1280, duration: 12.5, poster: '', getBoundingClientRect: () => ({width: 400, height: 700})}];
  const browser = page({videos});
  const data = browser.drain();
  assert.equal(data.items[0].aweme_id, id);
  assert.equal(data.items[0].video.duration, 12500);
  assert.deepEqual(page({url: `https://www.douyin.com/?modal_id=${id}`, videos}).drain().items, []);
  assert.deepEqual(page({videos: [...videos, ...videos]}).drain().items, []);
  assert.deepEqual(page({videos: [{...videos[0], currentSrc: 'blob:https://www.douyin.com/blob'}]}).drain().items, []);
});

test('capture does not install on foreign pages', () => {
  const browser = page({url: 'https://douyin.com.evil.example/', hydration: {aweme_detail: aweme()}});
  assert.equal(browser.context.__douyinDownloadCapture, undefined);
  assert.deepEqual(browser.drain().items, []);
});

test('guest recommendation feed provides title and camelCase playback without login', async () => {
  const browser = page({url: 'https://www.douyin.com/'});
  await browser.fetch('/aweme/v1/web/recommend/feed/', {aweme_list: [{
    awemeId: id, caption: '游客也能看到的视频', video: {
      duration: 12000,
      bitRateList: [{width: 1080, height: 1920, format: 'mp4', playAddr: [{src: 'https://v3.douyinvod.com/full.mp4'}]}],
    }
  }]});
  const result = browser.drain();
  assert.equal(result.login, null);
  assert.equal(result.items[0].desc, '游客也能看到的视频');
  assert.equal(result.items[0].video.bit_rate[0].play_addr.url_list[0], 'https://v3.douyinvod.com/full.mp4');
});

test('blob player recovers its own React data and audio rather than saving currentSrc', () => {
  const media = {currentSrc: 'blob:https://www.douyin.com/mse', getBoundingClientRect: () => ({width: 500, height: 600}),
    __reactProps$test: {videoInfo: {awemeId: id, desc: '当前作品的真实标题', video: {
      bitRateList: [{format: 'dash', playAddr: 'https://v3.douyinvod.com/media-video-avc1/track.mp4'}],
      bitRateAudio: [{playAddr: [{src: 'https://v3.douyinvod.com/media-audio-aac/track.m4a'}]}],
    }}}
  };
  const result = page({url: 'https://www.douyin.com/', videos: [media]}).drain();
  assert.equal(result.items[0].desc, '当前作品的真实标题');
  assert.equal(result.items[0].video.bit_rate[0].format, 'dash');
  assert.equal(result.items[0].video.bit_rate_audio[0].play_addr.url_list[0], 'https://v3.douyinvod.com/media-audio-aac/track.m4a');
});

test('late API metadata replaces early DOM fallback and survives subsequent DOM scans', async () => {
  const media = {currentSrc: 'https://v3.douyinvod.com/dom.mp4', videoWidth: 720, videoHeight: 1280,
    getBoundingClientRect: () => ({width: 500, height: 600})};
  const browser = page({videos: [media]});
  assert.equal(browser.drain().items[0].capture_source, 'dom');
  await browser.fetch('https://www.douyin.com/aweme/v1/web/aweme/detail/', {aweme_detail: aweme()});
  const updated = browser.drain().items[0];
  assert.equal(updated.desc, '湖边日落');
  assert.equal(updated.capture_source, 'data');
  assert.equal(updated.video.bit_rate.length, 1);
  browser.reinject();
  assert.equal(browser.drain().items.length, 0);
});
