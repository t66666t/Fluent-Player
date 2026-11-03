// Anonymous, opt-in live compatibility probe. Never opens a personal profile.
// Usage: DOUYIN_PLAYWRIGHT_PACKAGE=<path> node tool/douyin_media_policy_probe.cjs [--baseline] [url]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.DOUYIN_PLAYWRIGHT_PACKAGE || 'playwright');
const base = path.join(__dirname, '../lib/features/douyin_download');
const policy = fs.readFileSync(path.join(base, 'douyin_page_policy.dart'), 'utf8')
  .match(/const String douyinMediaPolicyScript = r'''([\s\S]*?)''';/)[1];
const captureSource = fs.readFileSync(path.join(base, 'douyin_capture_script.dart'), 'utf8');
const capture = captureSource.match(/const String douyinCaptureScript = r'''([\s\S]*?)''';/)[1];
const drain = captureSource.match(/const String douyinDrainScript = r'''([\s\S]*?)''';/)[1];
const baseline = process.argv.includes('--baseline');
const background = process.argv.includes('--background');
const fixture = process.argv.includes('--fixture');
const target = process.argv.find(arg => /^https:\/\//.test(arg)) ||
  'https://www.douyin.com/video/6961737553342991651';
const instrumentation = `
(() => {
  const counts = window.__nativeMediaProbeCounts = {eme: 0, encrypted: 0, clear: 0};
  const original = navigator.requestMediaKeySystemAccess;
  if (original) navigator.requestMediaKeySystemAccess = function() {
    counts.eme++;
    return original.apply(this, arguments);
  };
  const capabilities = navigator.mediaCapabilities;
  if (capabilities) {
    const original = capabilities.decodingInfo;
    capabilities.decodingInfo = function(configuration) {
      counts[configuration?.keySystemConfiguration ? 'encrypted' : 'clear']++;
      return original.apply(this, arguments);
    };
  }
})();
`;
(async () => {
  let browser;
  try {
    browser = await chromium.launch({channel: 'msedge', headless: true});
    const context = await browser.newContext({locale: 'zh-CN', viewport: {width: 1280, height: 900}});
    if (fixture) {
      const videoId = /\/video\/(\d+)/.exec(target)?.[1];
      const child = `<script>window.__earlyPolicy = window.__douyinMediaPolicy?.version; navigator.requestMediaKeySystemAccess('com.widevine.alpha', []).catch(() => {});</script>`;
      await context.route(target, route => route.fulfill({contentType: 'text/html', body: `<!doctype html><html><head><script>
        window.__earlyPolicy = window.__douyinMediaPolicy?.version;
        navigator.requestMediaKeySystemAccess('com.widevine.alpha', []).catch(() => {});
        navigator.mediaCapabilities.decodingInfo({type: 'media-source', video: {
          contentType: 'video/mp4; codecs="avc1.42E01E"', width: 640, height: 360, bitrate: 100000, framerate: 24
        }});
        window._ROUTER_DATA = {aweme_id: '${videoId}', desc: 'Compatibility fixture', video: {
          play_addr: {url_list: ['https://v.douyinvod.com/fixture.mp4']}, bit_rate: []
        }};
        document.addEventListener('DOMContentLoaded', () => {
          const frame = document.createElement('iframe');
          frame.srcdoc = ${JSON.stringify(child).replaceAll('<', '\\u003c')};
          document.body.appendChild(frame);
        });
        </script></head><body></body></html>`}));
    }
    // One init script fixes the ordering relative to early site inline scripts.
    await context.addInitScript(`${instrumentation}\nwindow.__douyinBackgroundCapture = ${background};\n${baseline ? '' : policy}\n${capture}`);
    const page = await context.newPage();
    await page.goto(target, {waitUntil: 'domcontentloaded', timeout: 30000});
    const found = new Map();
    for (let i = 0; i < 8; i++) {
      await page.waitForTimeout(fixture ? 150 : 1500);
      const data = JSON.parse(await page.evaluate(drain));
      for (const item of data.items) found.set(item.aweme_id, item);
    }
    const expectedId = /\/video\/(\d+)/.exec(target)?.[1];
    assert.ok(found.size, 'No video metadata was captured');
    if (expectedId) {
      const expected = found.get(expectedId);
      assert.ok(expected, 'The requested video was not captured');
      assert.ok(expected.video.play_addr || expected.video.bit_rate.length,
        'The requested video has no ordinary playback rendition');
    }
    const frames = [];
    for (const frame of page.frames()) {
      try {
        frames.push(await frame.evaluate(() => ({
          native: window.__nativeMediaProbeCounts,
          policy: window.__douyinMediaPolicy?.snapshot(),
          earlyPolicy: window.__earlyPolicy,
        })));
      } catch (_) { /* The page can replace a transient iframe. */ }
    }
    const media = await page.evaluate(() => Array.from(document.querySelectorAll('video')).slice(0, 4)
      .map(video => ({paused: video.paused, readyState: video.readyState, time: Math.round(video.currentTime)})));
    process.stdout.write(JSON.stringify({baseline, background, fixture, frames, media, captured: Array.from(found.values()).map(item => ({
      id: item.aweme_id, source: item.capture_source,
      qualities: item.video.bit_rate.length,
      hasBasePlayback: !!item.video.play_addr,
    }))}, null, 2));
    if (!baseline) {
      for (const frame of frames) {
        assert.equal(frame.native?.eme ?? 0, 0);
        assert.equal(frame.native?.encrypted ?? 0, 0);
        assert.equal(frame.native?.clear ?? 0, 0);
        if (fixture) assert.equal(frame.earlyPolicy, 1,
          'The policy was not installed before the first page script');
      }
    }
  } catch (error) {
    process.stderr.write(String(error.message).slice(0, 700));
    process.exitCode = 1;
  } finally { await browser?.close(); }
})();
