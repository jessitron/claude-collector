#!/usr/bin/env bash
# Validates config.yaml using the same otelcol-contrib image we run in compose.
# Keep the image tag here in sync with docker-compose.yaml.
# Reports OTTL or YAML errors without bringing up the receiver.
set -euo pipefail
cd "$(dirname "$0")/.."

# Need API key + endpoint env vars for the validator to expand env: references.
# Fall back to placeholders so validation works even if .env is missing.
HONEYCOMB_API_KEY="${HONEYCOMB_API_KEY:-placeholder}"
HONEYCOMB_API_ENDPOINT="${HONEYCOMB_API_ENDPOINT:-https://api.honeycomb.io:443}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-placeholder-bucket}"
S3_PREFIX="${S3_PREFIX:-claude-code}"

docker run --rm \
  -v "$PWD/config.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  -e HONEYCOMB_API_KEY="$HONEYCOMB_API_KEY" \
  -e HONEYCOMB_API_ENDPOINT="$HONEYCOMB_API_ENDPOINT" \
  -e AWS_REGION="$AWS_REGION" -e S3_BUCKET="$S3_BUCKET" -e S3_PREFIX="$S3_PREFIX" \
  otel/opentelemetry-collector-contrib:0.163.1 \
  validate --config=/etc/otelcol-contrib/config.yaml
