# Policy simulation — 500 tabs, 14 days, seed 3, 48227 tab activations
Model: 25 hot / 100 warm / 375 cold tabs, waking hours 08-24, project bursts every 3 days. Live tab ≈ 43 MB (measured), restore ≈ 110 ms (measured). Policy pass every 5 sim-minutes.

| policy | live-hit % | avg live tabs | avg live MB | p95 live MB | restores/day | premature (<30 min) % |
|---|---|---|---|---|---|---|
| fixed idle 5 min | 30.3 | 9 | 381 | 774 | 2402 | 66 |
| fixed idle 15 min | 56.2 | 24 | 1019 | 1892 | 1510 | 55 |
| fixed idle 30 min | 73.2 | 37 | 1587 | 2838 | 923 | 38 |
| fixed idle 60 min | 83.3 | 52 | 2244 | 3870 | 577 | 20 |
| fixed idle 120 min | 88.2 | 72 | 3093 | 5074 | 407 | 11 |
| fixed idle 240 min | 91.6 | 99 | 4278 | 6493 | 289 | 6 |
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2093 | 64 |
| LRU budget 40 | 60.8 | 39 | 1678 | 1720 | 1350 | 53 |
| LRU budget 60 | 75.6 | 59 | 2517 | 2580 | 841 | 38 |
| LRU budget 100 | 88.7 | 97 | 4191 | 4300 | 389 | 15 |
| **adaptive RELAXED preset** (product default) | 83.1 | 58 | 2509 | 4257 | 583 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 74.0 | 36 | 1542 | 2795 | 894 | 35 |
| **adaptive** min30 def60 cold45 k3 b100 | 78.4 | 43 | 1844 | 3225 | 745 | 29 |
| **adaptive** min30 def60 cold90 k3 b100 | 80.1 | 53 | 2267 | 3913 | 684 | 29 |
| **adaptive** min45 def90 cold90 k3 b100 | 83.1 | 58 | 2509 | 4257 | 583 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 83.7 | 70 | 2996 | 4300 | 561 | 27 |
| **adaptive** min20 def60 cold120 k3 b100 | 78.6 | 57 | 2463 | 4300 | 736 | 36 |
| **adaptive** min30 def120 cold120 k4 b100 | 81.4 | 63 | 2712 | 4300 | 640 | 30 |
| **adaptive** min60 def120 cold240 k4 b100 | 73.5 | 76 | 3253 | 4300 | 914 | 57 |
| **adaptive** min30 def60 cold90 k3 b60 | 68.7 | 43 | 1831 | 2580 | 1079 | 49 |
| **adaptive** min45 def90 cold90 k3 b60 | 68.1 | 44 | 1876 | 2580 | 1100 | 50 |