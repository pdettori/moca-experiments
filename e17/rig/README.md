# e17/rig: E17 on the E15 metal host

E17 runs on the E15 metal host (`/srv/e15`, profile `fresh-metal`) with E15's rig, plus switches in
`e15/rig` that only the new point and arm names select, and only on `fresh-metal`:

- **points** (`points.sh`) `pycache`, `pycache-low`, `pycache-d64` and `pycache-d768`:
  - library `/srv/e15/src/e17/workload/library.json`;
  - 1536 MiB workspaces;
  - arms `sbx resident-300 lease-30 lease-120`;
  - no fallback.

  | point | corpus (`/srv/e15/corpora/<corpus>/`) | template |
  |---|---|---|
  | `pycache` | `pycache` (9.5% duty) | `template-pycache-d256` |
  | `pycache-low` | `pycache-low` (1.5% duty) | `template-pycache-d256` |
  | `pycache-d64` | `pycache` | `template-pycache-d64` |
  | `pycache-d768` | `pycache` | `template-pycache-d768` |
- **arms** (`lib.sh`) `lease-30` and `lease-120`: the resident worker (`microvm-worker-resident`) with
  `E15_RESIDENT=1` and `E15_RESIDENT_IDLE_S=30` or `120`. In everything else they behave as
  `resident-300`: standby depth 0, a 1200 s warm-up, end-session Execs, and footprint drift
  (`record.py`).
- **setup.sh step 8c**: checks each staged pycache corpus against its report's `corpus_sha256` and
  records it in `state/artifacts`.

The pycache templates (`/srv/e15/template-pycache-d<D>/workspace.img`) are built by `bringup.sh`
(Task 5) with `e17/workload/build_pycache_workspace.sh`, not by `setup.sh`. `setup.sh`'s template
loop is E15's, unchanged.

| file | what |
|---|---|
| `sync.sh` | laptop: rsync `e15/`, `e16/` and `e17/` to `/srv/e15/src/`, and install the metal library. Stage the corpora `$E17_CORPORA/{pycache,pycache-low}/` to `/srv/e15/corpora/<point>/`, and the wheels `$E17_WHEELS/` to `/srv/e15/wheels-pycache/` |

Then, on the host: `rung.sh {sbx|resident-300|lease-30|lease-120} N {pycache|pycache-low|pycache-d64|pycache-d768}`.
Rig runs are started by the controller only.

Tests: `bash e15/rig/tests/rig.test.sh` (the E17 section, plus golden dumps of the pre-E17 points
and arms in `e15/rig/tests/golden/`) and `pytest e17`.
