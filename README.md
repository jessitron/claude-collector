# claude-collector

An OpenTelemetry Collector configuration for receiving telemetry from [Claude Code](https://code.claude.com/docs/en/monitoring-usage) and forwarding it to [Honeycomb](https://www.honeycomb.io), shaped so it appears in Honeycomb's **Agentic Timeline**.

## What it does

Claude Code can emit OTel telemetry: metrics, log/event records, and (in beta) traces. This collector:

1. Receives that telemetry over OTLP.
2. Adds and renames attributes so spans match the conventions Honeycomb's Agentic Timeline expects.
3. Exports to Honeycomb, and archives traces, logs, and metrics to S3 for [takeout-telemetry](https://github.com/honeycombio/takeout-telemetry) replay shapes (see `notes/takeout-telemetry-supplier.md`).

## Running the collector

```bash
cp .env.example .env            # then fill in HONEYCOMB_API_KEY
scripts/create-s3-supplier-user.sh   # one-time: IAM user for the S3 archive, writes its key into .env
./run                           # sources .env, docker compose up
```

`HONEYCOMB_API_ENDPOINT` defaults to US ingest; set it to `api.eu1.honeycomb.io:443` in `.env` if you're on EU. The S3 variables are required by `docker-compose.yaml`; if you don't want the archive, remove `awss3/takeout` from the pipelines in `config.yaml` and the `AWS_*`/`S3_*` lines from compose.

The collector listens on non-standard host ports (the OTLP defaults of 4317/4318 are left free for other collectors on your machine):

- gRPC: `localhost:4327`
- HTTP: `localhost:4328`

If you'd rather run the binary directly, install [`otelcol-contrib`](https://github.com/open-telemetry/opentelemetry-collector-releases) (the `transform` processor and `awss3` exporter are in contrib, not core) and run `otelcol-contrib --config config.yaml` with the same env vars set.

## Pointing Claude Code at the collector

Set these environment variables before running `claude`. Full reference: <https://code.claude.com/docs/en/monitoring-usage#quick-start>.

```bash
# Turn on telemetry
export CLAUDE_CODE_ENABLE_TELEMETRY=1

# Turn on traces (beta) — required for the Agentic Timeline
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1

# Choose what to export
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp

# Send to the local collector
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4327

# Optional: shorter intervals while you're verifying the setup
export OTEL_METRIC_EXPORT_INTERVAL=10000  # 10s (default 60s)
export OTEL_LOGS_EXPORT_INTERVAL=5000     # 5s  (default 5s)

claude
```

By default, Claude Code redacts prompt text, tool inputs, and tool outputs. To include them in spans:

```bash
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_LOG_TOOL_CONTENT=1
```

`OTEL_LOG_TOOL_DETAILS=1` is also what makes `subagent_type` available on Agent-tool spans (the subagent-spawning tool, formerly called Task), which is what the collector uses to label sub-agent invocations in the timeline.

### What you'll see

Each user turn produces a `claude_code.interaction` root span with these children:

```
claude_code.interaction
├── claude_code.llm_request
├── claude_code.hook
└── claude_code.tool
    ├── claude_code.tool.blocked_on_user
    └── claude_code.tool.execution
```

LLM-request spans already carry the OTel GenAI conventions (`gen_ai.system=anthropic`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`), which is what Honeycomb's Agentic Timeline keys off of.

## How the timeline mapping works

The collector applies these transforms to traces (see `config.yaml`):

| Source span                | Becomes                       | `gen_ai.operation.name` |
| -------------------------- | ----------------------------- | ----------------------- |
| `claude_code.interaction`  | `invoke_agent Claude Code`    | `invoke_agent`          |
| `claude_code.llm_request`  | `chat {model}`                | `chat`                  |
| `claude_code.tool` (w/ `subagent_type`) | `invoke_agent {subagent_type}` | `invoke_agent` |
| `claude_code.tool` (other) | `execute_tool {tool_name}`    | `execute_tool`          |

Every span also gets `gen_ai.agent.name`: `"Claude Code"` by default, `subagent_type` on a subagent invocation, and the subagent's type (from `query_source_safe`, e.g. `Explore`) on a subagent's own `chat` spans. Claude Code already sets `gen_ai.conversation.id` itself. On `chat` spans, `gen_ai.usage.input_tokens` is input plus cache reads plus cache writes, per the GenAI semconv. On tool spans, `gen_ai.tool.call.arguments` and `.result` come from the command/file path and the `tool.output` span event.

### Known limitations

- The timeline span for a tool call is the parent `claude_code.tool`, whose duration includes the time spent waiting for permission. The more accurate `claude_code.tool.execution` child doesn't carry `tool_name`, so we can't easily synthesize `execute_tool {tool_name}` on it without cross-span propagation.
- A sub-agent's own *tool* spans still say `gen_ai.agent.name = "Claude Code"`: they carry `agent_id` but not `query_source_safe`, so there's nothing on the span that names the agent.

### Gotcha: `BETA_TRACING_ENDPOINT` is HTTP, not gRPC

Claude Code's `ENABLE_BETA_TRACING_DETAILED=1` exports through a separate `BETA_TRACING_ENDPOINT`, and it POSTs to `$BETA_TRACING_ENDPOINT/v1/traces` and `/v1/logs` — i.e. OTLP **HTTP** paths. Point it at the HTTP receiver port (`4328`), not the gRPC one (`4327`); otherwise the requests vanish into a gRPC listener.

(The `parent_of` span link on every `chat` span is unrelated: it records the Anthropic API's `traceresponse` header and points at an Anthropic-internal trace that is never exported, so it's always a dead link. The collector drops it. Anthropic's server-side spans, where its telemetry export is set up, show up instead as children of the `chat` span in the same trace. That only happens for API-key sessions, not claude.ai logins.)

## Testing without Claude Code

`scripts/send-test-span.sh` and `scripts/send-test-metric.sh` POST one synthetic span / metric to the collector. `scripts/validate-config.sh` checks `config.yaml` against the pinned collector image before you restart.

With Claude Code: `scripts/smoke-turn.sh` sends one real turn (a Bash call, a Read, an Explore subagent) through the collector and prints its `session.id` to look up. `scripts/dump-raw-spans.sh` shows spans as Claude Code emits them, before any transform. Run it after a Claude Code upgrade to see which transforms are no longer needed.

See `notes/` for the full mapping rationale and a list of open questions.
