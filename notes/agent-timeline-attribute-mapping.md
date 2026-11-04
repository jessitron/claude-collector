# Mapping Claude Code spans → Honeycomb Agent Timeline

## What Honeycomb's Agent Timeline requires

Every span needs these three attributes:

| Attribute | Notes |
|---|---|
| `gen_ai.conversation.id` | Groups all spans within one agent conversation. |
| `gen_ai.agent.name` | Display name. Falls back to "Unknown" if missing. Sub-agents should use their own distinct names. |
| `gen_ai.operation.name` | Must be one of: `invoke_agent`, `create_agent`, `chat`, `text_completion`, `generate_content`, `embeddings`, `execute_tool`. |

Span **name** must also follow a pattern:

| Span type | `gen_ai.operation.name` | Span name pattern |
|---|---|---|
| Agent | `invoke_agent` or `create_agent` | `invoke_agent {agent_name}` |
| LLM call | `chat`, `text_completion`, ... | `chat {model}` |
| Tool call | `execute_tool` | `execute_tool {tool_name}` |

Recommended extras (Claude Code already supplies most of these): `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.tool.name`, `gen_ai.tool.call.id`.

## What Claude Code sent when we started

Verified against trace `51e48a330e17ce8f7e19429d248256eb` in `claude-code-usage`:

- `service.name = claude-code`
- Span hierarchy (no rewriting):
  ```
  claude_code.interaction
  ├── claude_code.llm_request
  ├── claude_code.hook
  └── claude_code.tool
      ├── claude_code.tool.blocked_on_user
      └── claude_code.tool.execution
  ```
- Already present (good): `session.id`, `gen_ai.system`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`, `model`, `input_tokens`, `total_tokens`, `tool_name`, `tool_use_id`, `agent_id`, `parent_agent_id`, `interaction.sequence`, `span.type`.
- Missing for the timeline: `gen_ai.conversation.id`, `gen_ai.agent.name`, `gen_ai.operation.name`, and the renamed span names.

## What Claude Code sends natively now (2.1.308, checked 2026-10-22; unchanged on 2.1.318, 2026-11-04)

Seen with `scripts/dump-raw-spans.sh`, before any transform:

- Every span: `gen_ai.conversation.id` (= `session.id`), `gen_ai.provider.name = anthropic`, `span.type`.
- `claude_code.interaction`: `gen_ai.operation.name = invoke_agent`.
- `claude_code.llm_request`: `gen_ai.system`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`, `query_source_safe`. **No** `gen_ai.operation.name`, **no** `gen_ai.usage.*` (the Claude Code docs say so explicitly).
- `claude_code.tool`: `gen_ai.operation.name = execute_tool` (even for the Agent tool), `gen_ai.tool.name`, `gen_ai.tool.call.id`. Tool output arrives as a `tool.output` **span event**, not an attribute.
- Nowhere: `gen_ai.agent.name`, semconv span names.

## Collector transformations (v0.14, see `config.yaml`)

All applied as `transform` processor statements keyed on `span.name` (which the doc says always equals `span.type`).

Unconditional on every span:

- `gen_ai.agent.name` ← `"Claude Code"` (default; overridden below for sub-agents)

Per span type:

