// n8n Code node: "Validate & format"
// Runs after the Claude API call (that node is set to continue on error).
//  1. Parses Claude's JSON.
//  2. Hallucination check: every number Claude wrote must exist in the data it was given,
//     every lane code must be real, and every flagged lane/hub must be covered.
//  3. If anything fails (or the API errored), falls back to a rule-based summary so ops
//     still get a correct report, clearly labelled.
//  4. Formats one chat message (Discord markdown) + rows for Google Sheets + a run-log entry.
const req = $('Build Claude request').first().json;
const payload = req.payload;
const resp = $input.first().json;

// ---------------------------------------------------------------- validation helpers
function collectNumbers(node, out) {
  if (node === null || node === undefined) return out;
  if (typeof node === 'number') out.push(Math.abs(node));
  else if (typeof node === 'string') (node.match(/\d+(?:\.\d+)?/g) || []).forEach(n => out.push(parseFloat(n)));
  else if (Array.isArray(node)) node.forEach(x => collectNumbers(x, out));
  else if (typeof node === 'object') Object.entries(node).forEach(([k, v]) => { collectNumbers(k, out); collectNumbers(v, out); });
  return out;
}
function numbersInText(text) {
  const clean = text.replace(/(\d),(?=\d{3}\b)/g, '$1');            // 1,401 -> 1401
  return (clean.match(/\d+(?:\.\d+)?/g) || []).map(Number);
}
function textOf(node) {
  if (node === null || node === undefined) return '';
  if (typeof node === 'string') return node + '\n';
  if (Array.isArray(node)) return node.map(textOf).join('');
  if (typeof node === 'object') return Object.values(node).map(textOf).join('');
  return String(node) + '\n';
}

function validate(ai) {
  const issues = [];
  if (!ai || typeof ai.headline !== 'string' || !Array.isArray(ai.issues)) {
    return { ok: false, issues: ['Output does not match the expected JSON shape'], checked: 0 };
  }
  if (req.has_flags && ai.issues.length === 0) issues.push('No issues returned although items were flagged');

  // (a) numbers: each must exist in the input (abs value, 0.05 tolerance, or a rounding of it)
  const allowed = collectNumbers(req.claude_input, []);
  const text = textOf(ai);
  const found = numbersInText(text);
  const unknown = [...new Set(found.filter(x => {
    if (Number.isInteger(x) && x <= 3) return false;                  // small counts ("2 lanes")
    return !allowed.some(a => Math.abs(x - a) < 0.051
      || (Number.isInteger(x) && (x === Math.round(a) || x === Math.floor(a))));
  }))];
  if (unknown.length) issues.push(`Numbers not in source data: ${unknown.slice(0, 8).join(' ')}`);

  // (b) lane codes must exist
  const knownLanes = new Set(payload.all_lanes.map(l => l.lane));
  const lanesMentioned = [...new Set(text.match(/\b[A-Z]{3}-[A-Z]{3}\b/g) || [])];
  const fakeLanes = lanesMentioned.filter(l => !knownLanes.has(l));
  if (fakeLanes.length) issues.push(`Unknown lanes: ${fakeLanes.join(' ')}`);

  // (c) coverage: every flagged lane and hub appears in some issue's "affected"
  const affected = new Set(ai.issues.flatMap(i => Array.isArray(i.affected) ? i.affected : []));
  const missing = [
    ...payload.lanes_flagged.map(l => l.lane),
    ...[...new Set(payload.hubs_flagged.map(h => h.hub_code))],
  ].filter(code => !affected.has(code));
  if (missing.length) issues.push(`Flagged but not explained: ${missing.join(' ')}`);

  return { ok: issues.length === 0, issues, checked: found.length };
}

