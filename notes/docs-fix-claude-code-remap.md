# Fix the Claude Code remapping example in "Instrumenting AI Agents"

Instructions for an agent working in the Honeycomb docs repo.

## The page

<https://docs.honeycomb.io/send-data/use-cases/agents>, in the section **"Remapping
existing telemetry."** Find the page's source file in this repo. It has prose about
Claude Code plus an OpenTelemetry Collector `transform` processor config that remaps
Claude Code's spans for Agent Timeline.

## What's wrong

The page says Claude Code's output doesn't follow the GenAI semantic conventions, so
everything has to be remapped. That was true in 2025. It isn't anymore. As of Claude
Code 2.1.308 (checked 2026-10-22, by dumping raw spans before any collector touched them),
Claude Code sets these itself:

| Span | Native GenAI attributes |
| --- | --- |
| every span | `gen_ai.conversation.id` (same value as `session.id`), `gen_ai.provider.name = "anthropic"` |
| `claude_code.interaction` | `gen_ai.operation.name = "invoke_agent"` |
| `claude_code.llm_request` | `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons` (but **no** `gen_ai.operation.name` and **no** `gen_ai.usage.*`) |
| `claude_code.tool` | `gen_ai.operation.name = "execute_tool"`, `gen_ai.tool.name`, `gen_ai.tool.call.id` |

Claude Code still does **not** set:

- `gen_ai.agent.name`, on any span
- semconv span names (`invoke_agent …`, `chat …`, `execute_tool …`); spans are still named `claude_code.*`
- `gen_ai.operation.name = "chat"` on `claude_code.llm_request`
- `gen_ai.usage.*` token counts (it has bare `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`)
- `gen_ai.tool.call.arguments` / `gen_ai.tool.call.result`

So remapping is still needed, just less of it.

## Specific fixes

1. **Prose.** Change the "Claude Code doesn't follow the GenAI conventions" framing to
   something like: "Claude Code sets many GenAI attributes itself, but not agent names,
   semconv span names, or token usage. Use a Collector `transform` processor to fill
   those in." Don't commit to a version number unless the page already does that elsewhere.

2. **Drop the `session.id` → `gen_ai.conversation.id` mapping.** Claude Code sets it.

3. **Fix the claim that `gen_ai.tool.call.id` has no Claude Code equivalent.** Claude Code
   sets it natively on `claude_code.tool`. Remove that note.

4. **Check every condition and guard in the YAML for this trap (the important one).**
   If any statement is guarded on a `gen_ai.*` attribute being *absent*, such as
   `where attributes["gen_ai.operation.name"] == nil` (often used to skip spans an earlier
   rule already handled), it now silently fails. Claude Code sets
   `gen_ai.operation.name = "execute_tool"` on every tool span, so the guard is false and
   *no tool span gets renamed*. We hit exactly this: 100% of tool spans went unrenamed.
   Fix: match on `span.name == "claude_code.tool"` instead. A rule that has already renamed
   a span takes it out of reach of later rules, because statements run in order per span.

5. **The subagent-spawning tool is `Agent` now, not `Task`.** If the example matches
   `tool_name == "Task"`, match on `IsString(attributes["subagent_type"])` instead. Only the
   spawning tool carries it, and it survives renames. It needs `OTEL_LOG_TOOL_DETAILS=1`.
   The span should become `invoke_agent {subagent_type}`, with `gen_ai.agent.name` and
   `gen_ai.operation.name = "invoke_agent"` set (overriding the native `execute_tool`).

6. **Token usage.** Semconv's `gen_ai.usage.input_tokens` *includes* cache reads and writes.
   Claude Code's bare `input_tokens` doesn't (it's often 2). So set
   `gen_ai.usage.input_tokens = input_tokens + cache_read_tokens + cache_creation_tokens`.
   Use the dotted semconv names for cache counts: `gen_ai.usage.cache_read.input_tokens`
   and `gen_ai.usage.cache_creation.input_tokens`. If the example uses underscore names
   like `gen_ai.usage.cache_read_input_tokens`, those aren't semconv; replace them.

7. **Tool I/O (if the example maps it).**
   - `gen_ai.tool.call.arguments` should be a JSON object string. With detailed beta tracing,
     `tool_input` is `"[TOOL INPUT: <tool>]\n{...json}"`, so that first line has to be stripped.
     Without it, the only inputs are `full_command` / `file_path` (from `OTEL_LOG_TOOL_DETAILS=1`),
     which are plain strings, not JSON. If the example copies one straight into
     `gen_ai.tool.call.arguments`, note that it isn't a JSON object. A full fix needs hand
     escaping because OTTL can't encode JSON. Simplifying is fine; just don't claim
     the result is semconv-shaped if it isn't.
   - Tool output is **not** a span attribute. With `OTEL_LOG_TOOL_CONTENT=1` it comes as a
     `tool.output` span event on the tool span, in the `output` (Bash/MCP/web),
     `content` (Read/Write) or `diff` (Edit) attribute. Copying it up takes a
     `context: spanevent` rule that writes `span.attributes["gen_ai.tool.call.result"]`.

8. **OTTL gotchas to respect in the example** (seen on otelcol-contrib 0.147.0):
   - Use `IsString(attributes["x"])` as a presence check, not `attributes["x"] != nil`.
   - Entries in a `conditions:` list are OR-ed. For AND, write one string with `and`.
   - Write `span.name` in conditions, not bare `name`.

## A working reference

<https://github.com/jessitron/claude-collector/blob/main/config.yaml>, processor
`transform/agent_timeline`. It's tested against current Claude Code and commented rule by rule.
Feel free to borrow from it, but the docs example should stay short. A reader needs:
the default `gen_ai.agent.name`, the three renames, `chat` on llm_request, and the token
sums. Tool I/O and subagent naming of chat spans (`query_source_safe`) can be "optional
extras" or links to the reference.

## Verify before you finish

- Run the YAML through `otelcol-contrib validate --config=<file>` (any recent contrib image),
  wrapped in a minimal receivers/exporters/pipeline so it loads.
- Re-read the page once to make sure the prose and the YAML agree, and that no sentence
  still says Claude Code lacks GenAI conventions entirely.
