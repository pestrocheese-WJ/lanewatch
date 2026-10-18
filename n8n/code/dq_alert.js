// n8n Code node: "DQ alert" (data-quality gate failed: send an alert, NOT a summary)
const row = $input.first().json;
const checks = typeof row.checks === 'string' ? JSON.parse(row.checks) : row.checks;
const failed = checks.filter(c => !c.ok);
const text = [
  `**LaneWatch · 🚨 Data-quality gate FAILED · ${row.report_date}**`,
  `No performance summary was sent, because it would be built on bad data.`,
  ...failed.map(c => `• **${c.check}**: observed \`${c.observed}\`, expected ${c.rule}`),
  `_Passed: ${checks.filter(c => c.ok).map(c => c.check).join(', ')}_`,
  `Next step: check the upstream feed, reload, then re-run the workflow manually.`,
].join('\n');

return [{
  json: {
    report_date: row.report_date,
    message_text: text,
    issue_rows: [],
    lane_rows: [],
    log: {
      report_date: row.report_date, dq_pass: false, lanes_flagged: 0, hubs_flagged: 0, ai_status: 'skipped',
      notes: failed.map(c => `${c.check}=${c.observed}`).join('; ').slice(0, 500),
    },
  },
}];