// ---------------------------------------------------------------- rule-based fallback
function fallbackSummary(p) {
  const out = [];
  const lanesCovered = new Set();
  const hubs = {};
  p.hubs_flagged.forEach(h => { (hubs[h.hub_code] = hubs[h.hub_code] || []).push(h); });

  for (const [code, rows] of Object.entries(hubs)) {
    const lanesHit = p.lanes_flagged
      .filter(l => rows.some(r => r.lanes_through_hub.includes(l.lane)))
      .map(l => l.lane);
    lanesHit.forEach(l => lanesCovered.add(l));
    const parts = rows.map(r => `${r.flow} median ${r.dwell_p50_h}h (usual ${r.dwell_p50_same_weekday_baseline_h}h)`);
    out.push({
      title: `${rows[0].hub_name} processing slowdown`,
      scope: 'hub', affected: [code, ...lanesHit],
      severity: lanesHit.length >= 2 ? 'high' : 'medium',
      what_happened: `${rows[0].hub_name}: ${parts.join('; ')}.`,
      one_liner: `${rows[0].hub_name} parcels wait ${rows[0].dwell_p50_h}h instead of ${rows[0].dwell_p50_same_weekday_baseline_h}h`,
      likely_cause: 'Hub-level processing delay; rules cannot determine why.',
      evidence: parts, confidence: 'medium',
      suggested_action: `Check staffing, sorter capacity and backlog at ${code} today.`,
      control_metric: `${code} median processing time back under ${p.targets.hub_dwell_p50_max_h}h`,
    });
  }

  for (const l of p.lanes_flagged.filter(x => !lanesCovered.has(x.lane))) {
    const k = l.kpis;
    const facts = [];
    let cause = '';
    if (l.breaches.includes('first_attempt_success')) {
      facts.push(`First-attempt success ${k.first_attempt_success_pct}% vs ${k.first_attempt_success_baseline_pct}% baseline`);
      const r = (l.fail_reasons_first_attempt || []).slice()
        .sort((a, b) => (b.today_share_pct - b.baseline_share_pct) - (a.today_share_pct - a.baseline_share_pct))[0];
      const s = (l.first_attempt_fail_rate_by_time || []).slice()
        .sort((a, b) => (b.today_fail_pct - b.baseline_fail_pct) - (a.today_fail_pct - a.baseline_fail_pct))[0];
      if (r) { facts.push(`${r.reason} is ${r.today_share_pct}% of failures (baseline ${r.baseline_share_pct}%)`); cause += `Rise in ${r.reason} failures. `; }
      if (s) facts.push(`${s.slot.slice(2)} fail rate ${s.today_fail_pct}% (baseline ${s.baseline_fail_pct}%)`);
      if (k.final_delivered_rate_pct >= k.final_delivered_rate_baseline_pct - 1 && k.attempts_per_parcel > k.attempts_per_parcel_baseline) {
        facts.push(`Final delivered rate still ${k.final_delivered_rate_pct}% but attempts per parcel ${k.attempts_per_parcel} (baseline ${k.attempts_per_parcel_baseline})`);
        cause += 'Hidden by re-attempts. ';
      }
    }
    if (l.breaches.includes('lead_time_compliance')) {
      facts.push(`On-time ${k.lead_time_compliance_pct}% vs ${k.lead_time_compliance_baseline_pct}% baseline`);
      const t = l.time_breakdown_h;
      const legs = [['origin hub', t.origin_hub_dwell_p50_today, t.origin_hub_dwell_p50_baseline],
                    ['linehaul', t.linehaul_p50_today, t.linehaul_p50_baseline],
                    ['destination hub', t.dest_hub_dwell_p50_today, t.dest_hub_dwell_p50_baseline]]
        .filter(x => x[1] !== null && x[2] !== null)
        .sort((a, b) => (b[1] - b[2]) - (a[1] - a[2]));
      if (legs.length) { facts.push(`${legs[0][0]} median ${legs[0][1]}h (baseline ${legs[0][2]}h)`); cause += `Most added time at ${legs[0][0]}. `; }
    }
    out.push({
      title: `${l.lane}: ${l.breaches.join(' + ').replace(/_/g, ' ')}`,
      scope: 'lane', affected: [l.lane], severity: l.severity,
      what_happened: facts[0] + '.', one_liner: `${l.lane}: ${facts[0]}`, likely_cause: cause.trim() || 'Not determined by rules.',
      evidence: facts.slice(1), confidence: 'low',
      suggested_action: `Review ${l.lane} with the ${l.dest_hub} regional team.`,
      control_metric: l.breaches.includes('first_attempt_success')
        ? `${l.lane} first-attempt success >= ${p.targets.first_attempt_success_min_pct}%`
        : `${l.lane} on-time >= ${p.targets.lead_time_compliance_min_pct}%`,
    });
  }
  const sev = { high: 0, medium: 1, low: 2 };
  out.sort((a, b) => sev[a.severity] - sev[b.severity] || b.affected.length - a.affected.length);
  return {
    headline: `${p.network.lanes_flagged} of ${p.network.lanes_total} lanes and ${p.network.hubs_flagged} hub(s) flagged.`,
    issues: out,
    watchlist: p.recurring_patterns.map(r => `${r.hub_code} ${r.flow}: weekend median ${r.weekend_dwell_p50_h}h vs weekday ${r.weekday_dwell_p50_h}h (recurring)`),
    summary_th: `พบเส้นทางผิดปกติ ${p.network.lanes_flagged} จาก ${p.network.lanes_total} เส้นทาง และฮับผิดปกติ ${p.network.hubs_flagged} แห่ง (สรุปด้วยกฎอัตโนมัติ)`,
  };
}

