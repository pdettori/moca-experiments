#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies
# experiments/e17-lease/rig/tests/chain-e17c.test.sh
#
# Rig-free tests for chain-e17c.sh (PLAN-E17C Task 4): the stage list, its order and needs, the seal refusal
# (predictions-e17c.json), the refusal of E15_* stage knobs and of E17b's switches, the bring-up stages allowed before
# the seal, the gate stages that Tasks 9 and 10 build (listing, needs, seal only: ruling R-b), the cal stages (N = 1
# baselines from E15_START_ZERO=1, topped up to 4 seeds), the squeeze value, the 500 000-file walk's refusal (moca #907)
# and the verdict stage. The chain runs from a staged copy under a scratch root (/srv/e15/src layout); rung.sh,
# ladder.sh, baseline.sh, smoke.sh, ownwalk.sh and the analysis scripts are stubs that log their calls.
#
# Run: bash experiments/e17-lease/rig/tests/chain-e17c.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E15RIG="$RIG/../../e15-session-density/rig"
fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (want '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# --- syntax and lint -------------------------------------------------------------------------
SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in chain-e17c.sh tests/chain-e17c.test.sh; do
  bash -n "$RIG/$s" 2>"$TMP/n.out"
  check "bash -n $s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x "$RIG/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck $s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  else
    check "shellcheck available" "missing" "present"
  fi
done

# --- fixture: a staged copy under a scratch root, stub stage commands --------------------------------------------
T="$TMP/e15-rig-test.chain"
PIN=2222222222222222222222222222222222222222
mkdir -p "$T/src/e15" "$T/src/e17" "$T/state" "$T/runs" "$TMP/stub" "$TMP/an"
cp -R "$E15RIG" "$T/src/e15/rig"
cp -R "$RIG" "$T/src/e17/rig"
CHAIN="$T/src/e17/rig/chain-e17c.sh"
PRED="$T/src/e17/predictions-e17c.json"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 "$PIN" >"$TMP/pins.sh"
printf '%s\n' "$PIN" >"$T/state/go-stock-e17b"
echo fresh-metal >"$T/state/host_profile"
CLOG="$TMP/calls.log"
printf '#!/usr/bin/env bash\ncase "$*" in *e15-worker.service*) [ -e "%s/worker-up" ] ;; *) exit 1 ;; esac\n' "$TMP" >"$TMP/stub/systemctl"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$TMP/stub/sudo"
chmod +x "$TMP/stub/systemctl" "$TMP/stub/sudo"
# a stage stub KIND: logs "KIND ARGS tag=<E15_TAG> seed=<E15_SEED> zero=<E15_START_ZERO> memmax=<...> e17c=<E17C>
# e17b=<E17B> ram=<E17B_GUEST_RAM_MB>"; fails when the logged call starts with $FAIL_ON. rung writes the rung's
# params.json and record.json (reason STUB_REASON); baseline writes seeds N1-s1..N1-s$STUB_SEEDS (default 3) and
# N1/baseline.json; ladder at a squeeze point a ladder.json with squeeze.stop_n 40 and the memmax it ran under.
mkstub() {
  cat >"$TMP/stub-$1.sh" <<SH
#!/usr/bin/env bash
line="$1 \$* tag=\${E15_TAG:-unset} seed=\${E15_SEED:-unset} zero=\${E15_START_ZERO:-unset} memmax=\${E15_SQUEEZE_MEMMAX_MB:-unset} e17c=\${E17C:-unset} e17b=\${E17B:-unset} ram=\${E17B_GUEST_RAM_MB:-unset}"
echo "\$line" >>"$CLOG"
case "\$line" in "\${FAIL_ON:-NONE}"*) echo "stub failure: \$line" >&2; exit 1 ;; esac
rungdir() { # DIR ARM REASON
  mkdir -p "\$1"
  printf '{"arm": "%s", "n": 1, "moca_commit": "%s", "driver_exit": 0, "rung_failed": null, "memory_abort": null}\n' "\$2" "\${STUB_COMMIT:-$PIN}" >"\$1/params.json"
  printf '{"aborted": false, "holds": true, "reason": "%s"}\n' "\$3" >"\$1/record.json"
}
case "$1" in
rung) rungdir "\$E15_ROOT/runs/\$3/\$1/N\$2\${E15_TAG:+-\$E15_TAG}" "\$1" "\${STUB_REASON:-ok}" ;;
baseline)
  for s in \$(seq 1 "\${STUB_SEEDS:-3}"); do rungdir "\$E15_ROOT/runs/\$1/\$2/N1-s\$s" "\$2" ok; done
  mkdir -p "\$E15_ROOT/runs/\$1/\$2/N1"
  printf '{"class_medians": {"build": 1.0}}\n' >"\$E15_ROOT/runs/\$1/\$2/N1/baseline.json" ;;
