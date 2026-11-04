#!/usr/bin/env bash
# Run one tiny non-interactive Claude Code turn with the console trace exporter,
# so we see the spans exactly as Claude Code emits them -- before the collector
# renames or enriches anything. Use it to check which transforms are still needed
# after a Claude Code upgrade.
#
#   scripts/dump-raw-spans.sh [outfile]
#
# Writes the console exporter output (plus Claude's reply) to outfile, default
# raw-spans.txt in the current directory. Costs one small model call and one
# `echo` tool call.
set -euo pipefail
out="${1:-raw-spans.txt}"

# When launched from inside a Claude Code session (an agent running this script),
# the child claude inherits the parent's session vars and prints no spans at all.
# Clear them, plus the parent's trace context and beta-tracing endpoint.
unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_PID \
  TRACEPARENT TRACESTATE BETA_TRACING_ENDPOINT ENABLE_BETA_TRACING_DETAILED

export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
export OTEL_TRACES_EXPORTER=console
export OTEL_METRICS_EXPORTER=none
export OTEL_LOGS_EXPORTER=none
export OTEL_TRACES_EXPORT_INTERVAL=500
# Same content gates as claude-env.sh, so attributes match what the collector sees.
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_LOG_TOOL_CONTENT=1

# Prompt goes before --allowedTools: that flag is variadic and would swallow it.
claude -p "Run the shell command: echo hello-from-dump-raw-spans. Then reply with one word." \
  --allowedTools "Bash(echo:*)" \
  > "$out" 2>&1 || true

echo "claude version: $(claude --version)"
echo "wrote $out ($(wc -l < "$out") lines)"
