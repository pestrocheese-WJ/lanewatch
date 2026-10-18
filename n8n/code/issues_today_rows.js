// n8n Code node: "Issues today rows"
// Builds the "issues_today" dashboard tab (cleared every run, so it only ever shows today).
//
// FACTS ONLY: every cell is written by code straight from the SQL detection output (the same numbers
// the SQL computed). No AI text appears in this table, so the dashboard can't be biased by the model.
// The AI's explanation and suggested actions go to Discord and the "Issues" history tab instead.
const pick = name => { try { return $(name).first().json; } catch (e) { return null; } };
const fmt = pick('Validate & format') || pick('All clear') || pick('DQ alert');
const req = pick('Build AI request') || pick('Build Claude request');
const date = fmt.report_date;
const SEV = { high: '🔴 High', medium: '🟠 Medium', low: '🟡 Low' };

// data-quality gate failed: no payload exists, report that fact only
if (fmt.log && fmt.log.dq_pass === false) {
  return [{ json: { Date: date, Severity: '⚪ n/a', Where: '-', 'What happened': 'Data check failed: data incomplete, no analysis today' } }];
}

const p = req && req.payload;
const lanes = (p && p.lanes_flagged) || [];
const hubs = (p && p.hubs_flagged) || [];
if (lanes.length + hubs.length === 0) {
  return [{ json: { Date: date, Severity: '🟢 OK', Where: 'All lanes', 'What happened': 'All lanes within normal range' } }];
}

// fact from the lanes table: which flagged hubs does this lane pass through?
const flaggedHubs = new Set(hubs.map(h => h.hub_code));
const viaHub = l => [l.origin_hub, l.dest_hub].filter(h => flaggedHubs.has(h));

const rows = [];

// one row per flagged hub (inbound + outbound combined)
const byHub = {};
hubs.forEach(h => { (byHub[h.hub_code] = byHub[h.hub_code] || []).push(h); });
for (const [code, hs] of Object.entries(byHub)) {
  const parts = hs.map(h => `${h.flow} ${h.dwell_p50_h}h (usually ${h.dwell_p50_same_weekday_baseline_h}h)`);
  rows.push({
    sev: 0,
    Severity: SEV.high,
    Where: `${code} hub`,
    'What happened': `Median processing time: ${parts.join(', ')}`,
  });
}

// one row per flagged lane, listing only the KPIs that breached
for (const l of lanes) {
  const k = l.kpis;
  const facts = [];
  if (l.breaches.includes('first_attempt_success'))
    facts.push(`First-attempt success ${k.first_attempt_success_pct}% (usually ${k.first_attempt_success_baseline_pct}%)`);
  if (l.breaches.includes('lead_time_compliance'))
    facts.push(`On-time ${k.lead_time_compliance_pct}% (usually ${k.lead_time_compliance_baseline_pct}%)`);
  rows.push({
    sev: l.severity === 'high' ? 1 : 2,
    Severity: SEV[l.severity] || l.severity,
    Where: l.lane,
    'What happened': facts.join('; ') + viaHub(l).map(h => ` · passes through ${h} hub`).join(''),
  });
}

rows.sort((a, b) => a.sev - b.sev);
return rows.map(({ sev, ...r }) => ({ json: { Date: date, ...r } }));
