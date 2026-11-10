"""Constants shared by analyze.py, the package and the tests.

The shard format is build_pycache_workspace.sh's: a header line, then fixed-width rows of one
group id and six values, each "dd.ddd". The py_short `edit` command rewrites MAX_ITER and puts it
back in the same command, so keep that line exactly as it is.
"""

DATA_DIR = "../data"
SHARD_GLOB = "shard-*.csv"
COLUMNS = ("g", "x0", "x1", "x2", "x3", "x4", "x5")
VALUE_COLUMNS = COLUMNS[1:]
HEADER_BYTES = len(",".join(COLUMNS)) + 1
ROW_BYTES = 2 + 7 * len(VALUE_COLUMNS) + 1  # "gg" then ",dd.ddd" per value, "\n"
N_GROUPS = 100  # g is two digits, 00..99

SAMPLE_ROWS = 200_000
N_CLUSTERS = 8
N_INIT = 1
RANDOM_STATE = 0
MAX_ITER = 300
TOLERANCE = 1e-4
