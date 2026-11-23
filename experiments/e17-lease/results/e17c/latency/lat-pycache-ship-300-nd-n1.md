# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | ship-300-nd | py_analyze | 7 | 14608 | 17582 | 1 | 16725 | 16725 | 0 | - | - |
| pycache | 1 | ship-300-nd | py_grep | 1 | 376 | 376 | 0 | - | - | 0 | - | - |
| pycache | 1 | ship-300-nd | py_import | 1 | 453 | 453 | 0 | - | - | 0 | - | - |
| pycache | 1 | ship-300-nd | py_short | 7 | 10 | 11 | 2 | 116 | 132 | 0 | - | - |
| pycache | 1 | ship-300-nd | py_test | 3 | 60971 | 61095 | 2 | 61888 | 62133 | 0 | - | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 1 | ship-300-nd | 0.792 | 5 | 16725 | 62133 | 63 | 24 | 0 | 39 | 0 |
