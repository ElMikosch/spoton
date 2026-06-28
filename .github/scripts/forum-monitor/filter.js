import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TOPICS_PATH = join(__dirname, 'forum-topics.json');

let _topics = null;

async function loadTopics() {
  if (_topics) return _topics;
  try {
    const raw = await readFile(TOPICS_PATH, 'utf-8');
    _topics = JSON.parse(raw);
  } catch {
    _topics = { resolved: {} };
  }
  return _topics;
}

export function isQuoteOnly(post) {
  const html = (post.content || '').trim();
  if (!html) return true;

  const withoutQuotes = html
    .replace(/<div class="bbcode_container">[\s\S]*?<\/div>\s*<\/div>\s*<\/div>\s*<\/div>/gi, '')
    .replace(/<blockquote[^>]*>[\s\S]*?<\/blockquote>/gi, '')
    .replace(/<[^>]+>/g, '')
    .replace(/&[a-z]+;/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  return withoutQuotes.length < 30;
}

export async function matchesTopic(post) {
  const topics = await loadTopics();
  const text = (post.contentText || '').toLowerCase();

  for (const [name, topic] of Object.entries(topics.resolved || {})) {
    const matched = (topic.keywords || []).filter(kw =>
      text.includes(kw.toLowerCase())
    );
    if (matched.length >= 2) {
      return { name, topic, matched };
    }
  }
  return null;
}

export function isAlreadyQueued(post, state) {
  const pending = state.pendingTriage || [];
  const triaged = state.triagedPostIds || [];
  return pending.some(p => p.postId === post.postId) || triaged.includes(post.postId);
}

export async function filterPost(post, state) {
  if (isAlreadyQueued(post, state)) {
    return { skip: true, reason: `already queued or triaged (post ${post.postId})` };
  }

  if (isQuoteOnly(post)) {
    return { skip: true, reason: 'quote-only post, no original content' };
  }

  const topic = await matchesTopic(post);
  if (topic) {
    return {
      skip: true,
      reason: `matches resolved topic "${topic.name}" (${topic.topic.status}): ${topic.matched.join(', ')}`,
    };
  }

  return { skip: false };
}
