# E17b Implementation Plan — the shipped lease mode, measured: the whole verdict

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build everything E17b needs (spec §3, stage b), then run it on the AWS metal rig and report the verdict on the four questions and the five pass criteria of spec §7.5, with the shipped lease mode (moca `mode = lease`, plans 2–5 merged) in place of E17a's E15 resident patch.

**Architecture:** E17a drove the worker through the relay's harness path with one bearer token, which the relay forces to per-Exec, so E17b cannot reuse the E15 driver as is. The driver gains a sandbox-path mode: per-session `moca-sandbox+jwt` tokens minted in Go (no control plane), a `LeaseControl set_mode` before each session's first Exec, and capture of every `LeaseEvent` into `calls.jsonl`. The relay gets a sandbox-token keyset; the worker runs the shipped lease with spec §6's admission settings. New arms `ship-30`, `ship-120`, `ship-300` (the idle timeout travels in the token, one worker env for all three) run beside `sbx`. Analysis gains a lease-log warm/cold join, a lease-aware VM-age map, and a reclaim-and-notice matcher. A `squeeze` point and the §7.4 probes (level-1 overhead, ownership walk) are added. Predictions for E17b are sealed after calibration and before the first measured rung.

**Tech Stack:** Go (the E15 driver, `experiments/e15-session-density/driver/`), Python 3 (analysis, pytest), bash (rig scripts and their shell tests), the moca checkout at a new pin (relay in node, `microvm-worker` in Go).

**Spec:** `experiments/e17-lease/SPEC.md` v0.6 (§3, §5, §6, §7.1–7.5, §8, §9, §10). Parents: E15 (`experiments/e15-session-density/SPEC.md`, metal procedure §13) and E16. Design under test: moca `docs/specs/2026-11-08-sbx-lease-mode-design.md`. E17a's record: `results/E17A-REPORT.md`, `predictions.json` (sealed, not edited).

