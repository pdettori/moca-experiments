# E17c report — after moca #974, does a lease's charge follow its working set, and what does the drop cost?

Date: 2026-11-23. Spec: `experiments/e17-lease/SPEC.md` v0.8 §13. Plan: `PLAN-E17C.md`. Predictions:
`predictions-e17c.json`, sealed 2026-11-22 (`d21de77`, code `668ba0e`), with the pre-seal cuts E17C-C1/C2 and the
post-seal deviation E17C-D1. Rig: the E15/E16/E17 metal host (AWS m7i.metal-24xl, 96 vCPU, 377 GiB), profile
`fresh-metal`, 1024 MiB guests. Code under test: moca `e5ae5151` (#966 `normalise_us`, #970 abort keeps the lease,
#974 idle page-cache drop and the footprint charge). Arms: `sbx` (per-`Exec`), `ship-300` (lease, idle 300 s,
`SH_LEASE_CACHE_DROP_S` 30, the default) and `ship-300-nd` (the same with the drop off). Both lease arms charge the
footprint: `memory.current` less reclaimable page cache.

**Verdict: 2′ and 5b′ pass; 5a′ and 3′ fail as sealed.**

- **The charge now stays off the ceiling.** None of `ship-300`'s 309 heavy +45 s footprint readings at `pycache` was
  at ≥ 0.9 of guest RAM, against E17b's 0.536 on `memory.current` at +15 s. The same holds with the drop off (0 of
  307). The host-cache exclusion alone keeps leases below the ceiling at this workload.
- **5a′ still fails on its other half:** the share of heavy commands whose charge "follows" is 0.275 (14 of 51)
  against a 0.50 bar. The rule judges 15 s after a command, before the 30 s drop fires. With the drop on, a lease
  starts a heavy command from a dropped cache, so the command's growth includes re-reading its files, and that
  growth is still in place at +15 s. The no-drop arm follows 49 of 49. The rule, inherited from E17b, measures the
  wrong instant for this design (§5).
- **The drop costs little latency.** Warm `py_short` is still 82–86% faster than per-`Exec` and warm `py_import`
  39–42% faster, at N = 1 and N = 128 (2′ pass). Calls after a drop are 1.21× (`py_import`) and 1.32× (`py_short`)
  the median of calls that kept their cache.
- **3′ fails:** at the squeeze point the worker refused 6 lease starts (`memory-budget`) while an idle lease existed
  (1 at N = 32, 5 at N = 48). Most are moca's futility rule by design; two are not explained (§6). No memory-guard
  event, and all 368 reclaims took the idle-longest lease.
- **Squeeze density:** with the smaller charges no rung up to N = 48 reclaimed every minute (E17b: by N ≈ 40). The
  climb ended at N = 48 after a rig error at N = 56 (deviation E17C-D1).
- **The ownership walk, observed:** 94 ms at 10 000 files and 720 ms at 100 000, against E17b's inferred 91 and
  756 ms.

## 1. What ran

