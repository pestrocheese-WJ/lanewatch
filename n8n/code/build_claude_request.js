// n8n Code node: "Build Claude request"
// Input: one row from the "Daily lane report" Postgres query (column `payload`).
// Output: the request body for the Claude Messages API + data the next nodes need.
let payload = $input.first().json.payload;
if (typeof payload === 'string') payload = JSON.parse(payload);
const cfg = $('Config').first().json;

// Only send Claude what it needs to explain: flagged items + context. `all_lanes` stays out.
const claude_input = {
  report_date: payload.report_date,
  baseline_window: payload.baseline_window,
  targets: payload.targets,
  network: payload.network,
  lanes_flagged: payload.lanes_flagged,
  hubs_flagged: payload.hubs_flagged,
  recurring_patterns: payload.recurring_patterns,
};
const has_flags = payload.lanes_flagged.length + payload.hubs_flagged.length > 0;

// Kept in prompts/system_prompt.md; injected here by build_workflow.py
const SYSTEM_PROMPT = __SYSTEM_PROMPT__;

return [{
  json: {
    report_date: payload.report_date,
    payload,
    claude_input,
    has_flags,
    request_body: {
      model: cfg.ai_model,
      max_tokens: 3000,
      system: SYSTEM_PROMPT,
      messages: [{
        role: 'user',
        content: `Daily lane-health data for ${payload.report_date}. Explain the flagged lanes and hubs.\n\n<data>\n${JSON.stringify(claude_input)}\n</data>`,
      }],
    },
  },
}];
