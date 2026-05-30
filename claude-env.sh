# Source this before running `claude` to send its telemetry to the local
# claude-collector (which forwards to Honeycomb).
#
#   source claude-env.sh
#   claude

# ---- Core: telemetry on, traces beta on (required for Agent Timeline) ----
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# Send metrics, logs, and traces over OTLP.
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp

# Point at the local collector. We use non-standard host ports (4327 gRPC /
# 4328 HTTP) so the default OTLP ports stay free for other collectors.
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4327"

# service.name -> Honeycomb dataset name for traces.
# Commented out so we can see what Claude Code defaults service.name to.
# export OTEL_SERVICE_NAME=claude-code

# Custom resource attributes. Add anything you want to tag every span with.
export OTEL_RESOURCE_ATTRIBUTES="source=claude-code"

# ---- Detailed beta tracing (richer per-LLM-call trace + logs) ----
# Each `chat` span gets a span link of link.type=parent_of pointing at a
# detailed sub-trace exported through this knob.
#
# IMPORTANT: BETA_TRACING_ENDPOINT speaks OTLP *HTTP*, not gRPC.
# Claude Code POSTs to $BETA_TRACING_ENDPOINT/v1/traces and /v1/logs --
# those are HTTP-only paths. If you point this at our gRPC port (4327)
# the requests silently go nowhere and the `parent_of` links look like
# dead ends. Point it at the HTTP port (4328) instead.
# Cross-ref: github.com/honeycombio/autobots/blob/main/otelcol/collector.yaml
# Temporarily off so we can see what's lost without it.
# export ENABLE_BETA_TRACING_DETAILED=1
# export BETA_TRACING_ENDPOINT="http://localhost:4328"

# ---- Content gates: include prompts, tool I/O, and raw API bodies ----
# Each of these reveals sensitive content. Comment any of them out for
# privacy-sensitive use.
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_LOG_TOOL_CONTENT=1
# Logs full Anthropic Messages API request and response as separate log events
# (`claude_code.api_request_body`, `..._response_body`). Implies all the
# OTEL_LOG_* gates above. Bodies are truncated at 60 KB.
export OTEL_LOG_RAW_API_BODIES=1

# ---- Metrics cardinality (default values shown; OTEL_METRICS_INCLUDE_VERSION defaults off) ----
export OTEL_METRICS_INCLUDE_VERSION=true
export OTEL_METRICS_INCLUDE_SESSION_ID=true
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true

# ---- Export intervals (all in milliseconds) ----
# Claude Code exposes one interval knob per signal. Defaults per
# https://code.claude.com/docs/en/monitoring-usage:
#   OTEL_METRIC_EXPORT_INTERVAL  default 60000  (60s)
#   OTEL_LOGS_EXPORT_INTERVAL    default  5000  ( 5s)
#   OTEL_TRACES_EXPORT_INTERVAL  default  5000  ( 5s)  -- span batch interval
# We leave metrics at the 60s default (low value in seeing them faster) and
# push logs + traces down so interactive sessions feel near-live in Honeycomb.
export OTEL_METRIC_EXPORT_INTERVAL=60000
export OTEL_LOGS_EXPORT_INTERVAL=1000
export OTEL_TRACES_EXPORT_INTERVAL=1000

echo "Claude Code will send telemetry to ${OTEL_EXPORTER_OTLP_ENDPOINT}"