ladder)
  if [ "\${1#squeeze}" != "\$1" ]; then
    mkdir -p "\$E15_ROOT/runs/\$1/\$2"
    printf '{"squeeze": {"stop_n": 40, "memmax_mb": %s}}\n' "\$E15_SQUEEZE_MEMMAX_MB" >"\$E15_ROOT/runs/\$1/\$2/ladder.json"
  fi ;;
esac
exit 0
SH
  chmod +x "$TMP/stub-$1.sh"
}
for k in rung ladder baseline smoke ownwalk; do mkstub "$k"; done
# analysis stubs: every gate script passes (E17b's gate itself is tested in chain-e17b.test.sh; the code is the same)
cat >"$TMP/an/warmcold_lease.py" <<'PY'
import json, os, sys
json.dump({"unknown": 0, "disagreements": 0, "failed_no_vm": 0, "config_refusals": 0, "valid": True}, open(sys.argv[1] + "/warmcold-report.json", "w"))
open(os.environ["ALOG"], "a").write("warmcold_lease %s\n" % sys.argv[1])
PY
cat >"$TMP/an/lease_ends.py" <<'PY'
import json, os, sys
json.dump({"notices": {}, "valid": True, "criterion4_pass": True}, open(sys.argv[1] + "/lease_ends.json", "w"))
open(os.environ["ALOG"], "a").write("lease_ends %s\n" % sys.argv[1])
PY
cat >"$TMP/an/freed_from_shmem.py" <<'PY'
import json, os, sys
json.dump({}, open(sys.argv[1] + "/shmem.json", "w"))
PY
cat >"$TMP/an/vm_age_lease.py" <<'PY'
import json, os, sys
json.dump({"mapping_valid": True}, open(sys.argv[1] + "/vm_age_lease.json", "w"))
open(os.environ["ALOG"], "a").write("vm_age_lease %s\n" % " ".join(sys.argv[1:]))
PY
cat >"$TMP/an/latency_report.py" <<'PY'
import os, sys
a = sys.argv[1:]
os.makedirs(a[a.index("--out") + 1], exist_ok=True)
PY
VERDICT_STUB='import os, sys
a = sys.argv[1:]
open(os.environ["ALOG"], "a").write("verdict_e17c %s\n" % " ".join(a))
open(a[a.index("--out") + 1], "w").write("{}")'

