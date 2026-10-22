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
- [ ] Rename the `otlp` exporter to `otlp_grpc` (deprecation warning at startup).
