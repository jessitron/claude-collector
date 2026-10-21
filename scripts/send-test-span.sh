#!/usr/bin/env bash
# Sends one synthetic OTLP/HTTP span to the local collector, so you can check
# the exporters without running Claude Code. The span is named
# "claude-collector.test" and carries test=true.
set -euo pipefail
ENDPOINT="${1:-http://localhost:4328}"
NOW_NS=$(( $(date +%s) * 1000000000 ))
TRACE_ID=$(openssl rand -hex 16); SPAN_ID=$(openssl rand -hex 8)
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST "$ENDPOINT/v1/traces" \
  -H 'Content-Type: application/json' -d @- <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-collector-test"}}]},
 "scopeSpans":[{"spans":[{"traceId":"$TRACE_ID","spanId":"$SPAN_ID","name":"claude-collector.test","kind":1,
   "startTimeUnixNano":"$NOW_NS","endTimeUnixNano":"$((NOW_NS+1000000))",
   "attributes":[{"key":"test","value":{"boolValue":true}}]}]}]}]}
JSON
echo "trace_id=$TRACE_ID"
