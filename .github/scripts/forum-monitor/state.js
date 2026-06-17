import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const STATE_PATH = process.env.STATE_PATH || '.github/scripts/forum-monitor/forum-state.json';

function emptyState() {
  return {
    lastChecked: null,
    threads: {},
  };
}

export async function loadState() {
  try {
    const raw = await readFile(STATE_PATH, 'utf-8');
    return JSON.parse(raw);
  } catch {
    return emptyState();
  }
}

export async function saveState(state) {
  state.lastChecked = new Date().toISOString();
  await mkdir(dirname(STATE_PATH), { recursive: true });
  await writeFile(STATE_PATH, JSON.stringify(state, null, 2) + '\n');
}

export function diffPosts(state, threadUrl, currentPosts) {
  const threadState = state.threads[threadUrl];

  if (!threadState) {
    state.threads[threadUrl] = {
      knownPostIds: currentPosts.map(p => p.postId),
      lastPostCount: currentPosts.length,
    };
    return { newPosts: [], isFirstRun: true };
  }

  const known = new Set(threadState.knownPostIds);
  const newPosts = currentPosts.filter(p => p.postId && !known.has(p.postId));

  for (const p of currentPosts) {
    if (p.postId) known.add(p.postId);
  }
  threadState.knownPostIds = [...known];
  threadState.lastPostCount = currentPosts.length;

  return { newPosts, isFirstRun: false };
}
