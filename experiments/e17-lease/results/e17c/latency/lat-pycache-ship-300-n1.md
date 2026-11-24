# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | ship-300 | py_analyze | 7 | 14919 | 16562 | 1 | 16826 | 16826 | 0 | - | - |
| pycache | 1 | ship-300 | py_grep | 1 | 289 | 289 | 0 | - | - | 0 | - | - |
| pycache | 1 | ship-300 | py_import | 1 | 453 | 453 | 0 | - | - | 0 | - | - |
| pycache | 1 | ship-300 | py_short | 7 | 10 | 16 | 2 | 112 | 125 | 0 | - | - |
| pycache | 1 | ship-300 | py_test | 3 | 61153 | 61266 | 2 | 61499 | 61539 | 0 | - | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | ship-300 | 0.792 | 5 | 16826 | 61539 | 63 | 24 | 0 | 39 | 0 |

## Warm calls by the guest's page-cache drop

Warm calls whose session's previous call ended more than the rung's lease_cache_drop before (after drop) and the rest (kept). Reported beside the gain, which stays over all warm calls.

| point | N | arm | class | after drop n | after drop median ms | kept n | kept median ms | after drop / kept |
|---|---|---|---|---|---|---|---|---|
| pycache | 1 | ship-300 | py_analyze | 2 | 14953 | 5 | 14853 | 1.01 |
| pycache | 1 | ship-300 | py_grep | 0 | - | 1 | 289 | - |
| pycache | 1 | ship-300 | py_import | 0 | - | 1 | 453 | - |
| pycache | 1 | ship-300 | py_short | 4 | 13 | 3 | 8 | 1.60 |
| pycache | 1 | ship-300 | py_test | 1 | 60917 | 2 | 61210 | 1.00 |
