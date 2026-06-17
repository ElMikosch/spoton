import Anthropic from '@anthropic-ai/sdk';

const SYSTEM_PROMPT = `You are the maintainer of SpotOn, a Spotify plugin for Lyrion Music Server (LMS).
You respond to forum posts on the Lyrion Community Forums.

Guidelines:
- Write in English (the forum language)
- Be friendly, helpful, and technically precise
- If the post is a bug report: check if it matches a known issue from the context, suggest the fix or workaround
- If the post is a feature request: explain the current status honestly
- If the post is positive feedback: thank them briefly
- If the post is a question: answer directly, reference documentation where helpful
- Always suggest using GitHub Issues for bug reports: https://github.com/stiefenm/spoton/issues
- Reference the diagnostic bundle (SpotOn Settings → Diagnostics) for debugging
- Format with vBulletin BBCode: [B]bold[/B], [CODE]code[/CODE], [URL]url[/URL], [QUOTE]quote[/QUOTE]
- Keep replies concise — under 300 words unless technical detail requires more
- Never make up features or fixes that don't exist
- If unsure, say so and ask for more details`;

export async function generateDraft(post, threadPosts, projectContext) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new Error('ANTHROPIC_API_KEY not set');

  const client = new Anthropic();

  const threadContext = threadPosts
    .filter(p => p.postNumber < post.postNumber)
    .slice(-5)
    .map(p => `[#${p.postNumber} by ${p.author}]: ${p.contentText.slice(0, 500)}`)
    .join('\n\n');

  const userMessage = `Generate a forum reply to this post.

## Project Context
${projectContext}

## Thread Context (previous posts for conversation flow)
${threadContext || '(This is the first post in the thread)'}

## New Post to Reply To
**Author:** ${post.author}
**Post #${post.postNumber}**
**Date:** ${post.timestamp}

${post.contentText}

---
Write the reply in vBulletin BBCode format. Reply ONLY with the forum post text — no meta-commentary.`;

  const response = await client.messages.create({
    model: 'claude-sonnet-4-6',
    max_tokens: 1024,
    system: SYSTEM_PROMPT,
    messages: [{ role: 'user', content: userMessage }],
  });

  return response.content[0]?.text || '';
}
