# claude-collector — notes for future-Claude

## What this project does

An OpenTelemetry Collector configuration that sits between [Claude Code](https://code.claude.com/docs/en/monitoring-usage) and [Honeycomb](https://www.honeycomb.io), shaping Claude Code's telemetry so it appears in Honeycomb's **Agent Timeline**. It also archives the shaped traces to S3 so they can become replay shapes ("menu items") in takeout-telemetry; see `notes/takeout-telemetry-supplier.md`. Claude Code already emits structured spans for interactions, LLM requests, tool calls, and hooks; the collector adds the three `gen_ai.*` attributes that Agent Timeline requires and rewrites span names to the conventions Honeycomb expects.

## Task tracking — use Linear, not a file

Work on this repo is tracked in the private **jessitron** Linear team (key `JES`),
in the **claude-collector** project:
<https://linear.app/honeycombio/project/claude-collector-a55decd260c1>

Use the Linear MCP (`list_issues` / `save_issue` with `project: "claude-collector"`,
`team: "jessitron"`). `TODO.md` is retired — it's just a pointer now. When jessitron
mentions something to track, create or update a JES issue rather than writing it to a
file. This is part of her personal Linear-backed task system (set up 2026-05-28).

**Capturing tasks — `create-task` skill is currently unavailable** (removed
2026-05-29; pending reinstall via a new plugin — the old `.claude/skills/create-task/`
symlink and the whole `.claude/skills/` dir are gone). Until it's back, capture tasks by
using the **Linear MCP directly** (`save_issue` with `project: "claude-collector"`,
`team: "jessitron"`) — search first (`list_issues`) so you link to a related issue rather
than duplicating. When you spot incidental work mid-task — cleanup, something confusing, a
case not covered, a follow-up — **fork a general-purpose subagent to file the Linear issue**
and keep working; don't derail to do it yourself. Once the plugin is installed, restore the
fork-a-subagent-that-runs-`create-task` flow here.

## How to run it

```bash
# One-time: copy .env.example to .env and fill in HONEYCOMB_API_KEY
cp .env.example .env
# One-time: create the S3 IAM user and write its key into .env
scripts/create-s3-supplier-user.sh

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
| `docker-compose.yaml`         | One-service compose for `otel/opentelemetry-collector-contrib`, pinned to a version (keep in sync with `scripts/validate-config.sh`). Requires `transform` + `awss3` → must be contrib, not core. |
| `run`                         | Sources `.env`, preflight-checks `HONEYCOMB_API_KEY`, `docker compose up`. |
| `claude-env.sh`               | Sourceable env vars for `claude` — telemetry on, OTLP endpoint pointed at the collector, content gates set. |
| `.env.example` / `.env`       | `HONEYCOMB_API_KEY` (optionally `HONEYCOMB_API_ENDPOINT`), plus `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`/`S3_BUCKET`/`S3_PREFIX` for the S3 archive. `.env` is gitignored. |
| `scripts/create-s3-supplier-user.sh` | Creates IAM user `takeout-telemetry-supplier` in really-devrel-sandbox (PutObject on one bucket prefix only) and writes its key + bucket vars into `.env`. Ignores `$AWS_PROFILE` on purpose. |
| `scripts/send-test-span.sh` / `send-test-metric.sh` | POST one synthetic span / gauge point to the collector so you can check exporters (especially S3) without running Claude Code. |
| `scripts/validate-config.sh`  | Validate `config.yaml` against the same otelcol-contrib image we run, without bringing the receiver up. Catches YAML parse errors and OTTL errors. Run before `docker compose restart` on non-trivial edits — saves a "container failed to start, dig through compose logs" round trip. |
| `notes/`                      | Working notes, design rationale, attribute-mapping table, open questions. |

## Pipeline architecture

```
Claude Code  --OTLP-->  collector (transform/mark → transform/agent_timeline → batch)  --OTLP-->  Honeycomb
                                                                                      \--awss3-->  s3://devrel-takeout-telemetry-dev-6a8ca705/claude-code/  (traces, logs, metrics)
```

* `transform/mark` runs in **all three pipelines** (traces, metrics, logs) and stamps `collector.claude-collector="washere"` and `collector.claude-collector.version="<n>"` on the resource so we can prove data passed through us.
* `awss3/takeout` runs in **all three pipelines** too, so a takeout shape can include logs and metrics (`packer pack --signals traces,logs,metrics`).
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
2. Run `scripts/validate-config.sh` — catches YAML parse errors and OTTL errors against the same otelcol-contrib image we run. Exit code 0 = good. Skipping this and going straight to `docker compose restart` leaves you debugging from `docker compose logs` after the container has already died, which is slower.
3. `docker compose restart`.
4. Have jessitron run something in her claude session, then query Honeycomb:

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
4. **`BETA_TRACING_ENDPOINT` is OTLP HTTP, not gRPC.** Claude Code POSTs to `$BETA_TRACING_ENDPOINT/v1/traces` and `/v1/logs` -- HTTP-only paths. Point it at the collector's HTTP port (`4328`), not gRPC (`4327`). If pointed at gRPC, the requests silently disappear and the `parent_of` span link on every `chat` span looks like a dead end (the target trace is in valid OTel format, you just never receive it). Reference: github.com/honeycombio/autobots/blob/main/otelcol/collector.yaml. Open question: does the Detailed Beta receiver also need to authenticate or is plain OTLP enough? Verify once we have data flowing.
5. **`OTEL_SERVICE_NAME` is commented out in `claude-env.sh`** so we can observe what Claude Code defaults to. Don't set it unless we decide we need to.
6. **Metrics auto-route in Honeycomb.** The exporter sends no `x-honeycomb-dataset` header for metrics, so Honeycomb chooses. This means metrics land in an auto-named dataset rather than continuing to write to the existing `claude_code_metrics` dataset. If we ever want to keep writing there, add a per-pipeline exporter with the header.
7. **otelcol-contrib logs a deprecation:** the `"otlp"` exporter alias should be `"otlp_grpc"`. Non-fatal but worth renaming when we touch the exporter.
8. **AWS CLI by hand: always `--profile really-devrel-sandbox`.** jessitron's shell exports `AWS_PROFILE=sandbox`, a different account. See the gotcha in `notes/takeout-telemetry-supplier.md`.

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
