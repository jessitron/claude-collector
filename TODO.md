# TODO

Task tracking for this repo lives here again. (It was in Linear, team `JES`, from
2026-05-28 to 2026-10-22; old issue numbers like JES-158 in commits and notes refer
to that. Open Linear issues were not migrated.)

- [ ] Find out which cache-token names Honeycomb's Agent Timeline reads:
      `gen_ai.usage.cache_read.input_tokens` (current semconv) or
      `gen_ai.usage.cache_read_input_tokens` (Honeycomb's old Claude Code example).
      We emit both since v0.8; drop the one it doesn't use.
- [ ] A subagent's own tool spans still say `gen_ai.agent.name = "Claude Code"`.
      They carry `agent_id` but nothing that names the agent. Options: a generic
      "subagent" label when `agent_id` is set, or cross-span propagation from the
      subagent's `chat` spans (same agent_id). See notes/agent-timeline-attribute-mapping.md.
- [ ] A subagent's spans hang under the Agent tool's `claude_code.tool.execution` child,
      not under `invoke_agent {type}` directly. Check whether Agent Timeline shows them
      under the subagent; if not, decide what to do (we can't reparent without cross-span info).
- [ ] Anthropic's server-side spans (`claude-api` dataset) only join traces for API-key
      sessions, not claude.ai logins. Ask Anthropic whether that's expected.
- [ ] Rename the `otlp` exporter to `otlp_grpc` (deprecation warning at startup).
- [ ] Messages on `chat` spans: detailed beta tracing (on again in claude-env.sh) puts
      `new_context` (plain text, `[TOOL RESULT: id]` markers), `response.model_output`,
      `system_prompt_preview`, `system_reminders` on `claude_code.llm_request` -- confirmed
      for `claude -p` on 2.1.308. Still to do: (1) check an interactive session gets them
      (needs org allowlisting); (2) map to `gen_ai.input.messages` / `gen_ai.output.messages`
      so Agent Timeline shows them.