seal() { printf '{"status": "sealed", "sealed": %s, "predictions": []}\n' "$1" >"$PRED"; }
chain() { # [VAR=val ...] -- ARGS: run the staged chain; rc echoed, output in $TMP/c.out
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  : >"$CLOG"
  : >"$TMP/alog"
  env -u E17B -u E17C E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    E17C_TEST_HARNESS=1 E17C_RUNG="$TMP/stub-rung.sh" E17C_LADDER="$TMP/stub-ladder.sh" E17C_BASELINE="$TMP/stub-baseline.sh" E17C_SMOKE="$TMP/stub-smoke.sh" \
    E17C_OWNWALK="$TMP/stub-ownwalk.sh" E17C_ANALYSIS="$TMP/an" ALOG="$TMP/alog" ${envs[@]+"${envs[@]}"} bash "$CHAIN" "$@" >"$TMP/c.out" 2>&1
  echo $?
}
calls() { sed 's/ *tag=.*//' "$CLOG" | tr '\n' ';'; }
reset() { rm -rf "$T/e17c" "$T/runs" && mkdir -p "$T/runs"; }
listed() { sed -n '2,$p' "$TMP/c.out" | awk '{print $1 ":" $2}' | tr '\n' ' '; }

STAGES_WANT="smoke:- cal-pycache-sbx:- cal-pycache-ship-300:- cal-pycache-ship-300-nd:- gate-pycache-low:- gate-256:- \
lat-pycache-sbx-n128:seal lat-pycache-ship-300-n128:seal lat-pycache-ship-300-nd-n128:seal \
base-pycache-low-sbx:seal base-pycache-low-ship-300:seal lat-pycache-low-sbx-n128:seal lat-pycache-low-ship-300-n128:seal \
base-squeeze-sbx:seal base-squeeze-ship-300:seal squeeze-ship-300:seal squeeze-sbx:seal ownwalk:seal \
ram256-pycache-sbx-n1:ram256 ram256-pycache-ship-300-n1:ram256 ram256-base-squeeze-sbx:ram256 ram256-base-squeeze-ship-300:ram256 \
ram256-squeeze-ship-300:ram256 ram256-squeeze-sbx:ram256 \
ladder-default-sbx:opt ladder-default-ship-300:opt ownwalk-500k:opt verdict:seal "

test_list() {
  reset
  rm -f "$PRED"
  check "list: exit 0, the predictions state (predictions-e17c.json) in the header" \
    "$(chain -- --list)/$(head -1 "$TMP/c.out" | grep -c '^E17C stages (predictions: missing (.*predictions-e17c.json))')" "0/1"
  check "list: the stages in order, each with its needs (- before the seal, seal, ram256, opt)" "$(listed)" "$STAGES_WANT"
  check "list: the header names E17C_OPTIONAL and E17C_RAM256" \
    "$(head -1 "$TMP/c.out" | grep -c 'opt (E17C_OPTIONAL=1), ram256 (E17C_RAM256=1)')" "1"
  check "list: the commands (smoke, cal at pycache, the gates, ownwalk 10000 100000, the 500k walk, verdict)" \
    "$(awk '$1 == "smoke" || $1 == "cal-pycache-ship-300-nd" || $1 == "gate-pycache-low" || $1 == "gate-256" || $1 == "ownwalk" || $1 == "ownwalk-500k" || $1 == "squeeze-ship-300" || $1 == "verdict" {print $1 "=" $4, $5, $6}' "$TMP/c.out" | sed 's/ *#.*//; s/ *$//' | tr '\n' ';')" \
    "smoke=smoke;cal-pycache-ship-300-nd=cal pycache ship-300-nd;gate-pycache-low=gate-pycache-low;gate-256=gate-256;squeeze-ship-300=squeeze-ladder squeeze ship-300;ownwalk=ownwalk 10000 100000;ownwalk-500k=ownwalk-big 500000;verdict=verdict;"
  check "list: the 500k walk's note names moca #907; the squeeze's names 24576" \
    "$(grep -c '^ownwalk-500k .*# .*moca #907' "$TMP/c.out")/$(grep -c '^squeeze-ship-300 .*# .*24576' "$TMP/c.out")" "1/1"
}

