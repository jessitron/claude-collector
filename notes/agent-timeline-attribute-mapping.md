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

## What Claude Code actually sends today

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

## v1 collector transformations (see `config.yaml`)

All applied as `transform` processor statements keyed on `span.name` (which the doc says always equals `span.type`).

Unconditional on every span:

- `gen_ai.conversation.id` ← `session.id`
- `gen_ai.agent.name` ← `"Claude Code"` (default; overridden below for sub-agents)

Per span type:

| Source                                       | Set `gen_ai.operation.name` | Rewrite span name to            | Notes                                                                 |
|----------------------------------------------|-----------------------------|---------------------------------|-----------------------------------------------------------------------|
| `claude_code.interaction`                    | `invoke_agent`              | `invoke_agent Claude Code`      |                                                                       |
| `claude_code.llm_request`                    | `chat`                      | `chat {model}`                  |                                                                       |
| `claude_code.tool` (`subagent_type` set)     | `invoke_agent`              | `invoke_agent {subagent_type}`  | Also sets `gen_ai.agent.name = subagent_type`. Needs `OTEL_LOG_TOOL_DETAILS=1`. Matched on `subagent_type`, not tool name: the tool was `Task`, now `Agent`. |
| `claude_code.tool` (other)                   | `execute_tool`              | `execute_tool {tool_name}`      | Also copies `tool_name` → `gen_ai.tool.name`. Falls back to `execute_tool unknown` if `tool_name` is absent. Condition is `span.name` only; see JES-158. |
| `claude_code.tool.execution`                 | *(left as-is)*              | *(left as-is)*                  | Sits inside the timeline node above as nested detail.                 |
| `claude_code.tool.blocked_on_user`           | *(left as-is)*              | *(left as-is)*                  |                                                                       |
| `claude_code.hook`                           | *(left as-is)*              | *(left as-is)*                  |                                                                       |

### Attribute aliases (no span rename, but enrich existing spans)

On `claude_code.llm_request` (the future `chat {model}` span):

| Source attribute | Aliased onto |
|---|---|
| `input_tokens` | `gen_ai.usage.input_tokens` |
| `output_tokens` | `gen_ai.usage.output_tokens` |
| `cache_read_tokens` | `gen_ai.usage.cache_read_input_tokens` |
| `cache_creation_tokens` | `gen_ai.usage.cache_creation_input_tokens` |

On `claude_code.tool` (covers both the `execute_tool` and `invoke_agent {subagent_type}` rewrites — applied before the rename):

| Source attribute | Aliased onto | Requires |
|---|---|---|
| `tool_input` | `gen_ai.tool.call.arguments` | `OTEL_LOG_TOOL_DETAILS=1` + `OTEL_LOG_TOOL_CONTENT=1` |
| `new_context` | `gen_ai.tool.call.result` | same |

`gen_ai.tool.call.id` is now emitted natively by Claude Code on `claude_code.tool` spans (observed 2026-10-21), along with `gen_ai.operation.name="execute_tool"`, `gen_ai.tool.name` and `gen_ai.provider.name`. Our `execute_tool` rule overwrites the first two with the same values, which is harmless. Aggregate `gen_ai.usage.*` on the parent `invoke_agent` span is also absent (per-call totals live on the `chat` children only); consumers compose at query time.

## Known v1 limitations

1. **Tool duration includes permission wait.** We use the parent `claude_code.tool` because `tool_name` lives there and not on `claude_code.tool.execution`. That makes the timeline bar wider than the actual execution. Fix would need cross-span attribute propagation.
2. **Sub-agent's own spans are labeled "Claude Code".** The Agent tool (formerly Task) spawns a sub-agent whose `claude_code.llm_request` / `claude_code.tool` spans nest under the parent's `claude_code.tool` span. They carry `agent_id` (UUID) but not the friendly `subagent_type`. Same propagation problem.
3. **Sub-agent attribution requires `OTEL_LOG_TOOL_DETAILS=1`.** Without it, `subagent_type` is absent and subagent spawns show as `execute_tool Agent`.

## Possible v2 directions

- **OTTL `cache` + `groupbytrace`**: stash parent attributes by `span_id` and look them up by `parent_span_id` on children. Untested, possibly fragile.
- **Custom Go processor**: small contrib that does parent-attribute propagation for a configured list of attrs.
- **File feedback to the Claude Code team** about the attribute placement (tool_name on .execution, subagent_type and skill_name un-gated and on subagent spans).