| Step | Rungs | Notes |
|---|---|---|
| Bring-up (Task 11) | `E17C=1` setup at `e5ae5151`; snapshots `e17c-e5ae5151-{1024,256}` (balloon-fpr-v1); end-to-end check; smoke | E17b's runs moved to `/srv/e15/runs-e17b/`. The smoke checked `vm_fp ≤ vm_mem` on every reading: up to 385 MiB per VM is left out as host cache |
| Calibration (pre-seal) | N = 1 baselines and class probes at `pycache`, three arms; the `pycache-low` and 256 MiB gates | Seeds s4–s6 `empty_window` in every arm (the corpus schedule). Both gates failed: C1, C2 |
| Latency (2′, 5a′, 5b′) | post-seal N = 1 seeds 11–14 and N = 128, three arms | R-z2 (fresh post-seal seeds), R-z6 (top-up, not needed: 11–14 all evaluable) |
| Squeeze (3′) | baselines; `ship-300` climb N = 1–48 under `MemoryMax` 24576 MiB; `sbx` at N = 48 | D1: rig error at N = 56; climb ended at N = 48 |
| Walk (Q7) | ownership walk at 10 000 and 100 000 files | 500 000 not run (needs moca #907's open half) |

Cut before the seal (user, 2026-11-22):
- **C1 `pycache-low`:** its gate failed again. Even with `E15_START_ZERO=1` and an 1800 s window, each seed got 0–1
  of the calls criterion 2 reads; pooled, 1–2 per class against the 5 a class-matched baseline needs.
- **C2 the 256 MiB stages:** `py_analyze` was OOM-killed in 20 of 20 runs at every `ANALYZE_WORK_SCALE` from 32 to
  1, in both arms. The scale sets CPU work; the memory is the imported stack and the dataset.

## 2. Criteria

| | Criterion | Result |
|---|---|---|
| 5a′ | charge follows the working set after a heavy command | **fail**: pinned share 0.0 (0 of 309 at +45 s; bar ≤ 0.50) passes; follow share 0.275 (14 of 51; bar ≥ 0.50) fails |
| 2′ | warm `py_short` ≥ 50%, `py_import` ≥ 30% faster than `sbx` | **pass**: 0.82 / 0.42 at N = 1, 0.86 / 0.39 at N = 128 |
| 5b′ | replacement lease's first `py_grep` ≤ 1.5× `sbx` | **pass**: 0.18–0.95 |
| 3′ | squeeze: no guard event, no refusal with an idle lease, idle-longest reclaimed | **fail**: 6 refusals with an idle lease; no guard event; 368 of 368 reclaims correct |

`verdict.json` (`results/e17c/`) is `analysis/verdict_e17c.py` over the rung tree, with the sealed reading `plus45`.

## 3. Latency (2′) and the drop's cost

| Arm | N | `py_short` gain | `py_import` gain | `py_grep` gain |
|---|---|---|---|---|
| `ship-300` | 1 | 0.82 | 0.42 | 0.27 |
| `ship-300` | 128 | 0.86 | 0.39 | 0.81 |
| `ship-300-nd` | 1 | 0.83 | 0.42 | 0.05 |
| `ship-300-nd` | 128 | 0.88 | 0.41 | 0.81 |

The two lease arms are within 0.03 of each other on the gated classes. `py_grep` (reported) is near zero at N = 1 on one or two warm calls and about 0.81 at N = 128, where per-`Exec`'s grep reads a cold host cache under load. Split by whether the session's previous call
ended more than 30 s before (so the guest had dropped its cache), `ship-300` at N = 128:

| Class | After drop: n, median | Kept: n, median | Ratio |
|---|---|---|---|
| `py_import` | 16, 666 ms | 56, 549 ms | 1.21 |
| `py_short` | 103, 10 ms | 181, 8 ms | 1.32 |
| `py_grep` | 27, 306 ms | 51, 339 ms | 0.90 |
| `py_analyze`, `py_test` | — | — | 1.00 |

A dropped cache is re-read from the host page cache, so the cost is a fraction of a cold start. Per-class tables are
in `results/e17c/latency/`.

## 4. Memory (5a′)

| Reading (`ship-300`, `pycache`, pooled) | Readings | Pinned (≥ 0.9 of guest RAM) |
|---|---|---|
| footprint at +45 s (sealed) | 309 | 0 |
| footprint at +15 s | 441 | 0 |
| footprint at the idle tail | 277 | 0 |
| `ship-300-nd` footprint at +45 s | 307 | 0 |
| E17b `memory.current` at +15 s (context) | 1323 | 709 (0.536) |

Pinned share is the fraction of readings at ≥ 0.9 of guest RAM, the same basis as E17b's sealed bar. Both lease
arms read 0.0, so F1's host-cache exclusion is enough by itself at this workload. The guest drop's effect shows in
`memory.current` instead, which the charge no longer uses.

## 5. Why the follow half fails

The follow rule (E17B-R29) judges a heavy command whose growth is ≥ 64 MiB. It asks whether the footprint at
+15 s gave back at least half the growth. Under the drop that asks the wrong question:

1. A lease idle for 30 s drops its clean cache. The next heavy command starts from a low footprint.
2. The command re-reads its dataset and venv into the guest cache. That growth is real memory the command keeps
   using, not something it frees.
3. At +15 s the drop has not fired yet (it fires 30 s after the command ends), so the growth is still there: the
   command does not "follow".

With the drop off, a command starts from a full cache; its growth is mostly anonymous memory that free-page
reporting returns within 15 s, so 49 of 49 follow. The rule's instant is right for free-page reporting and wrong for
an idle drop. Judged at +45 s instead (not sealed, reported), no reading is pinned. A future criterion should judge
the charge after the drop's delay, or at the idle tail.

## 6. Squeeze (3′)

| N | Reclaims | Refusals with an idle lease | Guard events |
|---|---|---|---|
| 1–16 | 0 | 0 | 0 |
| 24 | 9 | 0 | 0 |
| 32 | 48 | 1 | 0 |
| 40 | 93 | 0 | 0 |
| 48 | 168 | 5 | 0 |

Every reclaim took the idle-longest lease. The sealed stop rule (a reclaim in every whole minute of the window) was
never met: reclaims came in bursts, so `min_per_minute` was 0 at every rung.

**The refusals.** Each was a new lease's 192 MiB start charge against a 16 GiB budget (24 576 − 8192 MiB):
- **By design (4 of 6):** busy leases had grown after admission, putting the committed total 1.8–5.1 GiB over the
  budget. The idle leases together could not cover that, and moca's `evictForAdmissionLocked` refuses rather than
  end warm leases for a refusal that would happen anyway (its futility check). F1 lets more leases in at their small
  idle charge; when they turn busy and grow, the overshoot is larger. The criterion, from E17b, did not foresee a
  shortfall larger than one idle lease.
- **Not explained (2 of 6, N = 48):** 0.03 and 0.13 GiB over, which any idle lease would cover. The admission path
  skips an idle lease whose gate is held and returns early when the reclaim queue is full; at 168 reclaims in the
  rung either could apply. The worker does not log which. A moca follow-up.

**The rig error at N = 56 (D1).** The squeezed `e15.slice` sat at 23.3 of 24 GiB with `memory.high` throttling
(memory PSI up to 69%), mostly the page cache of destroyed VMs (E17b's F2). A VM restore missed Firecracker's 5 s
API-socket timeout, so a session's first call ran outside a lease and the driver aborted the rung. The user ended the
climb at its last valid rung. N = 56 is kept on disk, not counted; it shows 36 refusals (30 with an idle lease) and
194 correct reclaims.

## 7. The ownership walk (Q7)

| Files | `normalise_us` median (A) | B | A − B (E17b's inference) |
|---|---|---|---|
| 10 000 | 94 ms | 0 | 89 ms |
| 100 000 | 720 ms | 0 | 762 ms |

The worker's own phase confirms E17b's inference within 6%.

## 8. Predictions (sealed file, scored)

| # | Prediction | Outcome |
|---|---|---|
| 1 | 5a′ holds: pinned ∈ [0, 0.20], follow ∈ [0.50, 1] | **falsified**: pinned 0.0 holds, follow 0.275 |
| 2 | `ship-300-nd` pinned ∈ [0.10, 0.60], ≥ 0.10 above `ship-300` | **falsified**: 0.0 |
| 3 | 2′ holds; `ship-300-nd` within 0.05 | holds |
| 4 | after-drop ÷ kept: `py_import` ∈ [1.0, 1.5], `py_short` ∈ [1.0, 3.0] | holds: 1.21, 1.32 |
| 5 | 5b′ ratios ∈ [0.15, 1.0] | holds: 0.18–0.95 |
| 6 | 3′ holds; continuous reclaim only at N ≥ 48 | **falsified**: 6 refusals (no continuous reclaim by N = 48) |
| 7 | walk 10k ∈ [50, 200] ms, 100k ∈ [400, 1200] ms, B 0 | holds: 94, 720, 0 |
| 8 | driver < 1% of host CPU | holds: 0.003% |

5 of 8 hold. The misses are the two places where the inherited criteria met F1's design: a follow rule timed before
the drop, and a refusal rule that does not tell a futile reclaim from a missed one. Prediction 2 missed because the
host-cache exclusion did more than expected.

## 9. Findings for moca

1. **The admission refusals with an idle lease (§6).** Log, on a `memory-budget` refusal, why idle leases were not
   reclaimed (futile, gate held, reclaim queue full), and look at the two N = 48 cases. Consider reclaiming idle
   leases on the lease tick when busy growth has pushed the committed total over the budget, before the next
   admission arrives.
2. **The restore timeout under cgroup throttling (D1).** Firecracker's 5 s API-socket wait fails a restore when the
   slice is under `memory.high`. A bounded slice (F2) makes this reachable; either count the slice's page cache or
   make the wait adaptive.
3. **5a′'s follow rule (§5)** is an experiment-side finding, not moca's: the idle drop is working.

## 10. Recommendation

F1 does what it was built for: a lease's charge no longer sits at its ceiling, and the latency cost of the 30 s drop
is small (1.2–1.3× on calls after a drop, gains still 82–86% and 39–42%). The two failures are criteria mismatches
plus one moca follow-up (finding 1), not a regression. Whether to keep the 30 s default, and whether the remaining
findings block turning lease mode on, are the user's decisions; on this evidence the drop can stay at 30 s.

Raw run output: the next `data-v*` release (`data/MANIFEST.md`). Summaries in git: `results/e17c/`.
