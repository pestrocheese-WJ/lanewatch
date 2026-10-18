// Runs the n8n Code-node scripts outside n8n with mocked $input / $(), against real query output.
// Usage: node tests/test_code_nodes.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const root = path.join(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');

function runNode(file, input, nodes = {}) {
  let code = read(`n8n/code/${file}`);
  code = code.replace('__SYSTEM_PROMPT__', JSON.stringify(read('prompts/system_prompt.md')));
  const $input = { first: () => ({ json: input }), all: () => [{ json: input }] };
  const $ = name => {
    if (!(name in nodes)) throw new Error(`node "${name}" not mocked`);
    return { first: () => ({ json: nodes[name] }) };
  };
  return new Function('$input', '$', code)($input, $)[0].json;
}

const payload = JSON.parse(read('samples/payload_2026-10-17.json'));
const config = { report_date: '2026-10-17', ai_model: 'claude-sonnet-5-5' };
const out = {};
let passed = 0;
const ok = (name, fn) => { fn(); passed++; console.log('PASS', name); };

// 1. request builder
const built = runNode('build_claude_request.js', { payload }, { Config: config });
ok('builds a Claude request for flagged data', () => {
  assert.strictEqual(built.has_flags, true);
  assert.strictEqual(built.request_body.model, 'claude-sonnet-5-5');
  assert.ok(built.request_body.system.includes('Strict rules about numbers'));
  assert.ok(!('all_lanes' in built.claude_input));
});
fs.writeFileSync(path.join(root, 'samples/claude_request_body.json'), JSON.stringify(built.request_body, null, 2));

const wrap = text => ({ id: 'msg_test', type: 'message', role: 'assistant', content: [{ type: 'text', text }] });
const example = read('samples/example_claude_response.json');

// 2. a grounded response passes
const good = runNode('validate_and_format.js', wrap(example), { 'Build Claude request': built });
ok('grounded response is validated', () => {
  assert.strictEqual(good.ai_status, 'validated', good.problems.join(' | '));
  assert.strictEqual(good.issue_rows.length, 3);
  assert.strictEqual(good.lane_rows.length, 12);
});
out.validated = good.message_text;

// 3. a response with an invented ratio, a fake lane and a missing lane is rejected
const tampered = JSON.parse(example);
tampered.issues[0].what_happened = 'KKC inbound processing is 4.4x slower than normal and also hit BKK-XYZ.';
tampered.issues[2].affected = ['BKK-HDY'];
const bad = runNode('validate_and_format.js', wrap(JSON.stringify(tampered)), { 'Build Claude request': built });
ok('hallucinated numbers / lanes / missing coverage are rejected', () => {
  assert.strictEqual(bad.ai_status, 'rejected_fallback');
  const p = bad.problems.join(' | ');
  assert.ok(p.includes('4.4'), p);
  assert.ok(p.includes('BKK-XYZ'), p);
  assert.ok(p.includes('CBI-HDY'), p);
});
ok('rule-based fallback still covers every flagged lane and hub', () => {
  const affected = new Set(bad.summary.issues.flatMap(i => i.affected));
  payload.lanes_flagged.forEach(l => assert.ok(affected.has(l.lane), l.lane));
  payload.hubs_flagged.forEach(h => assert.ok(affected.has(h.hub_code), h.hub_code));
});
out.rejected_fallback = bad.message_text;

// 4. API down -> fallback, no crash
const err = runNode('validate_and_format.js', { error: { message: 'overloaded_error' } }, { 'Build Claude request': built });
ok('API error falls back without crashing', () => assert.strictEqual(err.ai_status, 'api_error_fallback'));

// 5. markdown-fenced JSON is accepted
const fenced = runNode('validate_and_format.js', wrap('```json\n' + example + '\n```'), { 'Build Claude request': built });
ok('accepts JSON wrapped in ``` fences', () => assert.strictEqual(fenced.ai_status, 'validated'));

// 5b. Gemini response format is accepted by the same validator
const geminiResp = { candidates: [{ content: { role: 'model', parts: [{ text: example }] }, finishReason: 'STOP' }] };
const gem = runNode('validate_and_format.js', geminiResp, { 'Build Claude request': built });
ok('accepts Gemini generateContent response', () => assert.strictEqual(gem.ai_status, 'validated', gem.problems.join(' | ')));
const gemErr = runNode('validate_and_format.js', { error: { code: 429, message: 'quota exceeded' } }, { 'Build Claude request': built });
ok('Gemini quota error falls back', () => assert.strictEqual(gemErr.ai_status, 'api_error_fallback'));

