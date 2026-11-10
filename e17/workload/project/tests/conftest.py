"""Shared setup for the pycache project's tests (E17's py_test command).

WORK_SCALE scales every test's numeric work at once: each test repeats its unit of work
reps(BASE) times, and BASE is chosen so that reps(BASE) takes about 1.5 s at WORK_SCALE = 1.0.
Task 5's calibration tunes the suite to about 60 s at N = 1 on the rig by editing WORK_SCALE alone
(and re-stamping the templates). PYC_WORK_SCALE overrides it for the laptop checks only; the
library's command never sets it.
"""

import os
import sys
import zlib

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

WORK_SCALE = float(os.environ.get("PYC_WORK_SCALE", "1.0"))


def reps(base):
    """How many times a test repeats its unit of work: base scaled by WORK_SCALE, at least 1."""
    return max(1, round(base * WORK_SCALE))


@pytest.fixture
def rng(request):
    """A generator seeded from the test's node id, so every run of a test draws the same data."""
    return np.random.default_rng(zlib.crc32(request.node.nodeid.encode()))
