import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pycache_corpus  # noqa: E402

GAPS = os.path.join(HERE, "testdata", "gaps-20.jsonl")
DRIVER = os.path.join(HERE, "..", "..", "e15", "driver")
DRIVER_FIXTURE = os.path.join(DRIVER, "testdata", "pycache-corpus.jsonl")
TURN_HEAD = ["py_analyze", "py_test"]


def gen(tmp_path, duty=0.095, sessions=40, seed=1, name="out", extra=()):
    out = tmp_path / name
    pycache_corpus.main(["--gaps-from", GAPS, "--duty", str(duty), "--sessions", str(sessions),
                         "--seed", str(seed), "--out", str(out), *extra])
    corpus = [json.loads(l) for l in (out / "corpus.jsonl").read_text().splitlines()]
    report = json.loads((out / "corpus-report.json").read_text())
    return out, corpus, report


def turns(classes):
    """Split a session's classes into turns; None when they do not follow the cycle."""
    out, k = [], 0
    while k < len(classes):
        if classes[k:k + 2] != TURN_HEAD:
            return None
        j = k + 2
        while j < len(classes) and classes[j] == "py_short":
            j += 1
        if j >= len(classes) or classes[j] != "py_analyze":
            return None
        out.append(j - k - 2)
        k = j + 1
    return out


def test_turn_order(tmp_path):
    _, corpus, _ = gen(tmp_path, duty=0.015)
    for s in corpus:
        ks = turns([c["class"] for c in s["calls"]])
        assert ks, s["session"]
        assert all(2 <= k <= 5 for k in ks), (s["session"], ks)


def test_seed_is_deterministic(tmp_path):
    a, _, _ = gen(tmp_path, name="a")
    b, _, _ = gen(tmp_path, name="b")
    c, _, _ = gen(tmp_path, seed=2, name="c")
    assert (a / "corpus.jsonl").read_bytes() == (b / "corpus.jsonl").read_bytes()
    assert (a / "corpus.jsonl").read_bytes() != (c / "corpus.jsonl").read_bytes()


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_duty_is_met(tmp_path, duty):
    _, corpus, report = gen(tmp_path, duty=duty)
    assert report["sessions"] == len(corpus) == 40
    assert abs(report["duty_achieved"]["mean"] - duty) <= 0.2 * duty
    # The report's duty is E15's occupied / span, re-measured here from the written calls.
    for s in corpus:
        busy = sum(c["dur_ms"] for c in s["calls"])
        span = busy + sum(c["gap_ms"] for c in s["calls"])
        assert busy / span <= 1.2 * duty, s["session"]


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_min_turns(tmp_path, duty):
    # Spec §4.2: a session is a loop of turns, so warmth across turns is exercised. Default floor 4.
    _, corpus, report = gen(tmp_path, duty=duty)
    counts = []
    for s in corpus:
        ks = turns([c["class"] for c in s["calls"]])
        assert ks and len(ks) >= 4, (s["session"], ks)
        counts.append(len(ks))
    tps = report["turns_per_session"]
    assert (tps["min"], tps["max"]) == (min(counts), max(counts)) and tps["min"] >= 4
    assert tps["median"] == statistics.median(counts)
    spans = report["span_min"]
    assert 0 < spans["min"] <= spans["median"] <= spans["max"]


def test_min_turns_is_a_parameter(tmp_path):
    _, corpus, report = gen(tmp_path, extra=("--min-turns", "6"))
    assert all(len(turns([c["class"] for c in s["calls"]])) >= 6 for s in corpus)
    assert report["min_turns"] == 6


def test_schema_and_timeline(tmp_path):
    _, corpus, report = gen(tmp_path)
    want = {"py_analyze": 15000, "py_test": 60000, "py_short": 300}
    users = set()
    for s in corpus:
        assert set(s) == {"session", "user", "provider", "calls"}
        assert s["provider"] == "synthetic"
        users.add(s["user"])
        calls = s["calls"]
        for n, c in enumerate(calls):
            assert set(c) == {"i", "class", "skeleton", "dur_ms", "work_ms", "gap_ms", "offset_ms",
                              "out_bytes", "chain"}
            assert c["i"] == n and c["chain"] is False
            assert c["dur_ms"] == c["work_ms"] == want[c["class"]]
            # offset_ms is from the previous call's emit (E15's replay timeline adds them up).
            assert c["offset_ms"] == (0 if n == 0 else calls[n - 1]["dur_ms"] + calls[n - 1]["gap_ms"])
        assert calls[-1]["gap_ms"] == 0
    assert users == {"pyc-u%02d" % u for u in range(40)}
    assert sum(report["calls_per_class"].values()) == sum(len(s["calls"]) for s in corpus)
    with open(GAPS, "rb") as f:
        assert report["gap_source_sha256"] == hashlib.sha256(f.read()).hexdigest()


def test_gaps_are_capped(tmp_path):
    for duty in (0.095, 0.015):
        _, corpus, _ = gen(tmp_path, duty=duty, name="d%s" % duty)
        assert max(c["gap_ms"] for s in corpus for c in s["calls"]) <= 1_800_000


def test_unmeetable_duty_fails(tmp_path, capsys):
    with pytest.raises(SystemExit) as e:
        gen(tmp_path, duty=0.0001)
    assert e.value.code not in (0, None)
    assert "duty" in capsys.readouterr().err


def test_schema_loads_in_e15_driver(tmp_path):
    # The committed driver fixture is exactly what the generator writes for these arguments.
    out, _, _ = gen(tmp_path, sessions=3)
    with open(DRIVER_FIXTURE, "rb") as f:
        assert f.read() == (out / "corpus.jsonl").read_bytes()
    if shutil.which("go") is None:
        pytest.skip("go is not on PATH")
    env = dict(os.environ)
    for k, v in (("GOPATH", "/tmp/gopath"), ("GOMODCACHE", "/tmp/gopath/pkg/mod"),
                 ("GOCACHE", "/tmp/gocache")):
        env.setdefault(k, v)
    r = subprocess.run(["go", "test", "-count=1", "-run", "^TestLoadCorpusAcceptsPycache$", "."],
                       cwd=DRIVER, env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no tests to run" not in r.stdout


def test_gaps_already_at_cap_are_scaled_down():
    # A source gap equal to H is a draw like any other: at a high duty it must shrink, not pin the
    # session's idle time at H.
    gaps = pycache_corpus.fit([1_800_000, 1_000], 10_000)
    assert sum(gaps) == 10_000 and max(gaps) < 1_800_000