// 6. all-clear path
const quiet = JSON.parse(JSON.stringify(payload));
quiet.lanes_flagged = []; quiet.hubs_flagged = []; quiet.network.lanes_flagged = 0; quiet.network.hubs_flagged = 0;
const builtQuiet = runNode('build_claude_request.js', { payload: quiet }, { Config: config });
const clear = runNode('all_clear.js', builtQuiet);
ok('no flags -> skip Claude, send all-clear', () => {
  assert.strictEqual(builtQuiet.has_flags, false);
  assert.ok(clear.message_text.includes('All 12 lanes'));
});
out.all_clear = clear.message_text;

// 7. DQ alert path, using the real query output from the --bad-data run
const dqLine = read('samples/dq_result_bad_data.txt').trim().split(' | ');
const dq = runNode('dq_alert.js', { report_date: dqLine[0], dq_pass: dqLine[1] === 't', checks: dqLine[3] });
ok('failed DQ gate -> alert listing the failed checks', () => {
  assert.ok(dq.message_text.includes('volume_vs_same_weekday'));
  assert.ok(dq.message_text.includes('duplicate_attempts'));
  assert.strictEqual(dq.log.dq_pass, false);
});
out.dq_alert = dq.message_text;

// 8. Discord splitter: every chunk under 2,000 chars, nothing lost, issues not cut in half
const splitAll = (text) => {
  let code = read('n8n/code/split_for_discord.js');
  const $input = { first: () => ({ json: { message_text: text } }) };
  return new Function('$input', code)($input).map(x => x.json.content);
};
ok('Discord splitter keeps every message under 2,000 chars and loses nothing', () => {
  for (const v of Object.values(out)) {
    const parts = splitAll(v);
    parts.forEach(p => assert.ok(p.length <= 2000, p.length));
    assert.strictEqual(parts.join('\n\n'), v);
  }
  const long = splitAll('x'.repeat(5000));
  assert.ok(long.every(p => p.length <= 2000) && long.join('').length === 5000);
});
ok('message uses Discord markdown, no Slack-only syntax', () => {
  for (const v of Object.values(out)) {
    assert.ok(!/:[a-z_-]+:/.test(v.replace(/https?:\/\/\S+/g, '')), 'emoji shortcode left: ' + v.match(/:[a-z_-]+:/));
  }
  assert.ok(out.validated.includes('**LaneWatch'));
});

// 9. issues_today: facts only, from the SQL payload, identical whether or not the AI passed
ok('issues_today: facts only, straight from SQL, no AI text', () => {
  const runRows = fmtNode => new Function('$', read('n8n/code/issues_today_rows.js'))(n => {
    const m = { 'Validate & format': fmtNode, 'Build AI request': built };
    if (!(n in m)) throw new Error('unexecuted'); return { first: () => ({ json: m[n] }) };
  }).map(x => x.json);
  const rows = runRows(good);
  assert.deepStrictEqual(Object.keys(rows[0]), ['Date', 'Severity', 'Where', 'What happened']);
  assert.strictEqual(rows.length, 1 + payload.lanes_flagged.length);
  assert.strictEqual(rows[0].Where, 'KKC hub');
  assert.ok(rows.find(r => r.Where === 'BKK-CNX')['What happened'].includes('72.9% (usually 85.2%)'));
  const allowed = JSON.stringify(payload);
  rows.forEach(r => (r['What happened'].match(/\d+(\.\d+)?/g) || []).forEach(n => assert.ok(allowed.includes(n), n)));
  assert.deepStrictEqual(runRows(bad), rows);
  const t3 = runNode('issues_today_rows.js', {}, { 'DQ alert': dq });
  assert.ok(t3['What happened'].startsWith('Data check failed'));
});

for (const [k, v] of Object.entries(out)) fs.writeFileSync(path.join(root, `samples/message_${k}.txt`), v + '\n');
console.log(`\n${passed} tests passed. Message samples written to samples/message_*.txt`);
