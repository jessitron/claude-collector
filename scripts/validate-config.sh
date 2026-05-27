#!/usr/bin/env bash
# Validates config.yaml using the same otelcol-contrib image we run in compose.
# Reports OTTL or YAML errors without bringing up the receiver.
set -euo pipefail
cd "$(dirname "$0")/.."

# Need API key + endpoint env vars for the validator to expand env: references.
# Fall back to placeholders so validation works even if .env is missing.
HONEYCOMB_API_KEY="${HONEYCOMB_API_KEY:-placeholder}"
HONEYCOMB_API_ENDPOINT="${HONEYCOMB_API_ENDPOINT:-https://api.honeycomb.io:443}"

docker run --rm \
  -v "$PWD/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  -e HONEYCOMB_API_KEY="$HONEYCOMB_API_KEY" \
  -e HONEYCOMB_API_ENDPOINT="$HONEYCOMB_API_ENDPOINT" \
  otel/opentelemetry-collector-contrib:0.147.0 \
  validate --config=/etc/otelcol-contrib/config.yaml
