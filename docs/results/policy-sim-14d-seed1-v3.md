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
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2099 | 63 |
| LRU budget 40 | 60.5 | 39 | 1678 | 1720 | 1367 | 53 |
| LRU budget 60 | 74.9 | 59 | 2517 | 2580 | 870 | 39 |
| LRU budget 100 | 88.5 | 97 | 4192 | 4300 | 397 | 16 |
| **adaptive RELAXED preset** (product default) | 82.7 | 58 | 2505 | 4300 | 598 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 74.1 | 36 | 1556 | 2838 | 896 | 35 |
| **adaptive** min30 def60 cold45 k3 b100 | 78.2 | 43 | 1858 | 3268 | 755 | 29 |
| **adaptive** min30 def60 cold90 k3 b100 | 79.8 | 53 | 2268 | 4042 | 700 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 82.7 | 58 | 2505 | 4300 | 598 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 83.1 | 69 | 2977 | 4300 | 585 | 28 |
| **adaptive** min20 def60 cold120 k3 b100 | 78.4 | 57 | 2464 | 4300 | 746 | 36 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.9 | 63 | 2705 | 4300 | 662 | 32 |
| **adaptive** min60 def120 cold240 k4 b100 | 72.7 | 76 | 3272 | 4300 | 946 | 57 |
| **adaptive** min30 def60 cold90 k3 b60 | 68.1 | 42 | 1826 | 2580 | 1105 | 49 |
| **adaptive** min45 def90 cold90 k3 b60 | 67.5 | 44 | 1883 | 2580 | 1123 | 50 |