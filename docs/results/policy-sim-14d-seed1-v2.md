# Policy simulation — 500 tabs, 14 days, seed 1, 48428 tab activations
Model: 25 hot / 100 warm / 375 cold tabs, waking hours 08-24, project bursts every 3 days. Live tab ≈ 43 MB (measured), restore ≈ 110 ms (measured). Policy pass every 5 sim-minutes.

| policy | live-hit % | avg live tabs | avg live MB | p95 live MB | restores/day | premature (<30 min) % |
|---|---|---|---|---|---|---|
| fixed idle 5 min | 30.0 | 9 | 382 | 817 | 2421 | 66 |
| fixed idle 15 min | 56.0 | 24 | 1025 | 1892 | 1521 | 55 |
| fixed idle 30 min | 72.8 | 37 | 1599 | 2881 | 940 | 39 |
| fixed idle 60 min | 83.1 | 53 | 2263 | 3913 | 583 | 20 |
| fixed idle 120 min | 88.2 | 73 | 3118 | 5117 | 409 | 10 |
| fixed idle 240 min | 91.6 | 100 | 4314 | 6622 | 291 | 6 |
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2101 | 63 |
| LRU budget 40 | 60.4 | 39 | 1678 | 1720 | 1369 | 53 |
| LRU budget 60 | 74.9 | 59 | 2517 | 2580 | 869 | 39 |
| LRU budget 100 | 88.5 | 97 | 4192 | 4300 | 397 | 16 |
| **adaptive** grace 60 min + budget 100 | 71.8 | 33 | 1412 | 2623 | 977 | 38 |
| **adaptive** grace 60 min + budget 60 | 71.3 | 33 | 1399 | 2580 | 993 | 39 |
| **adaptive** grace 60 min + budget 40 | 58.5 | 26 | 1114 | 1720 | 1436 | 53 |
| **adaptive** grace 30 min + budget 60 | 71.4 | 32 | 1396 | 2580 | 990 | 39 |
| **adaptive** grace 30 min + budget 40 | 58.6 | 26 | 1114 | 1720 | 1432 | 53 |
| **adaptive** grace 20 min + budget 30 | 47.4 | 21 | 884 | 1290 | 1820 | 60 |