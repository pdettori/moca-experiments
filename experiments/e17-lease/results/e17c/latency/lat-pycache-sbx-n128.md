# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | sbx | py_analyze | 0 | - | - | 192 | 18912 | 21525 | 0 | 18912 | - |
| pycache | 128 | sbx | py_grep | 0 | - | - | 87 | 1694 | 2369 | 0 | 1694 | - |
| pycache | 128 | sbx | py_import | 0 | - | - | 86 | 929 | 2154 | 0 | 929 | - |
| pycache | 128 | sbx | py_short | 0 | - | - | 326 | 63 | 114 | 0 | 63 | - |
| pycache | 128 | sbx | py_test | 0 | - | - | 84 | 68522 | 71442 | 0 | 68522 | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | sbx | 0.000 | 0 | - | - | 2301 | 775 | 0 | 1526 | 0 |
