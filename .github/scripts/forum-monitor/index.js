import { scrapePosts, THREAD_URL } from './scraper.js';
import { loadState, saveState, diffPosts } from './state.js';
import { buildContext } from './context.js';
import { generateDraft } from './drafter.js';
import { filterPost } from './filter.js';

const MAX_POSTS_PER_RUN = 5;
const OWN_USERNAME = 'sti';

async function main() {
  console.log(`[forum-monitor] Scraping ${THREAD_URL}`);
  const posts = await scrapePosts();
  console.log(`[forum-monitor] Found ${posts.length} posts`);

  const state = await loadState();
  const { newPosts, isFirstRun } = diffPosts(state, THREAD_URL, posts);

  if (isFirstRun) {
    console.log(`[forum-monitor] First run — seeded state with ${posts.length} known posts`);
    await saveState(state);
    return;
  }

  const postsToProcess = newPosts
    .filter(p => p.author !== OWN_USERNAME)
    .slice(0, MAX_POSTS_PER_RUN);

  if (!postsToProcess.length) {
    console.log('[forum-monitor] No new posts from other users');
    await saveState(state);
    return;
  }

  console.log(`[forum-monitor] ${postsToProcess.length} new post(s) to process`);

  if (!state.pendingTriage) state.pendingTriage = [];

  const context = await buildContext();

  for (const post of postsToProcess) {
    const { skip, reason } = await filterPost(post, state);
    if (skip) {
      console.log(`[forum-monitor] Skipping #${post.postNumber} by ${post.author}: ${reason}`);
      continue;
    }

    console.log(`[forum-monitor] Drafting reply for #${post.postNumber} by ${post.author}`);

    let draft;
    try {
      draft = await generateDraft(post, posts, context);
    } catch (err) {
      console.error(`[forum-monitor] Draft generation failed: ${err.message}`);
      draft = null;
    }

    state.pendingTriage.push({
      postId: post.postId,
      postNumber: post.postNumber,
      author: post.author,
      timestamp: post.timestamp,
      threadUrl: THREAD_URL,
      contentPreview: post.contentText.slice(0, 300).replace(/\n/g, ' '),
      draft,
      scrapedAt: new Date().toISOString(),
    });

    console.log(`[forum-monitor] Queued #${post.postNumber} by ${post.author} for triage`);
  }

  await saveState(state);
  const pending = state.pendingTriage.length;
  console.log(`[forum-monitor] Done — ${pending} post(s) pending triage`);
}

main().catch(err => {
  console.error(`[forum-monitor] Fatal: ${err.message}`);
  process.exit(1);
});
