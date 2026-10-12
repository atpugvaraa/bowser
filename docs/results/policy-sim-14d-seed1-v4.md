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
| LRU budget 20 | 39.4 | 20 | 839 | 860 | 2098 | 63 |
| LRU budget 40 | 60.4 | 39 | 1678 | 1720 | 1370 | 53 |
| LRU budget 60 | 74.9 | 59 | 2517 | 2580 | 868 | 39 |
| LRU budget 100 | 88.5 | 97 | 4192 | 4300 | 397 | 16 |
| **adaptive RELAXED preset** (product default) | 82.7 | 56 | 2423 | 4257 | 597 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 73.4 | 35 | 1502 | 2795 | 919 | 36 |
| **adaptive** min30 def60 cold45 k3 b100 | 77.8 | 42 | 1807 | 3225 | 768 | 30 |
| **adaptive** min30 def60 cold90 k3 b100 | 79.6 | 51 | 2181 | 3999 | 706 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 82.7 | 56 | 2423 | 4257 | 597 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 83.2 | 67 | 2901 | 4300 | 581 | 28 |
| **adaptive** min20 def60 cold120 k3 b100 | 78.1 | 56 | 2396 | 4300 | 759 | 37 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.7 | 61 | 2617 | 4300 | 666 | 32 |
| **adaptive** min60 def120 cold240 k4 b100 | 73.2 | 77 | 3293 | 4300 | 926 | 56 |
| **adaptive** min30 def60 cold90 k3 b60 | 67.9 | 41 | 1783 | 2580 | 1109 | 49 |
| **adaptive** min45 def90 cold90 k3 b60 | 67.7 | 43 | 1841 | 2580 | 1117 | 50 |