// ---------------------------------------------------------------- run
let ai = null, status = 'validated', problems = [], checked = 0;
// Accept both response formats: Claude Messages API (content[]) and Gemini generateContent (candidates[])
let rawText = null;
if (!resp.error && Array.isArray(resp.content)) {
  rawText = resp.content.filter(c => c.type === 'text').map(c => c.text).join('');
} else if (!resp.error && Array.isArray(resp.candidates) && resp.candidates[0]?.content?.parts) {
  rawText = resp.candidates[0].content.parts.map(p => p.text || '').join('');
}
if (rawText === null) {
  status = 'api_error_fallback';
  problems.push('AI API error: ' + JSON.stringify(resp.error || resp).slice(0, 160).replace(/,/g, ';'));
} else {
  const raw = rawText.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  try { ai = JSON.parse(raw); } catch (e) { problems.push('AI output was not valid JSON'); }
  const v = validate(ai);
  checked = v.checked;
  if (!v.ok) { status = 'rejected_fallback'; problems.push(...v.issues); }
}
const summary = status === 'validated' ? ai : fallbackSummary(payload);
const source = status === 'validated' ? 'claude' : 'rules';

// ---------------------------------------------------------------- format
const n = payload.network;
const icon = { high: '🔴', medium: '🟠', low: '🟡' };
// AI text is plain text: escape Discord markdown characters so a stray "_" or "*"
// (e.g. in a field name like lead_time_compliance_pct) can't turn half the message italic.
const esc = t => String(t == null ? '' : t).replace(/([\\_*~`|>])/g, '\\$1');
const lines = [
  `**LaneWatch · Daily lane health · ${payload.report_date}**`,
  `First-attempt success **${n.first_attempt_success_pct}%** (baseline ${n.first_attempt_success_baseline_pct}%) · On-time **${n.lead_time_compliance_pct}%** (baseline ${n.lead_time_compliance_baseline_pct}%) · ${n.lanes_flagged}/${n.lanes_total} lanes, ${n.hubs_flagged} hub(s) flagged`,
  '',
  `> ${esc(summary.headline)}`,
  '',
];
for (const i of summary.issues) {
  lines.push(`${icon[i.severity] || '⚪'} **${esc(i.title)}**  ${(i.affected || []).map(a => '`' + a + '`').join(' ')}`);
  lines.push(`> ${esc(i.one_liner || i.what_happened)}`);
  lines.push(`• **What:** ${esc(i.what_happened)}`);
  lines.push(`• **Likely cause:** ${esc(i.likely_cause)} (confidence: ${esc(i.confidence)})`);
  lines.push(`• **Action:** ${esc(i.suggested_action)}`);
  lines.push(`• **Track:** ${esc(i.control_metric)}`);
  lines.push('');
}
if (summary.watchlist && summary.watchlist.length) lines.push(`**Watchlist:** ${summary.watchlist.map(esc).join(' · ')}`, '');
if (summary.summary_th) lines.push(`🇹🇭 ${esc(summary.summary_th)}`, '');
lines.push(status === 'validated'
  ? `_AI summary validated: ${checked} numbers checked against source data._`
  : `_⚠️ AI summary not used (${esc(problems.join('; '))}). Showing rule-based summary._`);

const issue_rows = summary.issues.map(i => ({
  report_date: payload.report_date, severity: i.severity, scope: i.scope,
  affected: (i.affected || []).join(', '), title: i.title, one_liner: i.one_liner || i.what_happened, what_happened: i.what_happened,
  likely_cause: i.likely_cause, confidence: i.confidence, suggested_action: i.suggested_action,
  control_metric: i.control_metric, source,
}));
const lane_rows = payload.all_lanes.map(l => ({ report_date: payload.report_date, ...l, severity: l.severity || '' }));

return [{
  json: {
    report_date: payload.report_date,
    message_text: lines.join('\n'),
    summary, ai_status: status, problems,
    issue_rows, lane_rows,
    log: {
      report_date: payload.report_date, dq_pass: true,
      lanes_flagged: n.lanes_flagged, hubs_flagged: n.hubs_flagged,
      ai_status: status, notes: (problems.join('; ') || 'ok').replace(/,/g, ';').slice(0, 500),
    },
  },
}];
