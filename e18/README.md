# E18: crash recovery latency

Measures the extra wait a user sees when a moca worker or the supervisor is killed, on the Docker Compose
trial, with the model replaced by a canned-response stub. Spec: `../docs/specs/E18-crash-recovery-latency-design.md`.
Plan: `../docs/specs/E18-crash-recovery-latency-plan.md`.

## Run

Needs Node 22+, Docker with Compose, and a moca checkout (`E18_COMPOSE_DIR`, default `~/gh/moca/deploy/compose`).

```bash
./run.sh stub --runs 10 --out results/runs.jsonl    # four cases x 10 runs, stubbed model
ANTHROPIC_API_KEY=... ./run.sh real --n 20 --out results/baseline.json   # real-model median T
node report.mjs --runs results/runs.jsonl --baseline results/baseline.json --out RESULTS.md
```

Unit tests (no Docker): `node --test test/`.

## First thing to check

The stub is unverified against the harness (spec §3.2). Before the full run, `./run.sh stub --runs 1 --cases W-I`
must produce one record. If the harness rejects the stub's replies, fix `lib/stub.mjs`; if it cannot be made to
work, the spec's fallback is a recorded-response replay.

## Host

Record the host (OS, Docker version, `SH_WORKERS`) next to the results; numbers are indicative for other environments.
