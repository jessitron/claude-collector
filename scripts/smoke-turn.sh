#!/usr/bin/env bash
# Send one real Claude Code turn through the running collector, touching every
# rule in transform/agent_timeline: a Bash call, a Read, and an Explore subagent.
# Then look it up in Honeycomb (dataset claude-code) by session.id, printed below.
#
#   scripts/smoke-turn.sh
#
# Costs a few small model calls.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../claude-env.sh
source ./claude-env.sh >/dev/null
# Don't nest under the trace of whatever Claude session launched us.
unset TRACEPARENT TRACESTATE

session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
claude -p --session-id "$session_id" \
  "Smoke test, keep it short. 1) Run: echo smoke-turn. 2) Read the first lines of README.md. 3) Use the Agent tool with subagent_type Explore to find which file defines transform/mark, and have it answer in one line. Then reply with one sentence." \
  --allowedTools "Bash(echo:*)" "Read" "Agent" "Glob" "Grep"

echo
echo "session.id = $session_id"
