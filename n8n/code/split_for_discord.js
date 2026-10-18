// n8n Code node: "Split for Discord"
// Discord rejects messages over 2,000 characters, and the daily summary is usually longer.
// Split on blank lines (between issues) so no issue is cut in half; each item = one Discord message.
const LIMIT = 1900;
const text = $input.first().json.message_text || '';
const blocks = text.split('\n\n');
const chunks = [];
let cur = '';
for (const b of blocks) {
  const piece = cur ? cur + '\n\n' + b : b;
  if (piece.length <= LIMIT) { cur = piece; continue; }
  if (cur) chunks.push(cur);
  if (b.length <= LIMIT) { cur = b; continue; }
  // a single block longer than the limit: fall back to splitting by line, then hard-cut
  cur = '';
  for (const line of b.split('\n')) {
    const p2 = cur ? cur + '\n' + line : line;
    if (p2.length <= LIMIT) { cur = p2; continue; }
    if (cur) chunks.push(cur);
    let rest = line;
    while (rest.length > LIMIT) { chunks.push(rest.slice(0, LIMIT)); rest = rest.slice(LIMIT); }
    cur = rest;
  }
}
if (cur) chunks.push(cur);
return chunks.map((content, i) => ({ json: { content, part: i + 1, parts: chunks.length } }));
