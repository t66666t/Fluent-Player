// Manual anonymous browser smoke check; no personal profile or login is used.
const fs = require('node:fs');
const path = require('node:path');
// Install Playwright locally or provide its package directory via this variable.
const {chromium} = require(process.env.DOUYIN_PLAYWRIGHT_PACKAGE || 'playwright');
const source = fs.readFileSync(path.join(__dirname, '../lib/features/douyin_download/douyin_capture_script.dart'), 'utf8');
const capture = source.match(/const String douyinCaptureScript = r'''([\s\S]*?)''';/)[1];
const drain = source.match(/const String douyinDrainScript = r'''([\s\S]*?)''';/)[1];
(async () => {
  let browser;
  try {
    browser = await chromium.launch({channel: 'msedge', headless: true});
    const context = await browser.newContext({locale: 'zh-CN', viewport: {width: 1280, height: 900}});
    await context.addInitScript(capture);
    const page = await context.newPage();
    await page.goto(process.argv[2] || 'https://www.douyin.com/video/6961737553342991651', {waitUntil: 'domcontentloaded', timeout: 30000});
    const found = new Map();
    for (let i = 0; i < 8; i++) {
      await page.waitForTimeout(1500);
      const data = JSON.parse(await page.evaluate(drain));
      for (const item of data.items) found.set(item.aweme_id, item);
      if (Array.from(found.values()).some(item => item.desc && item.video.bit_rate?.length)) break;
    }
    process.stdout.write(JSON.stringify({pageTitle: await page.title(), count: found.size, items: Array.from(found.values()).map(item => ({
      id: item.aweme_id, title: item.desc, source: item.capture_source,
      qualities: item.video.bit_rate.length, ownAudioTracks: item.video.bit_rate_audio?.length || 0,
      hasBasePlayback: !!item.video.play_addr,
    }))}, null, 2));
    if (process.argv[3] && found.size) {
      fs.writeFileSync(process.argv[3], JSON.stringify({userAgent: await page.evaluate(() => navigator.userAgent), items: Array.from(found.values())}));
    }
  } catch (error) {
    process.stdout.write(JSON.stringify({error: String(error.message).slice(0, 700)}));
    process.exitCode = 1;
  } finally { if (browser) await browser.close(); }
})();
