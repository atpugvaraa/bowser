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
| LRU budget 20 | 39.2 | 20 | 839 | 860 | 2102 | 63 |
| LRU budget 40 | 60.4 | 39 | 1678 | 1720 | 1369 | 53 |
| LRU budget 60 | 74.9 | 59 | 2517 | 2580 | 869 | 39 |
| LRU budget 100 | 88.5 | 97 | 4192 | 4300 | 397 | 16 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 71.8 | 33 | 1412 | 2623 | 977 | 38 |
| **adaptive** min30 def60 cold45 k3 b100 | 76.9 | 41 | 1744 | 3096 | 798 | 31 |
| **adaptive** min30 def60 cold90 k3 b100 | 77.9 | 43 | 1834 | 3268 | 765 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 81.6 | 49 | 2115 | 3741 | 635 | 22 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.5 | 59 | 2520 | 4214 | 537 | 17 |
| **adaptive** min20 def60 cold120 k3 b100 | 75.7 | 41 | 1762 | 3182 | 840 | 34 |
| **adaptive** min30 def120 cold120 k4 b100 | 79.9 | 48 | 2046 | 3612 | 696 | 26 |
| **adaptive** min60 def120 cold240 k4 b100 | 85.2 | 71 | 3037 | 4300 | 511 | 19 |
| **adaptive** min30 def60 cold90 k3 b60 | 71.3 | 38 | 1635 | 2580 | 994 | 41 |
| **adaptive** min45 def90 cold90 k3 b60 | 67.4 | 40 | 1716 | 2580 | 1129 | 49 |