| Source                                       | Set `gen_ai.operation.name` | Rewrite span name to            | Notes                                                                 |
|----------------------------------------------|-----------------------------|---------------------------------|-----------------------------------------------------------------------|
| `claude_code.interaction`                    | *(native)*                  | `invoke_agent Claude Code`      | Wraps `user_prompt` into `gen_ai.input.messages`.                     |
| `claude_code.llm_request`                    | `chat`                      | `chat {model}`                  | If `query_source_safe` is `agent.builtin.<type>`, `gen_ai.agent.name = <type>`; if `agent.custom`, `"custom agent"`. Span links dropped (v0.10): the only one is a dead `parent_of` link to an Anthropic-internal trace. |
| `claude_code.tool` (`subagent_type` set)     | `invoke_agent` (overrides native `execute_tool`) | `invoke_agent {subagent_type}`  | Also sets `gen_ai.agent.name = subagent_type`. Needs `OTEL_LOG_TOOL_DETAILS=1`. Matched on `subagent_type`, not tool name: the tool was `Task`, now `Agent`. |
| `claude_code.tool` (other)                   | *(native)*                  | `execute_tool {tool_name}`      | Falls back to `execute_tool unknown` if `tool_name` is absent. Condition is `span.name` only; see JES-158. |
| `claude_code.tool.execution`                 | *(left as-is)*              | *(left as-is)*                  | Sits inside the timeline node above as nested detail.                 |
| `claude_code.tool.blocked_on_user`           | *(left as-is)*              | *(left as-is)*                  |                                                                       |
| `claude_code.hook`                           | *(left as-is)*              | *(left as-is)*                  |                                                                       |

### Attribute aliases (no span rename, but enrich existing spans)

On `claude_code.llm_request` (the future `chat {model}` span):

| Source attribute | Aliased onto |
|---|---|
| `input_tokens + cache_read_tokens + cache_creation_tokens` | `gen_ai.usage.input_tokens` (semconv counts cache reads and writes as input; bare `input_tokens` is usually 2) |
| `output_tokens` | `gen_ai.usage.output_tokens` |
| `cache_read_tokens` | `gen_ai.usage.cache_read.input_tokens` |
| `cache_creation_tokens` | `gen_ai.usage.cache_creation.input_tokens` |

The cache counts use the dotted semconv names only, matching Anthropic's own `claude-api` telemetry. Until v0.11 we also wrote underscore copies (`cache_read_input_tokens`, from Honeycomb's older Claude Code example); dropped to stick with semconv. (Semconv 1.41.0 still says `cache_creation`; the newest drafts may say `cache_write`. Watch for that.)

On `claude_code.tool` (covers both the `execute_tool` and `invoke_agent {subagent_type}` rewrites):

| Source | Aliased onto | Requires |
|---|---|---|
| `tool_input` (minus its `[TOOL INPUT: x]` line), else `{"command": full_command}`, else `{"file_path": file_path}` | `gen_ai.tool.call.arguments` (JSON object string) | `OTEL_LOG_TOOL_DETAILS=1`; `tool_input` also needs detailed beta tracing |
| `tool.output` span event's `output`, else `content`, else `diff` | `gen_ai.tool.call.result` | `OTEL_LOG_TOOL_CONTENT=1` |

The result rule runs in `spanevent` context and writes `span.attributes[...]`, which OTTL allows. Before v0.8 we aliased `tool_input`/`new_context`, but both are detailed-beta-only, so with detailed beta off those statements never fired.

Aggregate `gen_ai.usage.*` on the parent `invoke_agent` span is absent (per-call totals live on the `chat` children only); consumers compose at query time.

## Known limitations

1. **Tool duration includes permission wait.** We use the parent `claude_code.tool` because `tool_name` lives there and not on `claude_code.tool.execution`. That makes the timeline bar wider than the actual execution. Fix would need cross-span attribute propagation.
2. **Sub-agent's own tool spans are labeled "Claude Code".** Its `chat` spans are now named from `query_source_safe`, but its `claude_code.tool` spans carry only `agent_id` (a UUID), not `query_source_safe` or `subagent_type`. Same propagation problem.
3. **Sub-agent attribution on the spawn span requires `OTEL_LOG_TOOL_DETAILS=1`.** Without it, `subagent_type` is absent and subagent spawns show as `execute_tool Agent`.

## Possible v2 directions

- **OTTL `cache` + `groupbytrace`**: stash parent attributes by `span_id` and look them up by `parent_span_id` on children. Untested, possibly fragile.
- **Custom Go processor**: small contrib that does parent-attribute propagation for a configured list of attrs.
- **File feedback to the Claude Code team** about the attribute placement (tool_name on .execution, subagent_type and skill_name un-gated and on subagent spans).