# Ruling R-h: the operator's E15_* knobs are refused, as chain-e17b.sh refuses them; E17b's switches are refused too.
test_refuses_knobs() {
  reset
  seal true
  local v out=""
  for v in E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB E15_END_SESSION_RATE \
    E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS E15_PROBE_SEED E15_MEMINFO \
    E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED \
    E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH; do
    out+="$v=$(chain "$v=1" -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128):$(grep -c "E17C REFUSED: .*$v" "$TMP/c.out"):$(grep -c . "$CLOG") "
  done
  check "knobs: each E15_* stage knob set in the environment refuses the chain (exit 1), naming it, nothing run" \
    "$(printf '%s' "$out" | tr ' ' '\n' | grep -vc '=1:1:0$')" "0"
  check "knobs: an empty value counts as set; --list is refused too" \
    "$(chain E15_LADDER_EXTRA= -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)/$(grep -c . "$CLOG")/$(chain E15_RUNG=/tmp/x -- --list)" "1/0/1"
  out=""
  for v in E17B_OPTIONAL E17B_RAM256; do
    out+="$v=$(chain "$v=1" -- --list):$(grep -c "E17C REFUSED: .*$v.*E17C_" "$TMP/c.out") "
  done
  check "knobs: E17b's switches (E17B_OPTIONAL, E17B_RAM256) are refused, naming E17c's" "$out" "E17B_OPTIONAL=1:1 E17B_RAM256=1:1 "
  check "knobs: E17B_SQUEEZE_MEMMAX_MB other than 24576 is refused (spec §13.2); 24576 is accepted" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=16384 -- --list)/$(grep -c 'REFUSED: E17B_SQUEEZE_MEMMAX_MB=16384.*24576' "$TMP/c.out")/$(chain E17B_SQUEEZE_MEMMAX_MB=24576 -- --list)" "1/1/0"
  out=$(chain E17C_TEST_HARNESS= -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)
  check "hooks: without E17C_TEST_HARNESS=1 the test hooks are refused, each named, nothing run" \
    "$out/$(for v in E17C_RUNG E17C_LADDER E17C_BASELINE E17C_SMOKE E17C_OWNWALK E17C_ANALYSIS; do grep -q "REFUSED: .*$v" "$TMP/c.out" && printf '%s ' "$v"; done)/$(grep -c . "$CLOG")" \
    "1/E17C_RUNG E17C_LADDER E17C_BASELINE E17C_SMOKE E17C_OWNWALK E17C_ANALYSIS /0"
  check "knobs: the operator's own inputs are not knobs (E17C_OPTIONAL, E17C_RAM256, E15_MANIFEST)" \
    "$(chain E17C_OPTIONAL=0 E17C_RAM256=0 -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)/$(calls)" "0/rung sbx 128 pycache;"
}

test_refuses_unsealed() {
  local v
  for v in missing false '"true"' broken; do
    reset
    case "$v" in missing) rm -f "$PRED" ;; broken) printf '{"sealed": true,' >"$PRED" ;; *) seal "$v" ;; esac
    printf '%s:%s:%s:%s ' "$v" "$(chain)" "$(grep -c 'E17C REFUSED: predictions' "$TMP/c.out")" "$(grep -c . "$CLOG")"
  done >"$TMP/ref.out"
  check "seal: refused up front (exit 1, nothing run) unless predictions-e17c.json says \"sealed\": true (the boolean)" \
    "$(cat "$TMP/ref.out")" 'missing:1:1:0 false:1:1:0 "true":1:1:0 broken:1:1:0 '
  check "seal: the refusal names the stages that need it and how to stop before them" \
    "$(grep -c 'stages that need the seal: lat-pycache-sbx-n128 .* (stop before them with --to gate-256)' "$TMP/c.out")" "1"
  reset
  rm -f "$PRED"
  local st out=""
  for st in lat-pycache-ship-300-nd-n128 squeeze-ship-300 ownwalk verdict; do
    out+="$st=$(chain -- --from "$st" --to "$st"):$(grep -c . "$CLOG") "
  done
  check "seal: a seal stage alone is refused while unsealed, nothing run" "$out" "lat-pycache-ship-300-nd-n128=1:0 squeeze-ship-300=1:0 ownwalk=1:0 verdict=1:0 "
  check "seal: a ram256 or opt stage needs the seal too" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(chain E17C_OPTIONAL=1 -- --from ladder-default-sbx --to ladder-default-sbx)/$(grep -c . "$CLOG")" "1/1/0"
  check "seal: the gate stages run before the seal (not refused as needing it; they die as not built yet)" \
    "$(chain -- --from gate-pycache-low --to gate-pycache-low)/$(grep -c 'REFUSED' "$TMP/c.out")/$(grep -c 'not built yet (Task 9)' "$T/e17c/gate-pycache-low.log")/$(chain -- --from gate-256 --to gate-256)/$(grep -c 'not built yet (Task 10)' "$T/e17c/gate-256.log")" \
    "1/0/1/1/1"
}

