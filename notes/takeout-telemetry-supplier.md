# Supplying raw traces to takeout-telemetry via S3

Added 2026-10-21. The collector now exports traces to S3 as well as Honeycomb,
so Claude Code sessions can become "menu items" (replay shapes) in
[takeout-telemetry](https://github.com/honeycombio/takeout-telemetry), which
lives locally at `~/code/honeycombio/takeout-telemetry`.

## The chain

```
Claude Code → collector → otlp/honeycomb  (as before)
                        → awss3/takeout   → s3://devrel-takeout-telemetry-dev-6a8ca705/claude-code/
                                             year=2026/month=10/day=21/hour=20/minute=06/traces_<id>.json
```

Then, in the takeout repo (`docs/ADMIN-GUIDE.md`, "Shape data: capture → pack → publish"):

```bash
cd ~/code/honeycombio/takeout-telemetry/src/packer
AWS_PROFILE=really-devrel-sandbox python -m packer pack \
  --source s3://devrel-takeout-telemetry-dev-6a8ca705/claude-code --workdir <dir> --signals traces
# edit <dir>/shapes.yaml, fill TODOs, then:
python -m packer upload --workdir <dir> --dest s3://<bucket>/shapes/<dir>
```

The packer's "capture" step expects exactly the awss3 exporter's default output:
OTLP JSON, `year=/month=/day=/hour=/minute=/<signal>_<id>.json`, **uncompressed**
(the packer does not read gzip). That's why `compression: none` and
`marshaler: otlp_json` in `config.yaml`.

The exporter sits *after* the transform processors, so the archived spans carry
the Agent-Timeline names (`chat {model}`, `execute_tool X`) and the version marker.
That's intentional: a replayed shape should look right in Honeycomb without
needing this collector again.

Only traces go to S3 for now. Adding `awss3/takeout` to the logs/metrics
pipelines is a one-line change each if a shape wants them (`packer pack
--signals traces,logs,metrics`).

## AWS access

* Account: `really-devrel-sandbox` (657166037864). The buckets are in us-east-1.
* IAM user `takeout-telemetry-supplier`, inline policy allowing **only**
  `s3:PutObject` on `arn:aws:s3:::devrel-takeout-telemetry-dev-6a8ca705/claude-code/*`.
  It cannot list, read, or write anywhere else. Fine to have its key on a laptop.
* Created by `scripts/create-s3-supplier-user.sh`, which also writes
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `S3_BUCKET` /
  `S3_PREFIX` into `.env`. docker-compose passes them into the container, where
  the AWS SDK picks up the standard env vars with no further config.
* Re-running the script mints a new key (IAM allows two per user; delete the old
  one in the console if it complains).
* The dev bucket's bucket policy only grants public read on `shapes/*`, so the
  raw `claude-code/` prefix stays private. Note that with
  `OTEL_LOG_USER_PROMPTS=1` etc. the archived spans contain prompts and tool
  output; moving to the prod bucket is a conscious step, not a default.

### Gotcha: `AWS_PROFILE` in the shell

jessitron's shell exports `AWS_PROFILE=sandbox`, which is a *different* AWS account
(414852377253). The first version of the create script honored `$AWS_PROFILE` and
created the user there; S3 PutObject then failed with
`AccessDenied ... because no resource-based policy allows the s3:PutObject action`
(cross-account write with no bucket policy). The script now ignores `AWS_PROFILE`
and hardcodes `really-devrel-sandbox` (override with `SUPPLIER_AWS_PROFILE`).
When running `aws` by hand for this project, always pass `--profile really-devrel-sandbox`.

## Testing without Claude Code

`scripts/send-test-span.sh` posts one synthetic span to the collector's HTTP port.
Within ~10s (batch timeout 5s plus the S3 flush) an object appears:

```bash
aws s3 ls --recursive s3://devrel-takeout-telemetry-dev-6a8ca705/claude-code/ --profile really-devrel-sandbox | tail
```

A 403 in `docker compose logs` from `awss3/takeout` means credentials or policy;
the exporter retries with backoff and queues, so Honeycomb export is unaffected.

## Observed while testing

Some `claude_code.tool` spans arrive in S3 **un-renamed** (still `claude_code.tool`,
no `execute_tool` prefix), alongside correctly renamed `chat {model}` spans. The
`execute_tool` rule's condition uses `attributes["gen_ai.operation.name"] == nil`,
which is the same shape as OTTL gotcha #1 in CLAUDE.md (`!= nil` doesn't behave on
missing attributes). Or `tool_name` is missing on those spans. Not investigated yet;
tracked in Linear.
