"""
Builds the importable n8n workflow JSON from the source files, so the SQL, the prompt and the
Code-node JavaScript live in one place each (sql/, prompts/, n8n/code/) and stay in sync.

    python n8n/build_workflow.py   ->  n8n/lanewatch_daily.json, n8n/lanewatch_error_alert.json
"""
import json
import os
import uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def nid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "lanewatch/" + name))


PG_CRED = {"postgres": {"id": "REPLACE_ME", "name": "LaneWatch Postgres"}}
SHEETS_CRED = {"googleSheetsOAuth2Api": {"id": "REPLACE_ME", "name": "Google Sheets account"}}
CLAUDE_CRED = {"httpHeaderAuth": {"id": "REPLACE_ME", "name": "Anthropic API key"}}
REPORT_DATE = "={{ $('Config').first().json.report_date }}"


def node(name, ntype, version, pos, params, **extra):
    n = {"parameters": params, "id": nid(name), "name": name, "type": ntype,
         "typeVersion": version, "position": pos}
    n.update(extra)
    return n


def postgres(name, pos, sql, replacement=None, **extra):
    opts = {"queryReplacement": replacement} if replacement else {}
    return node(name, "n8n-nodes-base.postgres", 2.5, pos,
                {"operation": "executeQuery", "query": sql, "options": opts},
                credentials=PG_CRED, **extra)


def code(name, pos, js):
    return node(name, "n8n-nodes-base.code", 2, pos, {"jsCode": js})


def if_true(name, pos, left):
    return node(name, "n8n-nodes-base.if", 2.2, pos, {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
            "conditions": [{
                "id": nid(name + "/c"), "leftValue": left, "rightValue": "",
                "operator": {"type": "boolean", "operation": "true", "singleValue": True},
            }],
            "combinator": "and",
        },
        "options": {},
    })


def sheets_append(name, pos, sheet_name):
    return node(name, "n8n-nodes-base.googleSheets", 4.5, pos, {
        "operation": "append",
        "documentId": {"__rl": True, "value": "PASTE_YOUR_GOOGLE_SHEET_ID", "mode": "id"},
        "sheetName": {"__rl": True, "value": sheet_name, "mode": "name"},
        "columns": {"mappingMode": "autoMapInputData", "value": {}, "matchingColumns": [], "schema": []},
        # USER_ENTERED: Postgres returns numerics as text ("88.9"); this lets Sheets store them as numbers
        "options": {"cellFormat": "USER_ENTERED"},
    }, credentials=SHEETS_CRED)


def sheets_clear(name, pos, sheet_name):
    # wipe everything below the header row, so the tab is fully rewritten each morning
    return node(name, "n8n-nodes-base.googleSheets", 4.5, pos, {
        "operation": "clear",
        "documentId": {"__rl": True, "value": "PASTE_YOUR_GOOGLE_SHEET_ID", "mode": "id"},
        "sheetName": {"__rl": True, "value": sheet_name, "mode": "name"},
        "clear": "wholeSheet",
        "keepFirstRow": True,
    }, credentials=SHEETS_CRED, executeOnce=True)


def link(*names):
    return [{"node": n, "type": "main", "index": 0} for n in names]


system_prompt = read("prompts/system_prompt.md")
build_js = read("n8n/code/build_claude_request.js").replace("__SYSTEM_PROMPT__", json.dumps(system_prompt))

