// n8n Code node: "All clear" (data passed DQ and nothing was flagged: no need to call Claude)
const { payload } = $input.first().json;
const n = payload.network;
const watch = payload.recurring_patterns
  .map(r => `${r.hub_code} ${r.flow}: weekend median ${r.weekend_dwell_p50_h}h vs weekday ${r.weekday_dwell_p50_h}h`);
const text = [
  `**LaneWatch · Daily lane health · ${payload.report_date}**`,
  `🟢 All ${n.lanes_total} lanes within normal range.`,
  `First-attempt success **${n.first_attempt_success_pct}%** (baseline ${n.first_attempt_success_baseline_pct}%) · On-time **${n.lead_time_compliance_pct}%** (baseline ${n.lead_time_compliance_baseline_pct}%)`,
  watch.length ? `**Watchlist:** ${watch.join(' · ')}` : '',
].filter(Boolean).join('\n');

return [{
  json: {
    report_date: payload.report_date,
    message_text: text,
    issue_rows: [],
    lane_rows: payload.all_lanes.map(l => ({ report_date: payload.report_date, ...l, severity: l.severity || '' })),
    log: { report_date: payload.report_date, dq_pass: true, lanes_flagged: 0, hubs_flagged: 0, ai_status: 'skipped', notes: 'no flags' },
  },
}];