test_bringup_unsealed() {
  reset
  rm -f "$PRED"
  check "bring-up: --to cal-pycache-ship-300-nd runs without the seal: smoke, then the three cal stages" \
    "$(chain -- --to cal-pycache-ship-300-nd)/$(calls)" \
    "0/smoke;baseline pycache sbx;rung sbx 1 pycache;baseline pycache ship-300;rung ship-300 1 pycache;baseline pycache ship-300-nd;rung ship-300-nd 1 pycache;"
  check "bring-up: every stage ran with E17C=1 and E17B=1, its log and .done under \$E15_ROOT/e17c" \
    "$(grep -c 'e17c=1 e17b=1 ' "$CLOG")/$(find "$T/e17c" -name '*.log' | wc -l | tr -d ' ')/$(find "$T/e17c" -name '*.done' | wc -l | tr -d ' ')/$([ -e "$T/e17b" ] && echo e17b || echo none)" "7/4/4/none"
  check "cal: the baseline and the top-up seed run with E15_START_ZERO=1; the 4th seed is E15_SEED=4, tag s4" \
    "$(grep '^baseline pycache sbx\|^rung sbx 1 pycache' "$CLOG" | sed 's/ memmax=.*//' | tr '\n' ';')" \
    "baseline pycache sbx tag=unset seed=unset zero=1;rung sbx 1 pycache tag=s4 seed=4 zero=1;"
  reset
  check "cal: a baseline that ran 4 or more evaluable seeds is not topped up" \
    "$(chain STUB_SEEDS=5 -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(calls)" "0/baseline pycache sbx;"
  reset
  check "cal: a top-up seed with an empty window does not count; the next seed runs" \
    "$(chain STUB_REASON=empty_window -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(calls)" \
    "1/baseline pycache sbx;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;"
  check "cal: after 12 seeds without 4 evaluable ones the stage fails, naming it" "$(grep -c '12 seeds gave 3 evaluable' "$T/e17c/cal-pycache-sbx.log")" "1"
  reset
  # review fix 1: a corrupt record.json from before the stage (a --from resume) makes the seed count unreadable: the stage
  # fails, never "done" with fewer than 4 seeds (5 good seeds here: without the corrupt one it would not top up)
  mkdir -p "$T/runs/pycache/sbx/N1-s9"
  printf '{"reason": ' >"$T/runs/pycache/sbx/N1-s9/record.json"
  check "cal: a corrupt N1-s* record.json fails the stage (unreadable seeds), no .done, no top-up rung" \
    "$(chain STUB_SEEDS=5 -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(grep -c 'seeds under .*pycache/sbx are unreadable' "$T/e17c/cal-pycache-sbx.log")/$([ -f "$T/e17c/cal-pycache-sbx.done" ] && echo "done" || echo open)/$(calls)" \
    "1/1/open/baseline pycache sbx;"
  reset
  check "smoke: the commit preflight covers E17c's three arms (another commit's ship-300-nd rung refuses the stage)" \
    "$(mkdir -p "$T/runs/pycache/ship-300-nd/N1-old"; printf '{"arm": "ship-300-nd", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache/ship-300-nd/N1-old/params.json"; chain -- --from smoke --to smoke)/$(grep -c 'is not from E17C_MOCA_PIN' "$T/e17c/smoke.log")/$(grep -c . "$CLOG")" "1/1/0"
  reset
  check "bring-up: --to gate-256 runs smoke and the cal stages, then stops at gate-pycache-low (not built yet), resume named" \
    "$(chain -- --to gate-256)/$(grep -c 'E17C gate-pycache-low FAILED rc=1 .*resume with --from gate-pycache-low' "$TMP/c.out")" "1/1"
}