nodes = [
    node("Every day 08:00", "n8n-nodes-base.scheduleTrigger", 1.2, [0, 0],
         {"rule": {"interval": [{"field": "cronExpression", "expression": "0 8 * * *"}]}}),
    node("Run manually", "n8n-nodes-base.manualTrigger", 1, [0, 200], {}),
    node("Config", "n8n-nodes-base.set", 3.4, [220, 100], {
        "assignments": {"assignments": [
            {"id": nid("cfg/date"), "name": "report_date", "type": "string",
             "value": "={{ $now.setZone('Asia/Bangkok').minus({ days: 1 }).toFormat('yyyy-MM-dd') }}"},
            {"id": nid("cfg/model"), "name": "ai_model", "type": "string", "value": "claude-sonnet-5-5"},
            {"id": nid("cfg/discord"), "name": "discord_webhook_url", "type": "string",
             "value": "PASTE_YOUR_DISCORD_WEBHOOK_URL"},
        ]},
        "options": {},
    }),
    postgres("Data-quality checks", [440, 100], read("sql/04_dq_checks.sql"), REPORT_DATE),
    if_true("DQ passed?", [660, 100], "={{ $json.dq_pass }}"),
    postgres("Refresh KPI tables", [880, 0], read("sql/06_refresh.sql")),
    postgres("Daily lane report", [1100, 0], read("sql/05_lane_report.sql"), REPORT_DATE),
    code("Build Claude request", [1320, 0], build_js),
    if_true("Anything flagged?", [1540, 0], "={{ $json.has_flags }}"),
    node("Ask Claude to explain", "n8n-nodes-base.httpRequest", 4.2, [1760, -100], {
        "method": "POST",
        "url": "https://api.anthropic.com/v1/messages",
        "authentication": "genericCredentialType",
        "genericAuthType": "httpHeaderAuth",
        "sendHeaders": True,
        "headerParameters": {"parameters": [
            {"name": "anthropic-version", "value": "2023-06-01"},
            {"name": "content-type", "value": "application/json"},
        ]},
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify($json.request_body) }}",
        "options": {"timeout": 120000},
    }, credentials=CLAUDE_CRED, retryOnFail=True, maxTries=3, waitBetweenTries=5000,
       onError="continueRegularOutput"),
    code("Validate & format", [1980, -100], read("n8n/code/validate_and_format.js")),
    code("All clear", [1980, 120], read("n8n/code/all_clear.js")),
    code("DQ alert", [1980, 300], read("n8n/code/dq_alert.js")),
    code("Split for Discord", [2280, -200], read("n8n/code/split_for_discord.js")),
    node("Post to Discord", "n8n-nodes-base.httpRequest", 4.2, [2500, -200], {
        "method": "POST",
        "url": "={{ $('Config').first().json.discord_webhook_url }}",
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify({ content: $json.content, allowed_mentions: { parse: [] } }) }}",
        "options": {"batching": {"batch": {"batchSize": 1, "batchInterval": 1000}}},
    }),
    code("Issue rows", [2280, -20], "return $input.first().json.issue_rows.map(r => ({ json: r }));"),
    sheets_append("Sheet: Issues", [2500, -20], "Issues"),
    code("Lane KPI rows", [2280, 160], "return $input.first().json.lane_rows.map(r => ({ json: r }));"),
    sheets_append("Sheet: Lane KPIs", [2500, 160], "Lane KPIs"),
    postgres("Write run log", [2280, 340],
             "INSERT INTO run_log (report_date, dq_pass, lanes_flagged, hubs_flagged, ai_status, notes)\n"
             "VALUES ($1::date, $2::boolean, $3::int, $4::int, $5, $6);",
             # one expression returning an array: Postgres node v2.5 passes each item as its own
             # parameter, so commas inside the notes text can't split the values
             "={{ [$json.log.report_date, $json.log.dq_pass, $json.log.lanes_flagged, "
             "$json.log.hubs_flagged, $json.log.ai_status, $json.log.notes] }}"),
]

# ---------------------------------------------------------------- dashboard tabs
# After the KPI tables are refreshed (data already passed the DQ gate), rewrite the three
# Looker Studio tabs. Sequential chain: clear tab -> run query -> append rows, x3.
DASH = ["lane_summary", "lane_weekly", "hub_weekly"]
dash_nodes, dash_chain = [], []
for i, tab in enumerate(DASH):
    x = 1100 + i * 660
    clear_n, query_n, append_n = f"Clear {tab}", f"Query {tab}", f"Write {tab}"
    dash_nodes += [
        sheets_clear(clear_n, [x, -420], tab),
        postgres(query_n, [x + 220, -420], read(f"sql/dashboard/{tab}.sql"), executeOnce=True),
        sheets_append(append_n, [x + 440, -420], tab),
    ]
    dash_chain += [clear_n, query_n, append_n]
nodes += dash_nodes

# "issues_today" tab: cleared every run and rewritten with a short version of today's issues,
# so the dashboard table stays small and readable (full history stays in the "Issues" tab).
nodes += [
    sheets_clear("Clear issues_today", [2280, 520], "issues_today"),
    code("Issues today rows", [2500, 520], read("n8n/code/issues_today_rows.js")),
    sheets_append("Write issues_today", [2720, 520], "issues_today"),
]

outputs = link("Split for Discord", "Issue rows", "Lane KPI rows", "Write run log", "Clear issues_today")
connections = {
    "Every day 08:00": {"main": [link("Config")]},
    "Run manually": {"main": [link("Config")]},
    "Config": {"main": [link("Data-quality checks")]},
    "Data-quality checks": {"main": [link("DQ passed?")]},
    "DQ passed?": {"main": [link("Refresh KPI tables"), link("DQ alert")]},
    "Refresh KPI tables": {"main": [link("Daily lane report", dash_chain[0])]},
    "Daily lane report": {"main": [link("Build Claude request")]},
    "Build Claude request": {"main": [link("Anything flagged?")]},
    "Anything flagged?": {"main": [link("Ask Claude to explain"), link("All clear")]},
    "Ask Claude to explain": {"main": [link("Validate & format")]},
    "Validate & format": {"main": [outputs]},
    "All clear": {"main": [outputs]},
    "DQ alert": {"main": [outputs]},
    "Split for Discord": {"main": [link("Post to Discord")]},
    **{a: {"main": [link(b)]} for a, b in zip(dash_chain, dash_chain[1:])},
    "Clear issues_today": {"main": [link("Issues today rows")]},
    "Issues today rows": {"main": [link("Write issues_today")]},
    "Issue rows": {"main": [link("Sheet: Issues")]},
    "Lane KPI rows": {"main": [link("Sheet: Lane KPIs")]},
}

