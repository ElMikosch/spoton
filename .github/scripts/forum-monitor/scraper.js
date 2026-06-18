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

async function scrapeOnePage(url) {
  const browser = await chromium.launch({
    args: ['--disable-blink-features=AutomationControlled'],
  });
  try {
    const ctx = await browser.newContext({
      userAgent: USER_AGENT,
      viewport: { width: 1280, height: 720 },
      locale: 'en-US',
    });
    const page = await ctx.newPage();
    await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });

    const title = await page.title();
    if (title.includes('Just a moment')) {
      console.log('[scraper] Cloudflare challenge detected, waiting...');
      await page.waitForFunction(
        () => !document.title.includes('Just a moment'),
        { timeout: 45000 }
      );
      console.log('[scraper] Cloudflare challenge passed');
      await page.waitForTimeout(2000);
    }

    await page.waitForSelector('.js-post', { timeout: 30000 });

    const result = await page.evaluate(POST_EXTRACTION);

    const lastPage = await page.evaluate(() => {
      const links = Array.from(document.querySelectorAll('a.js-pagenav-button, a.arrow'));
      let max = 1;
      for (const link of links) {
        const m = link.href && link.href.match(/\/page(\d+)/);
        if (m) max = Math.max(max, parseInt(m[1], 10));
      }
      return max;
    });

    return { posts: result, lastPage };
  } finally {
    await browser.close();
  }
}

export async function scrapePosts(url = THREAD_URL) {
  const baseUrl = url.replace(/\/page\d+$/, '');
  const { posts: firstPagePosts, lastPage } = await scrapeOnePage(baseUrl);
  console.log(`[scraper] Page 1: ${firstPagePosts.length} posts, ${lastPage} page(s) total`);

  let allPosts = firstPagePosts;

  // Cloudflare blocks cross-page navigation within the same browser session,
  // so each page needs its own browser instance.
  for (let p = 2; p <= lastPage; p++) {
    const pageUrl = baseUrl + '/page' + p;
    console.log(`[scraper] Scraping page ${p}: ${pageUrl}`);
    const { posts: pagePosts } = await scrapeOnePage(pageUrl);
    console.log(`[scraper] Page ${p}: ${pagePosts.length} posts`);
    allPosts = allPosts.concat(pagePosts);
  }

  return allPosts;
}

export async function scrapeFromFile(filePath) {
  const browser = await chromium.launch();
  try {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(`file://${filePath}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.js-post', { timeout: 10000 });
    return await page.evaluate(POST_EXTRACTION);
  } finally {
    await browser.close();
  }
}

export { THREAD_URL };