**Branches:** this plan on `e17b/plan`; the build on `e17b/build` (moca-experiments). Rig: the AWS m7i.metal-24xl (profile `fresh-metal`, `/srv/e15`), reached through `~/gh/aws-rig` (the controller's public IP must be in its SG/NACL: `aws-rig set-location home`).

## Global Constraints

- **Sealed procedures stay.** E15's and E16's rig procedures and E17a's results are unchanged. New behaviour is selected only by the new arm and point names, on `fresh-metal` only. `experiments/e15-session-density/rig/tests/rig.test.sh` and `pytest experiments/e16-low-duty/rig` keep passing.
- **No rig time before the user approves this plan, and no measured rung before the predictions are sealed with the user's approval** (spec §9). Rig work is controller-run, one manifest line per host change in `~/e17-manifest.md` with an undo command (`| UNDO: cmd`).
- **Rig safety (2026-11-09 incident):** every `rm -rf`, snapshot build and workspace wipe targets a checked leaf path. A snapshot goes in a NEW leaf and never over `/srv/e15/snapshots/e15`.
- **Same moca commit for every E17b arm, selected by a profile, not by editing the shared pin.** `sbx` and the `ship-*` arms run from one new pin, `E17B_MOCA_PIN`, which only takes effect when `E17B=1` is set (the chain script sets it). Then `lib.sh` uses it for `E15_MOCA_PIN` and a separate checkout `$E15_ROOT/moca-e17b` for `E15_MOCA` (so `setup.sh`'s clone, build stamps, snapshot key, relay, `microvm-worker` and guest agent all follow the pin), and the resident-patch build is skipped. With `E17B` unset every sealed E15/E16/E17a procedure resolves exactly as before (`E15_MOCA_PIN` at `lib.sh:77` is untouched). E15's metal `sbx` ladder was built at that older pin, so it cannot be reused (spec §8: reuse only when moca commit, rig profile and corpus hash match); `sbx` is re-run at the new pin. Cost: about 6 more rig hours. This is the plan's call.
- **Arm names:** `ship-30`, `ship-120`, `ship-300` are the shipped lease at idle timeout 30, 120, 300 s. The spec's `lease-300` for stage b means `ship-300`. The E17a arms `resident-300`, `lease-30`, `lease-120` keep their meaning and are not run.
- **Guest RAM 1024 MiB** in every arm; the `pycache` N = 1 rungs and `squeeze` also run once at 256 MiB with `D` scaled to the same dataset-to-RAM ratio (spec §5). Standby depth: `sbx` 2, lease 0.
- **Lease admission (spec §6):** `SH_LEASE_START_MB` 192, `SH_LEASE_HEADROOM` 1.25, `SH_LEASE_PAGECACHE_MB` 256, `SH_LEASE_RECLAIM_FREE_MB` the worker's derived default, `SH_MAX_COMMITTED_MB` host RAM − 8 GiB (369 GiB on this host) on the lease arms. The `sbx` arm keeps E16's never-binding budget. `WORKER_MAX_CONCURRENT` above every N. Physical guards (`SH_HOST_MEM_FLOOR_MB` 1536) stay.
- **Driver is non-keepalive** (lease spec §4): `keepalive = false`, no `LeaseKeepalive`. Leases end by the idle timeout, by reclaim, or by the worker stopping at the rung's end.
- **Gated criteria** (spec §7.5, revised): (1) `ship-300` `N_max` ≥ `sbx` `N_max` at `default`; (2) at `pycache` N = 1 and 128 the median warm `py_short` ≥ 50% and `py_import` ≥ 30% faster than `sbx` (`py_grep`, `py_analyze`, `py_test` reported); (3) at `squeeze`: zero memory-guard events, zero refusals while an idle lease existed, every reclaim of the idle-longest lease; (4) every lease end has exactly one matching notice; (5) a lease VM's charge falls back toward its working set after a heavy command, and a replacement VM reads its workspace from the host page cache.
- **Determinism and records.** Seeds fixed; each rung's `params.json` records the moca commit, the snapshot hash and the arm's token idle timeout; a result that mixes commits is not reported as one arm.

## Review Focus

1. **The worker's `lease end` log line has no `at_unix_ms` and its timestamp has whole seconds**, so ends cannot be matched to notices by time. They are paired in order per key and by reason. A notice is acknowledged once it is queued on the stream, so a call that then fails still consumed one: the driver records `lease_events` on failed calls too. A lease that ends with no later Exec has its pending end carried by the driver's end-of-run status sweep. A lease still live when the worker stops gets no end line in that rung's log (its `worker_restart` end is written by the NEXT worker's start) and no notice: it is counted as `live_at_stop` and excluded from criterion 4 by definition. Pinned in Task 3 (events on failed calls, the sweep) and Task 8 (ordered pairing, trailing end, live at stop).
2. **`kind=` in the worker's exec log line** broke `warmcold.py`'s regex for the shipped worker: every call would be `unknown`. Pinned in Task 6 (`TestExecLineWithKind`).
3. **A new workspace runs per-Exec until `set_mode`** (worker `lease_state.go`: "epoch unknown, mode per-exec until set_mode"), so an Exec sent before it silently measures the wrong arm. Pinned in Task 3: the driver refuses to send a first Exec before its `set_mode` is acknowledged, and a rung fails if any session's first call lacks a lease `start` event. Later calls are not checked per call: a warm call carries no event and a replacement lease after an idle end carries only the `end`, its `start` is in the worker log. Whether a call ran in a live lease is derived from the worker log (Task 6).
6. **Every ship- session's first lease runs the lease spec's R7 ownership walk** (an unknown state at `set_mode` means `root_wrote`), so the first call of each session is slower than any later cold call. Those calls are tagged `first_lease` and kept out of the warm/cold gates; the cost is reported on its own (Tasks 6, 11).
4. **Lease cgroups are retired, not returned to the free list**, so `vm_age.py`'s LIFO replay assigns wrong VM names. Pinned in Task 7.
5. **Token expiry mid-session.** A session longer than the token's `exp` fails its next Exec. Pinned in Task 2 (refresh before `exp`) and checked in Task 3.

---

## File Structure

| Path | Responsibility | Task |
|---|---|---|
| `experiments/e15-session-density/driver/sbxtoken.go`, `sbxtoken_test.go` | Mint `moca-sandbox+jwt` and `moca-sandbox-mode+jwt` tokens (Ed25519) | 2 |
| `experiments/e15-session-density/driver/lease.go`, `lease_test.go`, `exec.go`, `main.go`, `record.go` | Sandbox-path mode: set_mode, LeaseEvent capture, session policy, status sweep | 3 |
| `experiments/e15-session-density/rig/lib.sh`, `setup.sh`, `points.sh`, `rung.sh`, `ladder.sh`, `record.py`, `smoke.sh`, `reprobe.sh` | Profile `E17B` (own pin and checkout), arms `ship-*`, relay keyset, worker env, point `squeeze` | 1, 4, 9 |
| `experiments/e17-lease/rig/snapshot-e17b.sh` | Build the 1024 MiB and 256 MiB lease snapshots in new leaves | 5 |
| `experiments/e17-lease/workload/` (`library.json`, `project/`, corpus generator) | `tmpfs_share`, class `py_shmem` | 10 |
| `experiments/e17-lease/analysis/warmcold_lease.py`, `latency_report.py` | Lease-log warm/cold join; latency report for `ship-*` | 6 |
| `experiments/e17-lease/analysis/vm_age_lease.py` | Lease-aware VM age and memory-returns reading (criterion 5) | 7 |
| `experiments/e17-lease/analysis/lease_ends.py` | Reclaim-order and notice matcher (criteria 3, 4) | 8 |
| `experiments/e17-lease/rig/probe-overhead.sh`, driver subcommand `ownwalk` | §7.4 probes | 11 |
| `experiments/e17-lease/predictions-e17b.json` | E17b predictions (new file; `predictions.json` stays sealed) | 13 |
| `experiments/e17-lease/results/E17B-REPORT.md`, `results/README.md` | The verdict | 15 |

---

### Task 1: Branch and the `E17B` profile (own pin, own checkout)

**Files:**
- Modify: `experiments/e15-session-density/rig/lib.sh` (`E15_MOCA_PIN` `:77`, `E15_MOCA` `:654`), `experiments/e15-session-density/rig/setup.sh` (`:210-236`, `:266`, `:281-284`)
- Test: `experiments/e15-session-density/rig/tests/rig.test.sh`

**Interfaces:**
- Produces: with `E17B=1`, `lib.sh` sets `E15_MOCA_PIN="$E17B_MOCA_PIN"` and `E15_MOCA="$E15_ROOT/moca-e17b"`, and `setup.sh` skips the resident-patch build (`:266`); `E17B_MOCA_PIN` is a full 40-hex sha in a new file `experiments/e17-lease/rig/e17b-pins.sh` (the controller picks upstream/main at build time and records it in the commit message); every other pin in `pins.sh` is unchanged. With `E17B` unset nothing resolves differently.

- [ ] **Step 1:** Create branch `e17b/build` from `e17b/plan`. Run `bash experiments/e15-session-density/rig/tests/rig.test.sh` and `pytest experiments/e16-low-duty/rig experiments/e17-lease`. Expected: pass (baseline).
- [ ] **Step 2: Failing tests** in `rig.test.sh`: `test_e17b_profile_off_is_unchanged` (with `E17B` unset, `E15_MOCA_PIN` is the old value and `E15_MOCA` is `$E15_ROOT/moca`, for the whole variable set `lib.sh` exports); `test_e17b_profile_on` (pin and checkout follow, the snapshot key from `setup.sh:281` contains the new pin, no resident-build call); `test_e17b_pin_is_a_full_sha`.
- [ ] **Step 3:** Implement. Run: PASS.
- [ ] **Step 4:** Commit `feat(e17b): E17B profile with its own moca pin and checkout`.

---

### Task 2: Driver — sandbox token minter

**Files:**
- Create: `experiments/e15-session-density/driver/sbxtoken.go`, `sbxtoken_test.go`

**Interfaces:**
- Produces: `type TokenKey struct{ Priv ed25519.PrivateKey }` with `func (k TokenKey) Kid() string` = hex(sha256(SPKI DER of the public key))[:16], the relay's `keyIdFor` (`packages/control-plane/src/token.ts:98`; the relay rejects a keyset whose kid does not match its key); `func (k TokenKey) PublicKeyset() string` = `<kid>:<base64 of the SPKI DER>`, the form `SH_SANDBOX_TOKEN_PUBLIC_KEYS` takes. `func (k TokenKey) MintSandbox(c SandboxClaims) (string, error)` and `MintSetMode(c SetModeClaims) (string, error)`: JWS EdDSA with `kid` in the header and `typ` `moca-sandbox+jwt` (set-mode: `moca-sandbox-mode+jwt`). Exec token claims, all required: `iss`, `aud` = `moca-sandbox`, `sub`, `tenant`, `sbx`, `wrk`, `wsk` (= `sbx`), `scope` = `["exec"]`, `mode`, `mode_epoch`, `idle_timeout_s`, `iat`, `exp`, `jti` (a fresh uuid). Set-mode token claims: the same without `tenant` and `scope`; TTL at most 300 s (`SANDBOX_MODE_TOKEN_TTL_S`). **The Exec token's `mode_epoch` equals the epoch of the `set_mode` the driver sent (1)**: a lower epoch than the worker's is refused with `stale_mode`. The issuer is a parameter with no default: the relay refuses to boot with a keyset and no `SH_SANDBOX_TOKEN_ISSUER`. `type Refresher` re-mints when less than 30% of the TTL remains.

- [ ] **Step 1: Failing tests** `TestMintedTokenHasTheClaims`: decode a minted token and assert header (`typ`, `alg`, `kid`), `exp` = now+TTL, every claim in the list above (including `aud`, `scope`, `iat`, `jti`, `tenant`), and `wsk == sbx`; `TestKidIsTheSPKIHash`: the kid equals the hex of the first 8 bytes of sha256 over the public key's SPKI DER, for a fixed test key. `TestRefresherMintsBeforeExp`: a fake clock at 71% of TTL returns the same token, at 71%+1 s a new one.
- [ ] **Step 2:** Run `go test ./... -run Token`. Expected: FAIL (undefined).
- [ ] **Step 3:** Implement `sbxtoken.go` with the standard library only.
- [ ] **Step 4:** Add the cross-language contract test `TestTokenVerifiesInTheMocaRelay` (skipped unless `E15_MOCA` points at a moca checkout with node): it writes a token and the keyset to a temp dir and runs a node script that calls the moca control-plane's verifier (`packages/control-plane/src/sandbox-token.ts`, via `npx tsx`) and asserts it accepts. This is the check that Go and TS agree.
- [ ] **Step 5:** Run all driver tests: PASS. Commit `feat(e17b): driver mints sandbox and set-mode tokens`.

---

### Task 3: Driver — lease mode, LeaseEvent capture, session policy

**Files:**
- Create: `experiments/e15-session-density/driver/lease.go`, `lease_test.go`
- Modify: `driver/main.go` (flags), `driver/exec.go` (`execOne`, `exec.go:104-142`), `driver/replay.go` (end-session path, `replay.go:364`), `driver/record.go` (`calls.jsonl` rows)

**Interfaces:**
- Consumes: Task 2's `TokenKey`, `Refresher`.
- Produces: flags `--lease-mode` (bool), `--token-key FILE`, `--idle-timeout-s N`, `--token-wrk` (default `e15`, the worker's `SANDBOX_ID`), `--token-iss` (required with `--lease-mode`, no default). With `--lease-mode` each session (workspace key K) gets `sbx = wsk = K`, `wrk = e15`, `mode = lease`, `idle_timeout_s = N`, `mode_epoch = 1`; the first Exec of K is preceded by a `LeaseControl set_mode` (epoch 1, a set-mode token) whose acknowledgement is awaited; a failed `set_mode` fails the session. `calls.jsonl` rows gain `lease_events []{state, reason, at_unix_ms, age_ms, mode}` (deduped on `at_unix_ms`), **recorded on failed and timed-out calls too** (a notice is acknowledged once queued on the stream, so a failed call may have consumed one), and `first_lease` (true for the first call of each session). A session whose first call carries no `start` event is marked `not_lease` and the rung fails on it (Review Focus 3); later calls are not checked per call. No end-session command is sent in lease mode. At the end of the run, before the driver exits, for every K it calls `LeaseControl status` and writes `{key, state, pending}` to `lease-tail.jsonl`: `state` is the lease state (`none`, `active`, `expiring`) and `pending` the pending event if any (a lease still live then is the matcher's `live_at_stop`).

- [ ] **Step 1: Failing tests** with a fake relay (the driver's existing test harness, or a minimal grpc fake): `TestFirstExecWaitsForSetMode` (an Exec is never sent before set_mode is acked; a delayed ack delays the Exec); `TestLeaseEventsAreRecordedAndDeduped` (two Execs carrying the same `at_unix_ms` event record it once); `TestNoEndSessionInLeaseMode`; `TestStatusSweepWritesStateAndPending`; `TestEventsRecordedOnFailedCalls` (an Exec whose stream carries an `end` event and then errors still records it); `TestFirstCallWithoutStartIsNotLease`; `TestExecTokenCarriesTheSetModeEpoch` (epoch 1 in both); `TestRefreshesTokenBeforeExp` (TTL 2 s, session 5 s, no auth failure); `TestFailsWhenSetModeRefused` (the session is recorded failed, not served per-exec).
- [ ] **Step 2:** `go test ./... -run 'Lease|SetMode|Sweep'`. Expected: FAIL.
- [ ] **Step 3:** Implement. Token claims per Task 2; the relay requires `ExecRequest.sandbox_id == wrk` and `workspace_key == wsk` (`sandbox-caller.ts:467-469`).
- [ ] **Step 4:** Run the whole driver suite and `go vet`: PASS. Commit `feat(e17b): driver lease mode (set_mode, lease events, status sweep)`.

---

### Task 4: Rig wiring — arms, relay keyset, worker env, points

**Files:**
- Modify: `experiments/e15-session-density/rig/lib.sh` (`E15_ARMS` `:119-121`, `worker_env` `:762-801`, `worker_bin` `:803-809`, relay env `setup.sh:176-179` and the per-rung relay restart), `points.sh` (`:94-107`), `rung.sh` (`:314`, `:455-458`, `:493`, driver flags), `record.py:25`, `smoke.sh:45`, `reprobe.sh:58`
- Test: `rig/tests/rig.test.sh`

**Interfaces:**
- Produces:
  - arms `ship-30`, `ship-120`, `ship-300` on `fresh-metal` only; `e15_is_arm` accepts them; they use `microvm-worker` (stock, rebuilt at the pin), depth 0, and `worker_env` writes `SH_MAX_COMMITTED_MB=<host RAM MiB − 8192>`, `WORKER_MAX_CONCURRENT=<above the ladder's top N>`, the Task 1 lease knobs left at defaults (printed in the worker banner and copied into `params.json`);
  - the relay env gains `SH_SANDBOX_TOKEN_PUBLIC_KEYS` (the content of `$dir/token.pub`, `<kid>:<base64 SPKI>`) and `SH_SANDBOX_TOKEN_ISSUER` (the fixed string `e17b-driver`, also passed to the driver as `--token-iss`; the relay refuses a keyset without an issuer); the rung generates an ed25519 key per run with `e15-driver mint-key --out DIR`, a subcommand added to the driver in this task, writing `token.key` (mode 0600) and `token.pub`;
  - `rung.sh` passes `--lease-mode --token-key ... --idle-timeout-s <30|120|300>` to the driver for `ship-*`, and the end-of-run order is: driver status sweep, then worker stop;
  - `params.json` records `arm`, `idle_timeout_s`, `moca_commit`, `snapshot_hash`, and the resolved lease banner line.

- [ ] **Step 1: Failing shell tests** in `rig.test.sh`: `test_ship_arms_known_on_fresh_metal_only`, `test_ship_worker_env_has_admission` (asserts `SH_MAX_COMMITTED_MB` = RAM − 8192 for a stubbed RAM, `WORKER_MAX_CONCURRENT` above N, depth 0), `test_ship_rung_passes_lease_flags`, `test_relay_env_has_token_keyset_and_issuer`, `test_sbx_arm_unchanged` (its worker env is byte-identical to today's).
- [ ] **Step 2:** `bash rig/tests/rig.test.sh`. Expected: FAIL.
- [ ] **Step 3:** Implement. Every hard-coded arm list listed under Files gains the three arms.
- [ ] **Step 4:** Run `rig.test.sh` and `pytest experiments/e16-low-duty/rig`: PASS. Commit `feat(e17b): ship-30/120/300 arms, relay token keyset, lease worker env`.

---

### Task 5: Snapshots at the pin (controller-run, rig)

**Files:**
- Create: `experiments/e17-lease/rig/snapshot-e17b.sh`
- Test: `experiments/e17-lease/rig/tests/snapshot-e17b.test.sh` (checks the leaf-path guard and argument handling with stubs; no KVM)

**Interfaces:**
- Produces: `snapshot-e17b.sh --ram-mb {1024|256} --leaf NAME` runs moca's `deploy/microvm/build-snapshot.sh` from `$E15_MOCA` (the `E17B` profile's checkout, Task 1) at the pin with the E15 kernel (`vmlinux-6.18.44`), the E15 rootfs rebuilt through `build-rootfs.sh` with the pinned guest agent, into `/srv/e15/snapshots/<NAME>`; it refuses a leaf that exists, is `e15`, or is outside `/srv/e15/snapshots/`. The manifest must list `lease-v1` and `balloon-fpr-v1`, which the script asserts.

- [ ] **Step 1: Failing test:** the guard refuses `e15`, an existing leaf, `../x`, and a path outside the snapshots dir; accepts `e17b-<sha8>-1024`.
- [ ] **Step 2–3:** Implement the guard and the build call. Run the test: PASS. Commit `feat(e17b): snapshot builder with a leaf-path guard`.
- [ ] **Step 4 (controller, rig):** build `e17b-<sha8>-1024` and `e17b-<sha8>-256`; record both manifests' hashes and features in `results/bringup/manifest.md`. Expected: features include `lease-v1` and `balloon-fpr-v1`; `microvm-worker` starts on each and prints `lease=on` with `balloon` not warned.

---

### Task 6: Analysis — warm/cold join on the shipped worker's log

**Files:**
- Create: `experiments/e17-lease/analysis/warmcold_lease.py`, `tests/test_warmcold_lease.py`, fixtures under `tests/fixtures/lease/`
- Modify: `experiments/e17-lease/analysis/latency_report.py` (arm map and `--baseline-arm sbx --arms ship-30,ship-120,ship-300`)

**Interfaces:**
- Consumes: the worker log line shapes `vmpool: exec req=%d workspace_key=%q kind=%s vm=%s … exit=… err=…`, `vmpool: lease start workspace_key=%q vm=%s mode=%s`, `vmpool: lease end workspace_key=%q vm=%s mode=%s reason=%s age=…` (and the `worker_restart` form), plus the driver's `lease_events` in `calls.jsonl`.
- Produces: `warmcold_lease.py RUNDIR` writes `warmcold.jsonl` and `warmcold-report.json`. A call is **warm** when its first Exec ran on the same `vm=` as the previous call's last Exec for the key and no `lease end` for that key lies between; whether a call ran in a live lease at all comes from the worker log (a `lease start` with no later `lease end` for the key), not from the call's own events, because a warm call carries none and a replacement lease after an idle end carries only the `end`. Calls tagged `first_lease` (Task 3) are reported separately and kept out of the warm/cold gates (their latency includes the first-lease ownership walk, Review Focus 6). The driver's events are a second source for the first call of each session and for every `end`; the report states how many calls the two sources disagree on (must be 0 to count the run). Unmatched calls are `unknown`, never guessed.

- [ ] **Step 1: Failing tests:** `test_exec_line_with_kind` (Review Focus 2); `test_warm_when_same_vm_no_end`; `test_cold_after_idle_end`; `test_cold_after_reclaim_end`; `test_sources_agree_or_flagged` (a fixture where the driver events say cold and the log says warm yields a disagreement count of 1); `test_replacement_lease_call_carries_only_an_end` (cold, with its start taken from the log); `test_first_lease_calls_excluded_from_gates`; `test_latency_report_for_ship_arms` (medians per class, gain vs `sbx`).
- [ ] **Step 2:** `pytest experiments/e17-lease/analysis`. Expected: FAIL.
- [ ] **Step 3:** Implement. Reuse `latency_report.py`'s statistics; do not fork them.
- [ ] **Step 4:** PASS. Commit `feat(e17b): warm/cold join on the shipped worker's lease log`.

---

### Task 7: Analysis — lease-aware VM age and the memory-returns reading

**Files:**
- Create: `experiments/e17-lease/analysis/vm_age_lease.py`, `tests/test_vm_age_lease.py`, fixtures
- Consumes: `experiments/e16-low-duty/analysis/vm_age.py` (`vm_table`, `:76-93`), `samples.jsonl` (`vm_mem`, 1 Hz cgroup memory.current), the `restore phases id=vm-N` and `destroy phases id=vm-N` lines (`SH_DIAG_PHASES=1`)

**Interfaces:**
- Produces: `vm_age_lease.py RUNDIR` maps lease VMs to cgroups by replaying the allocator with lease cgroups **retired** (`cgroup_pool.go:164-173`: never pushed back on the free list); writes `vm_age_lease.json` with: memory against age per arm; the share of lease VMs above 50% and 90% of guest RAM; and for the FPR reading (criterion 5): per heavy Exec, `memory.current` at the Exec's end, 15 s later, and the peak within it, and the verdict "charge follows the working set" = the 15 s value is at most the peak minus half of what the guest freed (the guest's freed amount comes from the `py_shmem` and `py_analyze` readings of Task 10). Also the replacement-VM reading: for a lease that began after an `idle` end of the same key, the first `py_grep` time against `sbx`'s median (criterion 5, second half).

- [ ] **Step 1: Failing tests:** `test_retired_cgroups_not_reused` (a fixture in which a naive LIFO replay assigns VM names wrongly and the lease replay does not); `test_memory_falls_back_after_heavy_exec`; `test_share_above_thresholds`; `test_replacement_vm_first_grep`.
- [ ] **Step 2–3:** Implement; validate the mapping on the smoke rung's real logs in Task 12 (each `vm-N` seen in exec lines resolves to exactly one cgroup).
- [ ] **Step 4:** PASS. Commit `feat(e17b): lease-aware VM age and memory-returns analysis`.

---

### Task 8: Analysis — reclaim order and the notice matcher

**Files:**
- Create: `experiments/e17-lease/analysis/lease_ends.py`, `tests/test_lease_ends.py`, fixtures

**Interfaces:**
- Consumes: worker `lease end workspace_key=… vm=… mode=… reason=… age=…` lines (timestamps to whole seconds; no `at_unix_ms`), `/stats` samples (`leaseEnds{reason:n}`, `refusals["memory-budget"]`, `memory_high` events in `samples.jsonl`), `calls.jsonl` (`lease_events`, including those on failed calls, and per-key last-Exec end times), `lease-tail.jsonl` (Task 3).
- Produces: `lease_ends.py RUNDIR` writes `lease_ends.json`: (a) **notice matching, by order and reason, not by time:** for each key, the n-th `lease end` log line pairs with the n-th `end` notice the driver saw for that key (events from `calls.jsonl` in call order, then the key's `pending` from `lease-tail.jsonl`); the pair must agree on `reason`; unmatched ends, unmatched notices and reason mismatches are listed (criterion 4); a lease whose `lease-tail` state is `active` or `expiring` is `live_at_stop`, has no end line in this rung's log (the worker's own `worker_restart` end is written by the next worker start) and is excluded from criterion 4, with its count reported; (b) **reclaim order:** for each `memory_reclaim` end, whether its key had the longest idle time (end-of-run reference time minus the key's last Exec end from `calls.jsonl`) among the leases alive at that moment; times in the log are whole seconds, so a tie within 1 s counts as correct and is reported as a tie; (c) **refusals while an idle lease existed:** the count of `memory-budget` refusals at instants when at least one lease was idle and alive (must be 0); (d) guard events (`memory_floor`, `memory_high`, OOM kills).

- [ ] **Step 1: Failing tests:** `test_every_end_has_one_notice_in_order`; `test_reason_mismatch_flagged`; `test_notice_from_a_failed_call_counts` (a call that errored after carrying an `end` event); `test_duplicate_notice_flagged`; `test_trailing_end_matched_by_status_sweep` (Review Focus 1); `test_live_at_stop_excluded_and_counted`; `test_log_with_no_at_unix_ms_and_whole_second_timestamps` (two ends of different keys in the same second still pair correctly); `test_reclaim_picks_idle_longest`, `test_reclaim_tie_within_a_second_reported` and `test_reclaim_wrong_pick_flagged`; `test_refusal_with_idle_lease_counted`; `test_guard_events_counted`.
- [ ] **Step 2–3:** Implement. **Step 4:** PASS. Commit `feat(e17b): reclaim-order and notice matcher`.

---

### Task 9: Point `squeeze`, the MemoryMax knob, and the chain script

**Files:**
- Modify: `experiments/e15-session-density/rig/points.sh`, `rung.sh`, `lib.sh` (`e15.slice` handling, `:688-694`)
- Create: `experiments/e17-lease/rig/chain-e17b.sh`
- Test: `rig/tests/rig.test.sh`

**Interfaces:**
- Produces: point `squeeze` = `pycache-d768` (D 768, 1536 MiB image, corpus `pycache`) with arms `ship-300` and `sbx`; `E15_SQUEEZE_MEMMAX_MB` makes `rung.sh` run `systemctl set-property --runtime e15.slice MemoryMax=… MemoryHigh=…` before the worker starts and restore the original at the rung's end and on error; the squeeze **ladder rule**: climb the ladder until `/stats.leaseEnds.memory_reclaim` is at least 1 per minute for the whole measurement window, then stop and record that N; `chain-e17b.sh` is the ordered run list of Tasks 14's rungs, each written to its own log, resumable at a named stage.

- [ ] **Step 1: Failing shell tests:** `test_squeeze_point_defined`, `test_memmax_set_and_restored_on_error` (a stubbed `systemctl` records the calls: set, then restore even when the rung body fails), `test_squeeze_stop_rule` (stubbed stats feed), `test_chain_resumes_at_stage`.
- [ ] **Step 2–3:** Implement. **Step 4:** PASS. Commit `feat(e17b): squeeze point, MemoryMax knob, chain script`.

---

### Task 10: Workload — `tmpfs_share` and `py_shmem`

**Files:**
- Modify: `experiments/e17-lease/extract/pycache_corpus.py` (`--tmpfs-share X`, default 0.5), `workload/library.json`, `workload/project/`
- Test: `experiments/e17-lease/extract/tests`, `workload/tests`

**Interfaces:**
- Produces: sessions flagged `tmpfs: true` (a fraction `tmpfs_share`, seeded) run their `py_analyze` and `py_test` with `PYC_CACHE_DIR=/tmp/pycache-<key>` so the dependency and dataset caches live in guest tmpfs; a tiny class `py_shmem` (`awk '/^Shmem:/{print $2}' /proc/meminfo`, reported only, excluded from the latency gates and from per-class medians, emitted once at the end of every turn) gives the guest's `Shmem` for spec §7.3 (the shipped agent does not sample it; this is the workaround). Corpus and dataset bytes stay deterministic.

- [ ] **Step 1: Failing tests:** `test_tmpfs_share_fraction` (400 sessions, share 0.5, seed 1: the count is the same on two runs and within ±5% of half); `test_corpus_unchanged_with_share_zero` (byte-identical to the E17a corpus hash); `test_py_shmem_in_every_turn`; `test_py_shmem_excluded_from_gates`.
- [ ] **Step 2–3:** Implement. **Step 4:** PASS. Commit `feat(e17b): tmpfs_share sessions and the py_shmem reading`.

---

### Task 11: The §7.4 probes — level-1 overhead and the ownership walk

**Files:**
- Create: `experiments/e17-lease/rig/probe-overhead.sh`, driver subcommand `ownwalk` in `driver/ownwalk.go` with `ownwalk_test.go`, `workload/build_tree.sh` (N-file workspace builder)

**Interfaces:**
- Produces: `probe-overhead.sh` runs `baseline.sh`/`classprobe.sh` for arm `ship-300` at N = 1 on the `default` probe classes, so the report can state per-call added latency against the E17a resident patch's N = 1 numbers (`results/calibration/`); `e15-driver ownwalk --files {10000|100000|500000}` builds a workspace of that many files written as root (a per-exec Exec). It then measures two cold lease Execs on that workspace, each in a fresh VM: **A**, the first lease Exec after the `per-exec` to `lease` switch (`set_mode`, epoch +1; the state is `root_wrote`, so the ownership walk runs), and **B**, a cold lease Exec after a `LeaseControl reset` (the state is known and clean, no walk). The walk is A − B (cold start and the Exec itself cancel); each is repeated 5 times and the median reported. The result goes to `ownwalk.json`. The same switch happens at the start of every `ship-` session (Review Focus 6), so the pycache workspace's own walk is read from the `first_lease` calls the same way.

- [ ] **Step 1: Failing tests:** `TestOwnwalkOrdersTheSteps` (a fake relay records: per-exec write, set_mode, A, reset, B, in that order, epochs 0 then 1); `TestOwnwalkReportsAMinusB`; shell test `test_probe_overhead_uses_ship_arm`.
- [ ] **Step 2–3:** Implement. **Step 4:** PASS. Commit `feat(e17b): level-1 overhead and ownership-walk probes`.

---

### Task 12: Bring-up (controller-run, rig)

**Files:** results under `results/bringup/` (manifest lines, logs)

- [ ] **Step 1:** `aws-rig set-location home` if the controller's IP changed; `ssh` check; confirm the rig is idle and fresh (`pgrep firecracker` 0, no E16/E17a leftovers); append the E17b start line to `~/e17-manifest.md`.
- [ ] **Step 2:** `sync.sh` from the clean `e17b/build` commit (it refuses uncommitted changes under `experiments/`); `setup.sh` steps rebuilding the relay and `microvm-worker` at the new pin; Task 5 Step 4 snapshots. Record elapsed times (the docs have none).
- [ ] **Step 3:** Smoke: `rung.sh ship-300 1 pycache` then `rung.sh sbx 1 pycache`. Expected: every session's first call carries a lease `start` and the worker log shows a live lease for every call, `warmcold-report.json` shows zero `unknown` and zero source disagreements, `vm_age_lease.json` maps every `vm-N` to exactly one cgroup, `lease_ends.json` matches every end to a notice, the driver CPU is under 1% of the host.
- [ ] **Step 4:** Re-run the lease KVM gates (level 1 and level 2) at the 1024 MiB snapshot: `-run TestGateLease` as in plan 5's rig recipe; expected: all PASS (spec §7.4). Record.
- [ ] **Step 5:** N = 1 baselines and class probes for `sbx`, `ship-300` at `default` and `pycache` (calibration for the predictions). Commit the small records; the raw data goes to the next `data-v*` release as before.

---

### Task 13: E17b predictions — draft, user approval, seal

**Files:**
- Create: `experiments/e17-lease/predictions-e17b.json` (E15's format: `{status, sealed, spec, section, recordedAt, codeCommit, calibration, predictions:[{id, claim, metric, falsifiedBy, note}]}`)

- [ ] **Step 1:** Draft from Task 12's calibration, one entry each: the re-scoped latency gains (`py_short` ≥ 0.50, `py_import` ≥ 0.30 at N = 1 and 128); `N_max` ranges for `sbx` and `ship-300` at `default` and their order; `ship-30` warm share; peak and charged lease memory and the share above 900 MiB with free-page reporting, and whether the charge follows the working set; the replacement-VM `py_grep` time against `sbx`; the level-1 overhead in ms per Exec (E17a's 2–50 ms stands as the prior); `squeeze` outcomes (zero guard events, zero refusals with an idle lease, reclaim order); notices (zero unmatched ends); the ownership-walk times at 10k, 100k, 500k files; the driver under 1% of host CPU. Each with `falsifiedBy`.
- [ ] **Step 2 (user gate):** send the draft to the user. Nothing in Task 14 starts until they approve it. On approval set `sealed: true`, record the code commit, commit `docs(e17b): predictions sealed`.

---

### Task 14: The measured rungs (controller-run, rig; about 23 h)

- [ ] **Step 1 (latency and FPR, `pycache`, spec §8 row "re-scoped latency and capacity rungs"):** `sbx` and `ship-300` at N = 1 and N = 128 on `pycache` and `pycache-low`; `ship-30` and `ship-120` at N = 128 on `pycache`; the 256 MiB runs at N = 1. About 8 h.
- [ ] **Step 2 (capacity):** ladders at `default` for `sbx` and `ship-300` (both at the new pin); `ship-30` and `ship-120` at `default` only if the rig time allows after Step 1 (the spec's arms; user may cut them). About 10 h. Apply E16's no-wedge re-judge and the staggered reading, reported beside the primary verdict.
- [ ] **Step 3 (`squeeze`):** `ship-300` and `sbx` with `E15_SQUEEZE_MEMMAX_MB` chosen from a first short climb; the stop rule of Task 9; at 1024 and 256 MiB. About 3 h.
- [ ] **Step 4 (§7.4):** the overhead probe and `ownwalk` at 10k, 100k, 500k files. About 2 h.
- [ ] **Step 5:** after each stage run `warmcold_lease.py`, `vm_age_lease.py`, `lease_ends.py`, `latency_report.py`; a stage whose analysis reports an `unknown` call, a source disagreement or an unmatched end stops the chain and goes to the user. Teardown per E15 §13; manifest complete.

---

### Task 15: The report

**Files:**
- Create: `experiments/e17-lease/results/E17B-REPORT.md`; modify `results/README.md`, `SPEC.md` (status line, version 0.7)

- [ ] **Step 1:** Write the report in E17A-REPORT's shape: per criterion pass/fail with the numbers, predictions scored against the sealed file, the §7.4 overhead and walk times, the notice and reclaim tables, what the E17a resident patch overstated (the gap), the SBX0 256 MiB reading, and the recommendation on turning lease mode on (the decision stays the user's).
- [ ] **Step 2:** Update the spec status and the results README (raw data in the next `data-v*` release; link, do not commit raw traces). Open a PR on moca-experiments.

---

## Self-Review

**Spec coverage.** §3 stage b: Tasks 2–4. §5 arms and the 256 MiB runs: Tasks 4, 14. §6 configuration: Task 4 and Global Constraints. §7.1 latency: Tasks 6, 14. §7.2 capacity: Task 14 Step 2. §7.3 memory, reclaim, tmpfs, `squeeze`: Tasks 7–10, 14. §7.4: Task 11, Task 12 Step 4. §7.5 criteria 1–5: Global Constraints; Tasks 6–8 compute them. §8 rig time: Task 14 (about 23 h plus the sbx re-run). §9 predictions: Task 13. §10 risks: the egress wedge is reported beside the verdict (Task 14 Step 2); admission sizing uses the shipped values, recorded in `params.json`.

**Gaps and calls to confirm.** (a) `sbx` is re-run at the new pin because E15's v0.9.0 ladder cannot be reused: about 6 h more than spec §8's 18 h row assumed. (b) The spec's "Shmem sampled by the agent" does not exist in the shipped agent; `py_shmem` is the workaround (no moca change). (c) There is no reclaim log line; reclaim is a `lease end … reason=memory_reclaim` line, and the idle-longest check is computed from call timestamps (Task 8). (d) Lease arms `ship-30` and `ship-120` capacity ladders are optional after the primary verdict. (e) The `E17B` profile keeps the shared E15 pin untouched, so the sealed procedures cannot move (PR review). (f) Notices are matched by order and reason because the worker's end line has no `at_unix_ms` (PR review).

**Proportion.** About 330 lines against a 376-line spec. Code appears only as interfaces and test names.
