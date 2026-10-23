#!/usr/bin/env bash
# Sends one synthetic claude_code.tool span with no tool_input, so the
# gen_ai.tool.call.arguments fallback (hand-escaped JSON string) runs.
# full_command holds a quote, a backslash, a newline and a tab. Look it up in
# Honeycomb by the printed trace_id and check that gen_ai.tool.call.arguments
# parses as JSON: {"command": "<the same text>"}.
set -euo pipefail
ENDPOINT="${1:-http://localhost:4328}"
NOW_NS=$(( $(date +%s) * 1000000000 ))
TRACE_ID=$(openssl rand -hex 16); SPAN_ID=$(openssl rand -hex 8)
# printf turns \t and \n into real tab and newline; jq escapes them for the payload.
COMMAND=$(printf 'echo "hi there" | grep a\\\\b\n\tdone')
jq -n --arg trace "$TRACE_ID" --arg span "$SPAN_ID" --arg now "$NOW_NS" \
  --arg end "$((NOW_NS+1000000))" --arg cmd "$COMMAND" '
{resourceSpans:[{resource:{attributes:[{key:"service.name",value:{stringValue:"claude-collector-test"}}]},
 scopeSpans:[{spans:[{traceId:$trace,spanId:$span,name:"claude_code.tool",kind:1,
   startTimeUnixNano:$now,endTimeUnixNano:$end,
   attributes:[{key:"test",value:{boolValue:true}},
               {key:"tool_name",value:{stringValue:"Bash"}},
               {key:"full_command",value:{stringValue:$cmd}}]}]}]}]}' |
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST "$ENDPOINT/v1/traces" \
  -H 'Content-Type: application/json' -d @-
echo "full_command=$(printf '%q' "$COMMAND")"
echo "trace_id=$TRACE_ID"
