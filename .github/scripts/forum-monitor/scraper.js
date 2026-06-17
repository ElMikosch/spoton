import { chromium } from 'playwright';

const THREAD_URL = 'https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton-%E2%80%94-spotify-plugin-for-lms-alternative-to-spotty';

const USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const POST_EXTRACTION = `
  Array.from(document.querySelectorAll('.js-post')).map(node => {
    const nodeId = node.getAttribute('data-node-id');
    const authorEl = node.querySelector('.b-userinfo__details span[itemprop="name"]');
    const timeEl = node.querySelector('time[itemprop="dateCreated"]');
    const contentEl = node.querySelector('.js-post__content-text');
    const countEl = node.querySelector('.b-post__count');
    return {
      postId: nodeId || null,
      author: authorEl ? authorEl.textContent.trim() : 'unknown',
      timestamp: timeEl ? timeEl.getAttribute('datetime') : null,
      content: contentEl ? contentEl.innerHTML.trim() : '',
      contentText: contentEl ? contentEl.textContent.trim() : '',
      postNumber: parseInt((countEl ? countEl.textContent.replace('#', '') : '0'), 10),
    };
  })
`;

async function launchBrowser() {
  return chromium.launch({
    args: ['--disable-blink-features=AutomationControlled'],
  });
}

async function newPage(browser) {
  const ctx = await browser.newContext({ userAgent: USER_AGENT });
  return ctx.newPage();
}

export async function scrapePosts(url = THREAD_URL) {
  const browser = await launchBrowser();
  try {
    const page = await newPage(browser);
    await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForSelector('.js-post', { timeout: 30000 });
    return await page.evaluate(POST_EXTRACTION);
  } finally {
    await browser.close();
  }
}

export async function scrapeFromFile(filePath) {
  const browser = await launchBrowser();
  try {
    const page = await newPage(browser);
    await page.goto(`file://${filePath}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.js-post', { timeout: 10000 });
    return await page.evaluate(POST_EXTRACTION);
  } finally {
    await browser.close();
  }
}

export { THREAD_URL };
