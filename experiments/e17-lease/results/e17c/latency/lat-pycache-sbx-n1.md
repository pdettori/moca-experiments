# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | py_analyze | 0 | - | - | 8 | 16193 | 16925 | 0 | 16193 | - |
| pycache | 1 | sbx | py_grep | 0 | - | - | 1 | 397 | 397 | 0 | 397 | - |
| pycache | 1 | sbx | py_import | 0 | - | - | 1 | 778 | 778 | 0 | 778 | - |
| pycache | 1 | sbx | py_short | 0 | - | - | 9 | 55 | 93 | 0 | 55 | - |
| pycache | 1 | sbx | py_test | 0 | - | - | 5 | 62133 | 63548 | 0 | 62133 | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | sbx | 0.000 | 0 | - | - | 67 | 24 | 0 | 43 | 0 |