sticky = node("README", "n8n-nodes-base.stickyNote", 1, [-40, -320], {
    "content": "## LaneWatch: daily lane health\n"
               "1. Data-quality gate. If it fails, send an alert, not a summary.\n"
               "2. Refresh KPI tables, then SQL flags lanes/hubs (z-score + targets).\n"
               "3. Claude explains ONLY the flagged items.\n"
               "4. Every number Claude writes is checked against the input. If any check fails, a rule-based summary is sent instead.\n"
               "5. Discord + Google Sheets + run_log.\n"
               "6. Top row: rewrites the 3 Looker Studio tabs every morning.\n\n"
               "Set credentials on: Postgres nodes, 'Ask Claude to explain' (Header Auth: x-api-key), Google Sheets. Paste your Discord webhook URL in Config.",
    "height": 260, "width": 520,
})

workflow = {
    "name": "LaneWatch · Daily lane health",
    "nodes": [sticky] + nodes,
    "connections": connections,
    "settings": {"executionOrder": "v1", "timezone": "Asia/Bangkok",
                 "errorWorkflow": "SET_TO_LANEWATCH_ERROR_ALERT_ID"},
    "pinData": {},
    "active": False,
}

error_wf = {
    "name": "LaneWatch · Error alert",
    "nodes": [
        node("When LaneWatch fails", "n8n-nodes-base.errorTrigger", 1, [0, 0], {}),
        node("Alert on Discord", "n8n-nodes-base.httpRequest", 4.2, [240, 0], {
            "method": "POST",
            "url": "PASTE_YOUR_DISCORD_WEBHOOK_URL",
            "sendBody": True,
            "specifyBody": "json",
            "jsonBody": "={{ JSON.stringify({ content: '🚨 **LaneWatch pipeline failed**\\nNode: `' + $json.execution.lastNodeExecuted + '`\\nError: ' + (($json.execution.error || {}).message || 'unknown') + '\\nExecution: ' + $json.execution.url, allowed_mentions: { parse: [] } }) }}",
            "options": {},
        }),
    ],
    "connections": {"When LaneWatch fails": {"main": [link("Alert on Discord")]}},
    "settings": {"executionOrder": "v1", "timezone": "Asia/Bangkok"},
    "pinData": {},
    "active": False,
}

# ---------------------------------------------------------------- free variant: Gemini
# Same workflow, but the AI step calls Google's Gemini API (has a free tier) instead of Claude.
# Same prompt, same validator: only the HTTP node and the model name change.
import copy
gemini = copy.deepcopy(workflow)
gemini["name"] = "LaneWatch · Daily lane health (Gemini, free tier)"
for n in gemini["nodes"]:
    if n["name"] == "Config":
        for a in n["parameters"]["assignments"]["assignments"]:
            if a["name"] == "ai_model":
                a["value"] = "gemini-flash-latest"   # change to any free-tier Flash model listed in AI Studio
    if n["name"] == "Ask Claude to explain":
        n["name"] = "Ask Gemini to explain"
        n["id"] = nid("Ask Gemini to explain")
        n["credentials"] = {"httpHeaderAuth": {"id": "REPLACE_ME", "name": "Gemini API key"}}
        n["parameters"]["url"] = ("=https://generativelanguage.googleapis.com/v1beta/models/"
                                  "{{ $('Config').first().json.ai_model }}:generateContent")
        n["parameters"]["headerParameters"] = {"parameters": [
            {"name": "content-type", "value": "application/json"}]}
        n["parameters"]["jsonBody"] = (
            "={{ JSON.stringify({"
            " system_instruction: { parts: [{ text: $json.request_body.system }] },"
            " contents: [{ role: 'user', parts: [{ text: $json.request_body.messages[0].content }] }],"
            " generationConfig: { responseMimeType: 'application/json', temperature: 0.2, maxOutputTokens: 8192 }"
            " }) }}")
    if n["name"] == "README":
        n["parameters"]["content"] = n["parameters"]["content"].replace(
            "'Ask Claude to explain' (Header Auth: x-api-key)",
            "'Ask Gemini to explain' (Header Auth: name x-goog-api-key, value = key from aistudio.google.com)")
# Rename the shared prompt-builder node so the Gemini version doesn't say "Claude",
# and update every reference to it (connections + $('...') lookups inside code/expressions).
gem_json = json.dumps(gemini, ensure_ascii=False)
gem_json = gem_json.replace("Build Claude request", "Build AI request")
gemini = json.loads(gem_json)
for n in gemini["nodes"]:
    if n["name"] == "Build AI request":
        n["id"] = nid("Build AI request")
conns = gemini["connections"]
conns["Anything flagged?"]["main"][0][0]["node"] = "Ask Gemini to explain"
conns["Ask Gemini to explain"] = conns.pop("Ask Claude to explain")

for fname, wf in (("lanewatch_daily.json", workflow), ("lanewatch_error_alert.json", error_wf),
                  ("lanewatch_daily_gemini.json", gemini)):
    with open(os.path.join(ROOT, "n8n", fname), "w", encoding="utf-8") as f:
        json.dump(wf, f, indent=2, ensure_ascii=False)
    print("wrote n8n/" + fname, f"({len(wf['nodes'])} nodes)")
