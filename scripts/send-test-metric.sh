#!/usr/bin/env bash
# Sends one synthetic OTLP/HTTP gauge data point to the local collector, so you
# can check the metrics pipeline's exporters without running Claude Code.
set -euo pipefail
ENDPOINT="${1:-http://localhost:4328}"
NOW_NS=$(( $(date +%s) * 1000000000 ))
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST "$ENDPOINT/v1/metrics" \
  -H 'Content-Type: application/json' -d @- <<JSON
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-collector-test"}}]},
 "scopeMetrics":[{"metrics":[{"name":"claude_collector.test","gauge":{"dataPoints":[
   {"timeUnixNano":"$NOW_NS","asInt":"1","attributes":[{"key":"test","value":{"boolValue":true}}]}]}}]}]}]}
JSON