test_sealed_stages() {
  reset
  seal true
  check "sealed: the pycache, pycache-low and squeeze stages in order; the squeeze climb at 24576 without any operator value" \
    "$(chain -- --from lat-pycache-sbx-n128 --to squeeze-sbx)/$(sed 's/ seed=.*memmax=/ memmax=/; s/ e17c=.*//' "$CLOG" | tr '\n' ';')" \
    "0/rung sbx 128 pycache tag=lat memmax=unset;rung ship-300 128 pycache tag=lat memmax=unset;rung ship-300-nd 128 pycache tag=lat memmax=unset;baseline pycache-low sbx tag=unset memmax=unset;baseline pycache-low ship-300 tag=unset memmax=unset;rung sbx 128 pycache-low tag=lat memmax=unset;rung ship-300 128 pycache-low tag=lat memmax=unset;baseline squeeze sbx tag=unset memmax=unset;baseline squeeze ship-300 tag=unset memmax=unset;ladder squeeze ship-300 tag=unset memmax=24576;rung sbx 40 squeeze tag=sq memmax=24576;"
  check "sealed: ship-300-nd rungs go through the analysis gate (a ship-* arm), with --sbx the same-named sbx rung" \
    "$(chain -- --from lat-pycache-ship-300-nd-n128 --to lat-pycache-ship-300-nd-n128)/$(grep '^vm_age_lease' "$TMP/alog" | sed "s#$T/runs/##g")" \
    "0/vm_age_lease pycache/ship-300-nd/N128-lat --sbx pycache/sbx/N128-lat"
  check "ownwalk: 10000 then 100000 files (the seal stage), under E17C=1" \
    "$(chain -- --from ownwalk --to ownwalk)/$(sed 's/ tag=.* e17c=/ e17c=/; s/ e17b=.*//' "$CLOG" | tr '\n' ';')" "0/ownwalk 10000 e17c=1;ownwalk 100000 e17c=1;"
  check "ram256: SKIP without E17C_RAM256=1; with it the pycache-d64 N=1 rungs at 256 MiB" \
    "$(chain -- --from ram256-pycache-sbx-n1 --to ram256-squeeze-sbx)/$(grep -c 'SKIP (ram256: E17C_RAM256=1 runs it)' "$TMP/c.out")/$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-ship-300-n1)/$(sed 's/ seed=.* ram=/ ram=/' "$CLOG" | tr '\n' ';')" \
    "0/6/0/rung sbx 1 pycache-d64 tag=ram256 ram=256;rung ship-300 1 pycache-d64 tag=ram256 ram=256;"
  check "opt: SKIP without E17C_OPTIONAL=1; with it the default ladders run" \
    "$(chain -- --from ladder-default-sbx --to ladder-default-ship-300)/$(grep -c 'SKIP (optional: E17C_OPTIONAL=1 runs it)' "$TMP/c.out")/$(chain E17C_OPTIONAL=1 -- --from ladder-default-sbx --to ladder-default-ship-300)/$(calls)" \
    "0/2/0/ladder default sbx 56;ladder default ship-300 80;"
  mkdir -p "$T/snapshots/e17c-${PIN:0:8}-1024"
  printf '{"hash": "h", "guest_ram_mb": 1024, "features": ["lease-v1", "balloon-fpr-v1"]}\n' >"$T/snapshots/e17c-${PIN:0:8}-1024/manifest.json"
  # ruling R-n: a SKIP with its reason (exit 0), so a resume goes on to verdict; its .done and .log say skipped
  check "ownwalk-500k: SKIPPED with its reason (moca #907, the 4 GiB workspace drive), exit 0, nothing run" \
    "$(chain E17C_OPTIONAL=1 -- --from ownwalk-500k --to ownwalk-500k)/$(grep -c '^E17C ownwalk-500k SKIP (.*moca #907.*)' "$TMP/c.out")/$(grep -c 'skipped: .*4 GiB.*moca #907.*no workspace drive size' "$T/e17c/ownwalk-500k.log")/$(grep -c 'skipped: .*moca #907' "$T/e17c/ownwalk-500k.done")/$(grep -c . "$CLOG")" "0/1/1/1/0"
  printf '%s\n' "$VERDICT_STUB" >"$TMP/an/verdict_e17c.py"
  check "ownwalk-500k: a plain resume with E17C_OPTIONAL=1 goes through it to verdict" \
    "$(rm -f "$T/e17c/ownwalk-500k.done"; chain E17C_OPTIONAL=1 -- --from ownwalk-500k)/$(grep -c 'E17C ownwalk-500k SKIP' "$TMP/c.out")/$(grep -c 'E17C verdict DONE' "$TMP/c.out")" "0/1/1"
  rm -f "$TMP/an/verdict_e17c.py" "$T/e17c/verdict.json"
  check "verdict: no analysis/verdict_e17c.py yet -> a clear failure naming it (Task 7), not a crash" \
    "$(chain -- --from verdict)/$(grep -c 'no .*verdict_e17c.py (Task 7' "$T/e17c/verdict.log")/$([ -f "$T/e17c/verdict.done" ] && echo "done" || echo open)" "1/1/open"
  printf '%s\n' "$VERDICT_STUB" >"$TMP/an/verdict_e17c.py"
  check "verdict: verdict_e17c.py over the runs, at the E17C pin, to \$E15_ROOT/e17c/verdict.json" \
    "$(chain -- --from verdict)/$(sed "s#$T/##g" "$TMP/alog")/$([ -f "$T/e17c/verdict.json" ] && echo written)" \
    "0/verdict_e17c runs --moca-commit $PIN --out e17c/verdict.json/written"
  rm -f "$TMP/an/verdict_e17c.py"
}

