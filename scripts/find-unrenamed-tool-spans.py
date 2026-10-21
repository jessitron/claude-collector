#!/usr/bin/env python3 -I
"""Scan OTLP-JSON trace files for spans still named exactly `claude_code.tool`
and report which attributes they carry, per collector config version.

Usage: python3 -I find_unrenamed_tool_spans.py <dir-or-file> [...]
"""
import json
import os
import sys
from collections import Counter, defaultdict


def attr_map(attrs):
    out = {}
    for a in attrs or []:
        v = a.get("value", {})
        # unwrap the OTLP AnyValue
        if "stringValue" in v:
            out[a["key"]] = v["stringValue"]
        elif "intValue" in v:
            out[a["key"]] = int(v["intValue"])
        elif "boolValue" in v:
            out[a["key"]] = v["boolValue"]
        elif "doubleValue" in v:
            out[a["key"]] = v["doubleValue"]
        else:
            out[a["key"]] = v
    return out


def iter_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    if "traces_" in f:
                        yield os.path.join(root, f)
        else:
            yield p


def main(paths):
    by_version_name = Counter()           # (version, span name) -> count
    unrenamed = []                        # details for claude_code.tool spans
    tool_span_by_version = Counter()      # version -> all tool-ish spans
    for path in iter_files(paths):
        with open(path) as fh:
            try:
                doc = json.load(fh)
            except json.JSONDecodeError as e:
                print(f"skip {path}: {e}", file=sys.stderr)
                continue
        for rs in doc.get("resourceSpans", []):
            res = attr_map(rs.get("resource", {}).get("attributes"))
            version = res.get("collector.claude-collector.version", "?")
            for ss in rs.get("scopeSpans", []):
                for span in ss.get("spans", []):
                    name = span.get("name")
                    by_version_name[(version, name)] += 1
                    if name == "claude_code.tool":
                        attrs = attr_map(span.get("attributes"))
                        unrenamed.append(
                            {
                                "file": os.path.basename(path),
                                "version": version,
                                "tool_name": attrs.get("tool_name"),
                                "gen_ai.operation.name": attrs.get("gen_ai.operation.name"),
                                "gen_ai.tool.name": attrs.get("gen_ai.tool.name"),
                                "subagent_type": attrs.get("subagent_type"),
                                "gen_ai.agent.name": attrs.get("gen_ai.agent.name"),
                                "attr_keys": sorted(attrs.keys()),
                            }
                        )

    print("== span name counts by collector version ==")
    for (version, name), n in sorted(by_version_name.items()):
        print(f"  v{version:<5} {n:6d}  {name}")

    print(f"\n== un-renamed claude_code.tool spans: {len(unrenamed)} ==")
    shape = Counter()
    for u in unrenamed:
        shape[
            (
                u["version"],
                "tool_name=" + repr(u["tool_name"]),
                "op=" + repr(u["gen_ai.operation.name"]),
                "subagent_type=" + repr(u["subagent_type"]),
            )
        ] += 1
    for k, n in sorted(shape.items(), key=lambda kv: -kv[1]):
        print(f"  {n:5d}  {k}")

    if unrenamed:
        print("\n== attribute keys present on the first few un-renamed spans ==")
        for u in unrenamed[:5]:
            print(f"  {u['file']} v{u['version']}: {u['attr_keys']}")

    # Also: did any renamed execute_tool span lack gen_ai.operation.name? (sanity)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
