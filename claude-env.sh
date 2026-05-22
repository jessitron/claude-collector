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
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4327

# service.name -> Honeycomb dataset name for traces.
# Commented out so we can see what Claude Code defaults service.name to.
# export OTEL_SERVICE_NAME=claude-code

# Custom resource attributes. Add anything you want to tag every span with.
export OTEL_RESOURCE_ATTRIBUTES="source=claude-code"

# ---- Detailed beta tracing (claude_code.hook spans + richer content attrs) ----
# Per the docs: requires your org to be allowlisted for the feature in
# *interactive* CLI sessions. Agent SDK and `claude -p` sessions are not gated.
# If interactive runs don't produce claude_code.hook spans after enabling this,
# allowlisting is the likely cause.
# TODO: verify whether modernity is allowlisted -- update this comment once
# we've checked.
#
# BETA_TRACING_ENDPOINT points at the local collector so detailed data flows
# through our transforms. If Claude Code turns out to want a real Honeycomb
# endpoint there, switch this to api.honeycomb.io:443.
export ENABLE_BETA_TRACING_DETAILED=1
export BETA_TRACING_ENDPOINT=http://localhost:4327

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

# ---- Faster export while debugging ----
# Defaults: metrics 60s, logs 5s. Comment out for production-y use.
export OTEL_METRIC_EXPORT_INTERVAL=60000
export OTEL_LOGS_EXPORT_INTERVAL=2000

echo "Claude Code will send telemetry to ${OTEL_EXPORTER_OTLP_ENDPOINT}"
