# claude-collector — notes for future-Claude

## What this project does

An OpenTelemetry Collector configuration that sits between [Claude Code](https://code.claude.com/docs/en/monitoring-usage) and [Honeycomb](https://www.honeycomb.io), shaping Claude Code's telemetry so it appears in Honeycomb's **Agent Timeline**. Claude Code already emits structured spans for interactions, LLM requests, tool calls, and hooks; the collector adds the three `gen_ai.*` attributes that Agent Timeline requires and rewrites span names to the conventions Honeycomb expects.

## How to run it

```bash
# One-time: copy .env.example to .env and fill in HONEYCOMB_API_KEY
cp .env.example .env

# Start the collector (sources .env, runs docker compose up)
./run

# In another terminal: source the Claude Code env vars and run claude
source claude-env.sh
claude
```

The collector listens on `localhost:4327` (gRPC) and `localhost:4328` (HTTP) and exports to Honeycomb. These are non-standard host ports — the OTLP defaults (4317/4318) are left free for other collectors on the machine. Inside the container, the receiver still binds to 4317/4318; `docker-compose.yaml` remaps the host side. The `claude-code-usage` Honeycomb environment is where jessitron tests this.

## File map

| File                          | Purpose                                                                  |
| ----------------------------- | ------------------------------------------------------------------------ |
| `config.yaml`                 | The collector config. Two processors: `transform/mark` and `transform/agent_timeline`. |
| `docker-compose.yaml`         | One-service compose for `otel/opentelemetry-collector-contrib`. Requires `transform` processor → must be contrib, not core. |
| `run`                         | Sources `.env`, preflight-checks `HONEYCOMB_API_KEY`, `docker compose up`. |
| `claude-env.sh`               | Sourceable env vars for `claude` — telemetry on, OTLP endpoint pointed at the collector, content gates set. |
| `.env.example` / `.env`       | `HONEYCOMB_API_KEY` (and optionally `HONEYCOMB_API_ENDPOINT`). `.env` is gitignored. |
| `notes/`                      | Working notes, design rationale, attribute-mapping table, open questions. |

## Pipeline architecture

```
Claude Code  --OTLP-->  collector (transform/mark → transform/agent_timeline → batch)  --OTLP-->  Honeycomb
```

* `transform/mark` runs in **all three pipelines** (traces, metrics, logs) and stamps `collector.claude-collector="washere"` and `collector.claude-collector.version="<n>"` on the resource so we can prove data passed through us.
* `transform/agent_timeline` runs **only on traces**. It does the Agent-Timeline-shaped rewrites of span name and `gen_ai.*` attributes.

## Conventions to keep

### Bump the version on every config change

The `collector.claude-collector.version` attribute lives in `transform/mark` for all three signal types. **Bump it every time you change `config.yaml`** (even trivially). It's how we tell which generation of the config produced which data in Honeycomb. Current value lives at three spots in `config.yaml` — search for `claude-collector.version` and update all three.

### Commit after each conceptual change, tagged "- claude"

Jessitron has this in her global instructions. Every commit message in this repo should end with a `- claude` line so she knows you wrote it. Look at `git log` for the style.

### Don't write to memory

Jessitron uses multiple computers. Notes live in `notes/` so they sync via git. Use the notes dir rather than the memory system.

## OTTL gotchas we already hit

These bit us during the first real run. Don't repeat them.

1. **`attributes["x"] != nil` quietly passes for missing attributes.** This OTTL build (otelcol-contrib 0.147.0) treats access to a missing attribute as something other than `nil` for the purpose of `!=` comparison. Use `IsString(attributes["x"])` (or another `IsXxx` for non-string types) as the presence check instead.
2. **The entries in the `conditions:` array are OR-ed, not AND-ed.** At least in 0.147.0. If you need AND, combine them into a single string with the `and` keyword: `conditions: [ 'span.name == "X" and IsString(attributes["y"])' ]`.
3. **Use `span.name`, not bare `name`, in conditions.** Statements get auto-rewritten by OTTL (you'll see it in the startup log), but conditions don't, and bare `name` can resolve to something other than the span's name.

The full pattern these gotchas push you toward:

```yaml
- context: span
  conditions:
    - 'span.name == "foo" and IsString(attributes["bar"])'
  statements:
    - set(span.name, Concat(["new ", attributes["bar"]], "")) where IsString(attributes["bar"])
```

The defensive `where` on the `set(...)` is belt-and-suspenders against the same gotcha as #1.

## How to tell whether your changes are working

After editing `config.yaml`:

1. Bump `collector.claude-collector.version` in all three places (`transform/mark`).
2. `docker compose restart`.
3. Have jessitron run something in her claude session, then query Honeycomb:

```
dataset: claude-code (in env claude-code-usage)
breakdowns: name, gen_ai.operation.name, gen_ai.agent.name, collector.claude-collector.version
time_range: 3m
filter: collector.claude-collector = "washere"
```

The version column tells you which config generation produced each span.

**Filter out jessitron's claude-code session in this conversation** (which Anthropic's deployment of Claude Code sends *directly* to Honeycomb, bypassing the collector) with `session.id != "<your session id>"`. The session id is in `/Users/jessitron/.claude/projects/-Users-jessitron-code-jessitron-claude-collector/` — the directory name in `tasks/` is your session UUID. Or just filter on the marker attribute being present.

## Current mapping (transform/agent_timeline)

| Source span                                          | Becomes                          | `gen_ai.operation.name` |
| ---------------------------------------------------- | -------------------------------- | ----------------------- |
| `claude_code.interaction`                            | `invoke_agent Claude Code`       | `invoke_agent`          |
| `claude_code.llm_request`                            | `chat {model}`                   | `chat`                  |
| `claude_code.tool` (Task, `subagent_type` set)       | `invoke_agent {subagent_type}`   | `invoke_agent`          |
| `claude_code.tool` (anything else)                   | `execute_tool {tool_name}`       | `execute_tool`          |
| `claude_code.tool.execution` / `.blocked_on_user`    | *(left as-is; just marked + agent.name=Claude Code)* | *(unset)*  |
| `claude_code.hook`                                   | *(left as-is; just marked + agent.name=Claude Code)* | *(unset)*  |

Plus, universally: `gen_ai.conversation.id` ← `session.id`, and `gen_ai.agent.name = "Claude Code"` (overridden to `subagent_type` for the Task-subagent rule).

Attribute aliases (no rename, just enrichment onto the GenAI semconv):

* On `claude_code.llm_request`: `input_tokens` / `output_tokens` / `cache_read_tokens` / `cache_creation_tokens` → `gen_ai.usage.{input,output,cache_read_input,cache_creation_input}_tokens`.
* On `claude_code.tool` (applied before the rename, so covers both `execute_tool` and `invoke_agent {subagent_type}` paths): `tool_input` → `gen_ai.tool.call.arguments`, `new_context` → `gen_ai.tool.call.result`. Requires `OTEL_LOG_TOOL_DETAILS=1` + `OTEL_LOG_TOOL_CONTENT=1`.

Full rationale and open questions: `notes/agent-timeline-attribute-mapping.md`.

## Known limitations / open questions

1. **Tool-call duration includes the permission wait.** We use the parent `claude_code.tool` span because `tool_name` only lives on the parent, not on `.execution`. To get accurate execution time *plus* the tool name, we'd need cross-span attribute propagation (parent → child), which standard OTTL processors don't do.
2. **Sub-agent's own nested spans show `gen_ai.agent.name = "Claude Code"`.** When the Task tool spawns a sub-agent, the sub-agent's `claude_code.llm_request` and `claude_code.tool` spans nest under the parent's `claude_code.tool`. They carry `agent_id` (a UUID) but not the friendly `subagent_type` name. Same propagation problem as #1.
3. **`subagent_type` is gated behind `OTEL_LOG_TOOL_DETAILS=1`.** Without it, Task calls fall through to `execute_tool Task`.
4. **Detailed beta tracing may require allowlisting.** `claude-env.sh` sets `ENABLE_BETA_TRACING_DETAILED=1` and `BETA_TRACING_ENDPOINT`, but per the docs, interactive CLI sessions need the org to be allowlisted for the feature to produce `claude_code.hook` spans. We have not yet verified whether modernity is allowlisted. Check by looking for `claude_code.hook` spans in the dataset.
5. **`OTEL_SERVICE_NAME` is commented out in `claude-env.sh`** so we can observe what Claude Code defaults to. Don't set it unless we decide we need to.
6. **Metrics auto-route in Honeycomb.** The exporter sends no `x-honeycomb-dataset` header for metrics, so Honeycomb chooses. This means metrics land in an auto-named dataset rather than continuing to write to the existing `claude_code_metrics` dataset. If we ever want to keep writing there, add a per-pipeline exporter with the header.
7. **otelcol-contrib 0.147.0 logs a deprecation:** the `"otlp"` exporter alias should be `"otlp_grpc"`. Non-fatal but worth renaming when we touch the exporter.

## Where the spans actually come from in Claude Code

Useful when debugging which env var to flip:

* **`claude_code.interaction`** — emitted per user turn. Root of the trace.
* **`claude_code.llm_request`** — every API call to Anthropic, including retries. Carries `gen_ai.request.model`, `input_tokens`, `output_tokens`, `agent_id` (for subagents).
* **`claude_code.tool`** — parent span around a tool call. Has `tool_name`, and (with `OTEL_LOG_TOOL_DETAILS=1`) `subagent_type` for Task and `skill_name` for Skill.
* **`claude_code.tool.execution`** — the actual run of the tool. Has `duration_ms`, `success`, `error`.
* **`claude_code.tool.blocked_on_user`** — the time waiting for the permission prompt.
* **`claude_code.hook`** — only emitted with `ENABLE_BETA_TRACING_DETAILED=1` *and* org allowlisting.

`OTEL_LOG_USER_PROMPTS=1`, `OTEL_LOG_TOOL_DETAILS=1`, `OTEL_LOG_TOOL_CONTENT=1`, and `OTEL_LOG_RAW_API_BODIES=1` are content gates that add prompts / tool input / tool output / raw API bodies as span attributes or log events.

## Honeycomb Agent Timeline requirements

Every span Honeycomb's Agent Timeline displays needs:

* `gen_ai.conversation.id` — groups spans into one agent conversation.
* `gen_ai.agent.name` — display name.
* `gen_ai.operation.name` — one of: `invoke_agent`, `create_agent`, `chat`, `text_completion`, `generate_content`, `embeddings`, `execute_tool`.

And the span name must follow the pattern matching the operation: `invoke_agent {name}`, `chat {model}`, `execute_tool {tool_name}`.

Recommended extras (Claude Code already sends most): `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.model`, `gen_ai.response.finish_reasons`, `gen_ai.tool.name`, `gen_ai.tool.call.id`.

Source: <https://docs.honeycomb.io/send-data/agents>.

## References

* Claude Code monitoring docs: <https://code.claude.com/docs/en/monitoring-usage>
* Honeycomb Agent Timeline: <https://docs.honeycomb.io/send-data/agents>
* OTel Collector transform processor: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor>
* OTTL language: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/pkg/ottl>
