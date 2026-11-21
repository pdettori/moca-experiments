#!/usr/bin/env bash
# experiments/e17-lease/rig/gen_corpora.sh (laptop): generate E17's two pycache corpora with experiments/e17-lease/extract/pycache_corpus.py,
# where experiments/e17-lease/rig/sync.sh stages them from:
#   $E17_CORPORA/pycache/       --duty 0.095   (points pycache, pycache-d64, pycache-d768)
#   $E17_CORPORA/pycache-low/   --duty 0.015   (point pycache-low)
# each with --sessions 400 --seed 1 --min-turns 4 and the gaps of the E15 default corpus
# (E17_GAPS, default /tmp/kagenti/e16-corpus-default/corpus.jsonl, the rig's own by sha256).
# E17_CORPORA defaults to /tmp/kagenti/e17-corpora; E17_PYTHON (default python3) runs the generator.
# E17_TMPFS_SHARE (PLAN-E17B Task 10) is --tmpfs-share: that fraction of the sessions keeps its
# py_analyze/py_test caches in guest tmpfs, and every turn ends with a py_shmem reading. Its default follows the
# profile (final review M3): 0.5 under E17B=1 (the E17b corpora; E17C=1 implies E17B=1, PLAN-E17C Task 4), 0 with
# E17B and E17C unset, so the sealed command still
# writes the E17a corpora byte for byte (corpus_sha256 of results/corpus/*-report.json).
#
#   bash experiments/e17-lease/rig/gen_corpora.sh [--durations-from CAL.json] [--gate-256 GATE.json]
#
# --durations-from CAL.json: a JSON object, each of the five classes (py_analyze, py_test, py_import,
# py_grep, py_short; spec v0.4 §4.3) to its measured N=1 median run_ms (the calibration, PLAN Task 5
# step 4). The corpora then carry those as dur_ms/work_ms, not the 15000/60000/2000/2200/300
# placeholders (ruling: after calibration they must),
# and each corpus-report.json records them (durations_ms, durations_from). Without it the
# placeholders stay, and this script says so. Each corpus directory is replaced whole: written to
# a temporary sibling first, then moved over the old one.
#
# --gate-256 GATE.json (E17C=1 only; PLAN-E17C Task 10, SPEC §13.5 R45): a passing gate-256.json (the rig's
# $E15_RUNS/pycache-d64/gate-256.json, copied back). Also writes $E17_CORPORA/pycache-256/, the corpus of E17c's 256 MiB
# points (pycache-d64, squeeze-256): pycache's arguments, with the durations of --durations-from (or the placeholders)
# but py_analyze at the gate's py_analyze_ms (the chosen scale's sbx median), so it has its own corpus hash. The
# durations go in via a durations-256.json, which its corpus-report.json names. A gate that did not pass is refused
# (exit 1) before anything is written. Under E17C=1 without it, no pycache-256 is written, and this script says so.
set -euo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PC=${E17_CORPORA:-/tmp/kagenti/e17-corpora}
GAPS=${E17_GAPS:-/tmp/kagenti/e16-corpus-default/corpus.jsonl}
PY=${E17_PYTHON:-python3}
if [ "${E17B:-}" = 1 ] || [ "${E17C:-}" = 1 ]; then SHARE=${E17_TMPFS_SHARE:-0.5}; else SHARE=${E17_TMPFS_SHARE:-0}; fi
cal=()
gate=""
while [ $# -gt 0 ]; do
  case "$1" in
  --durations-from)
    if [ $# -lt 2 ] || [ ! -f "$2" ]; then
      echo "gen_corpora.sh: --durations-from needs an existing CAL.json" >&2
      exit 2
    fi
    cal=(--durations-from "$2")
    shift 2
    ;;
  --gate-256)
    if [ "${E17C:-}" != 1 ]; then
      echo "gen_corpora.sh: --gate-256 is E17c's (E17C=1): the 256 MiB points' corpus" >&2
      exit 2
    fi
    if [ $# -lt 2 ] || [ ! -f "$2" ]; then
      echo "gen_corpora.sh: --gate-256 needs an existing GATE.json (gate-256.json)" >&2
      exit 2
    fi
    gate=$2
    shift 2
    ;;
  *)
    echo "usage: gen_corpora.sh [--durations-from CAL.json] [--gate-256 GATE.json]" >&2
    exit 2
    ;;
  esac
