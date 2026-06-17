import { scrapePosts, THREAD_URL } from './scraper.js';
import { loadState, saveState, diffPosts } from './state.js';
import { buildContext } from './context.js';
import { generateDraft } from './drafter.js';
import { execSync } from 'node:child_process';

const MAX_ISSUES_PER_RUN = 5;
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
    .slice(0, MAX_ISSUES_PER_RUN);

  if (!postsToProcess.length) {
    console.log('[forum-monitor] No new posts from other users');
    await saveState(state);
    return;
  }

  console.log(`[forum-monitor] ${postsToProcess.length} new post(s) to process`);

  const context = await buildContext();

  for (const post of postsToProcess) {
    console.log(`[forum-monitor] Drafting reply for #${post.postNumber} by ${post.author}`);

    let draft;
    try {
      draft = await generateDraft(post, posts, context);
    } catch (err) {
      console.error(`[forum-monitor] Draft generation failed: ${err.message}`);
      draft = `*Draft generation failed: ${err.message}*\n\nPlease write a manual reply.`;
    }

    const title = `Forum: @${post.author} — ${post.contentText.slice(0, 60).replace(/\n/g, ' ')}`;
    const body = formatIssueBody(post, draft);

    try {
      const result = execSync(
        `gh issue create --title "${escapeShell(title)}" --label "forum-reply-draft" --body "$(cat <<'GHEOF'\n${body}\nGHEOF\n)"`,
        { encoding: 'utf-8', timeout: 30000 }
      );
      console.log(`[forum-monitor] Created issue: ${result.trim()}`);
    } catch (err) {
      console.error(`[forum-monitor] Issue creation failed: ${err.message}`);
    }
  }

  await saveState(state);
  console.log('[forum-monitor] Done');
}

function formatIssueBody(post, draft) {
  return `## Original Post

**Author:** ${post.author}
**Date:** ${post.timestamp}
**Post:** #${post.postNumber}
**Link:** ${THREAD_URL}#post-${post.postId}

---

${post.contentText}

---

## Draft Reply

<!-- DRAFT_START -->
${draft}
<!-- DRAFT_END -->

<!-- THREAD_URL:${THREAD_URL} -->
<!-- POST_ID:${post.postId} -->
<!-- POST_NUMBER:${post.postNumber} -->

---

**Actions:**
- Add label \`approved\` to trigger auto-post (Phase 24)
- Edit the draft above, then approve
- Close this issue to ignore`;
}

function escapeShell(str) {
  return str.replace(/"/g, '\\"').replace(/`/g, '\\`').replace(/\$/g, '\\$');
}

main().catch(err => {
  console.error(`[forum-monitor] Fatal: ${err.message}`);
  process.exit(1);
});
