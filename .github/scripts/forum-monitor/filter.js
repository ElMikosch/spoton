import { readFile } from 'node:fs/promises';
import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const TOPICS_PATH = join(__dirname, 'forum-topics.json');

let _topics = null;
let _dismissed = null;

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

function loadDismissedPostIds() {
  if (_dismissed) return _dismissed;
  _dismissed = new Set();
  try {
    const out = execSync(
      'gh issue list --state closed --label forum-reply-draft --limit 100 --json body --jq ".[].body"',
      { encoding: 'utf-8', timeout: 15000 }
    );
    const postIdPattern = /<!-- POST_ID:(\d+) -->/g;
    let match;
    while ((match = postIdPattern.exec(out)) !== null) {
      _dismissed.add(match[1]);
    }
  } catch {
    // gh CLI unavailable or no closed issues — continue without
  }
  return _dismissed;
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

export function isDismissed(post) {
  const dismissed = loadDismissedPostIds();
  return dismissed.has(post.postId);
}

export async function filterPost(post) {
  if (isDismissed(post)) {
    return { skip: true, reason: `dismissed (closed draft for post ${post.postId})` };
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