done
[ -f "$GAPS" ] || {
  echo "gen_corpora.sh: no gap source $GAPS (E17_GAPS)" >&2
  exit 1
}
specs="pycache:0.095 pycache-low:0.015"
d256=""
if [ -n "$gate" ]; then
  # the gate first: a gate that did not pass writes nothing
  d256=$(mktemp -d)
  trap 'rm -rf -- "$d256"' EXIT
  "$PY" - "$W/experiments/e17-lease/extract" "$gate" "${cal[1]:-}" "$d256/durations-256.json" <<'PY' || exit 1
import json, sys
sys.path.insert(0, sys.argv[1])
import pycache_corpus as P  # noqa: E402
gate, cal, out = sys.argv[2:]
try:
    g = json.load(open(gate))
except (OSError, ValueError) as e:
    sys.exit("gen_corpora.sh: %s is unreadable (%s)" % (gate, e))
ms = g.get("py_analyze_ms") if isinstance(g, dict) else None
if not isinstance(g, dict) or g.get("pass") is not True or not isinstance(ms, (int, float)) or ms <= 0:
    sys.exit("gen_corpora.sh: %s did not pass (%s): no pycache-256 corpus" % (gate, (g or {}).get("reason") if isinstance(g, dict) else "not an object"))
dur = dict(json.load(open(cal))) if cal else dict(P.DUR_MS)
dur["py_analyze"] = ms
json.dump(dur, open(out, "w"), sort_keys=True)
PY
  specs+=" pycache-256:0.095"
fi
mkdir -p "$PC"
for spec in $specs; do
  p=${spec%%:*}
  duty=${spec#*:}
  args=(${cal[@]+"${cal[@]}"})
  [ "$p" != pycache-256 ] || args=(--durations-from "$d256/durations-256.json")
  tmp=$(mktemp -d "$PC/.$p.XXXXXX")
  if ! "$PY" "$W/experiments/e17-lease/extract/pycache_corpus.py" --gaps-from "$GAPS" --duty "$duty" --sessions 400 \
    --seed 1 --min-turns 4 ${args[@]+"${args[@]}"} --tmpfs-share "$SHARE" --out "$tmp"; then
    rm -rf -- "$tmp"
    echo "gen_corpora.sh: pycache_corpus.py failed for $p" >&2
    exit 1
  fi
  # Only the corpus directory itself is replaced: $PC/pycache, $PC/pycache-low or $PC/pycache-256, nothing above.
  rm -rf -- "${PC:?}/$p"
  mv "$tmp" "$PC/$p"
  "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); print("%s: duty %.4f (target %s), %d sessions (%d tmpfs, share %s), durations_ms %s, corpus_sha256 %s" % (sys.argv[2], r["duty_achieved"]["mean"], r["duty_target"], r["sessions"], r["tmpfs_sessions"], r["tmpfs_share"], r["durations_ms"], r["corpus_sha256"]))' \
    "$PC/$p/corpus-report.json" "$p"
done
if [ "${E17C:-}" = 1 ] && [ -z "$gate" ]; then
  echo "gen_corpora.sh: note: no pycache-256 corpus (E17c's 256 MiB points): re-run with --gate-256 GATE.json once gate-256 passed" >&2
fi
[ ${#cal[@]} -gt 0 ] || echo "gen_corpora.sh: note: placeholder durations (no --durations-from); re-run with the calibration's before the measured rungs" >&2
