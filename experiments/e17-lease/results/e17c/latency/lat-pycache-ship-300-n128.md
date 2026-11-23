# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | ship-300 | py_analyze | 168 | 16673 | 19535 | 16 | 17565 | 20958 | 0 | - | - |
| pycache | 128 | ship-300 | py_grep | 78 | 314 | 2000 | 4 | 1999 | 2054 | 0 | - | - |
| pycache | 128 | ship-300 | py_import | 72 | 565 | 994 | 11 | 971 | 1516 | 0 | - | - |
| pycache | 128 | ship-300 | py_short | 284 | 9 | 30 | 41 | 104 | 149 | 0 | - | - |
| pycache | 128 | ship-300 | py_test | 75 | 66169 | 67967 | 2 | 66821 | 67999 | 0 | - | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | ship-300 | 0.901 | 74 | 135 | 19786 | 2123 | 751 | 0 | 1372 | 0 |

## Warm calls by the guest's page-cache drop

Warm calls whose session's previous call ended more than the rung's lease_cache_drop before (after drop) and the rest (kept). Reported beside the gain, which stays over all warm calls.

| point | N | arm | class | after drop n | after drop median ms | kept n | kept median ms | after drop / kept |
|---|---|---|---|---|---|---|---|---|
| pycache | 128 | ship-300 | py_analyze | 59 | 16708 | 109 | 16653 | 1.00 |
| pycache | 128 | ship-300 | py_grep | 27 | 306 | 51 | 339 | 0.90 |
| pycache | 128 | ship-300 | py_import | 16 | 666 | 56 | 549 | 1.21 |
| pycache | 128 | ship-300 | py_short | 103 | 10 | 181 | 8 | 1.32 |
| pycache | 128 | ship-300 | py_test | 26 | 65999 | 49 | 66314 | 1.00 |