test_guards() {
  reset
  seal true
  touch "$TMP/worker-up"
  check "guard: a rung's worker running -> refused before any stage" "$(chain -- --from smoke --to smoke)/$(grep -c 'refusing to preempt it' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  rm -f "$TMP/worker-up"
  printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 0000000000000000000000000000000000000000 >"$TMP/pins0.sh"
  check "guard: the placeholder E17C pin is refused before any stage" \
    "$(chain E15_TEST_PINS="$TMP/pins0.sh" -- --from smoke --to smoke)/$(grep -c 'E17C_MOCA_PIN is still the placeholder' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  check "guard: only the staged copy runs" \
    "$(env E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" PATH="$TMP/stub:$PATH" bash "$RIG/chain-e17c.sh" --list >"$TMP/c.out" 2>&1; echo $?)/$(grep -c 'run the staged copy' "$TMP/c.out")" "1/1"
  check "usage: an unknown stage, or --from after --to, is exit 2, nothing run" \
    "$(chain -- --from nowhere)/$(chain -- --from verdict --to smoke)/$(chain -- --bogus)/$(grep -c . "$CLOG")" "2/2/2/0"
}

test_list
test_refuses_knobs
test_refuses_unsealed
test_bringup_unsealed
test_sealed_stages
test_guards

echo
if [ "$fails" -eq 0 ]; then echo "chain-e17c.test.sh: all checks passed"; else echo "chain-e17c.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
