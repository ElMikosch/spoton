import { readFile } from 'node:fs/promises';
import { execSync } from 'node:child_process';

export async function buildContext() {
  const parts = [];

  const changelog = await readRecentChangelog();
  if (changelog) parts.push(`## Recent Releases\n${changelog}`);

  const troubleshooting = await readSafe('TROUBLESHOOTING.md');
  if (troubleshooting) parts.push(`## Known Issues & Troubleshooting\n${troubleshooting}`);

  const issues = getOpenIssues();
  if (issues) parts.push(`## Open GitHub Issues\n${issues}`);

  return parts.join('\n\n---\n\n');
}

async function readRecentChangelog() {
  const raw = await readSafe('CHANGELOG.md');
  if (!raw) return null;

  const lines = raw.split('\n');
  let releases = 0;
  const out = [];
  for (const line of lines) {
    if (line.startsWith('## [') && !line.includes('Unreleased')) {
      releases++;
      if (releases > 3) break;
    }
    if (releases > 0) out.push(line);
  }
  return out.join('\n').trim() || null;
}

function getOpenIssues() {
  try {
    const out = execSync('gh issue list --state open --limit 10 --json number,title,labels 2>/dev/null', {
      encoding: 'utf-8',
      timeout: 10000,
    });
    const issues = JSON.parse(out);
    if (!issues.length) return null;
    return issues
      .map(i => `- #${i.number}: ${i.title} [${i.labels.map(l => l.name).join(', ')}]`)
      .join('\n');
  } catch {
    return null;
  }
}

async function readSafe(path) {
  try {
    return await readFile(path, 'utf-8');
  } catch {
    return null;
  }
}
