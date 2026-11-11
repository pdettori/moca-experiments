# How an experiment is laid out

Experiments from E15 on follow one file set. Older ones (E1–E14) keep their own
`EXPERIMENTS.md` plus `RESULTS-SUMMARY.md` convention.

| File | Purpose |
|---|---|
| `SPEC.md` | The question, design, hypotheses, pass and fail criteria. Written and approved before any run. |
| `PLAN.md` | The steps to build and run it. |
| `predictions.json` | Predictions sealed (committed) before the measured runs. Never edited after sealing. |
| `RESULTS.md` | What was measured, the verdict on each sealed prediction, and the caveats. Every number traces to a file under `results/`. |
| `results/` | Summaries and per-run records (`record.json`, `params.json`, `summary.json`). Raw traces are not stored here; see `data/MANIFEST.md`. |
| `rig/`, `driver/`, `analysis/`, `extract/` | Run scripts, the replay driver, and the analysis and tests. Later experiments reuse E15's instrument and say so in their SPEC. |

## Rules

- **Seal before you run.** Commit `predictions.json` before the measured runs. A prediction that
  fails is reported as falsified, not rewritten.
- **One source of truth.** A `RESULTS-SUMMARY.md` or README is an entry point, not the record. If
  it disagrees with the record, the record wins and the summary gets fixed.
- **Corrections are appended.** If a published number is retracted, say so in the record with the
  date, and keep the original text visible.
- **No hosts or credentials.** Rig addresses come from the environment (`RIG_IP`); docs use
  placeholders such as `<RIG_IP>`. No tokens, key material or home-directory paths.
- **Raw data is a release asset.** Add the archive to `data/MANIFEST.md` with its sha256 and a
  `data-vN` tag. Do not commit files over a few MB.
