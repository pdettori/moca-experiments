# E17 latency (SPEC §7.1)

Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / sbx median).

| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms | cold p95 ms | unknown | sbx median ms | gain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | ship-300-nd | py_analyze | 168 | 16525 | 19973 | 16 | 17687 | 21317 | 0 | - | - |
| pycache | 128 | ship-300-nd | py_grep | 78 | 321 | 2010 | 4 | 2030 | 2043 | 0 | - | - |
| pycache | 128 | ship-300-nd | py_import | 71 | 545 | 997 | 11 | 1219 | 1854 | 0 | - | - |
| pycache | 128 | ship-300-nd | py_short | 284 | 8 | 26 | 41 | 101 | 146 | 0 | - | - |
| pycache | 128 | ship-300-nd | py_test | 75 | 66254 | 67832 | 2 | 66885 | 67962 | 0 | - | - |

## Warm share, first call after idle, call counts

| point | N | arm | warm share | first call after idle n | median ms | p95 ms | calls | used | unknown | not in window | not ok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pycache | 128 | ship-300-nd | 0.901 | 74 | 145 | 19989 | 2121 | 750 | 0 | 1371 | 0 |
