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
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2092 | 64 |
| LRU budget 40 | 60.8 | 39 | 1678 | 1720 | 1350 | 53 |
| LRU budget 60 | 75.6 | 59 | 2517 | 2580 | 842 | 38 |
| LRU budget 100 | 88.7 | 97 | 4191 | 4300 | 389 | 15 |
| **adaptive RELAXED preset** (product default) | 83.0 | 56 | 2415 | 4214 | 587 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 73.4 | 34 | 1480 | 2752 | 915 | 36 |
| **adaptive** min30 def60 cold45 k3 b100 | 78.1 | 41 | 1784 | 3182 | 756 | 30 |
| **adaptive** min30 def60 cold90 k3 b100 | 79.9 | 50 | 2168 | 3913 | 694 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 83.0 | 56 | 2415 | 4214 | 587 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 83.9 | 68 | 2906 | 4300 | 556 | 26 |
| **adaptive** min20 def60 cold120 k3 b100 | 78.2 | 55 | 2384 | 4300 | 752 | 37 |
| **adaptive** min30 def120 cold120 k4 b100 | 81.3 | 61 | 2612 | 4300 | 644 | 30 |
| **adaptive** min60 def120 cold240 k4 b100 | 74.2 | 76 | 3276 | 4300 | 888 | 55 |
| **adaptive** min30 def60 cold90 k3 b60 | 68.5 | 41 | 1782 | 2580 | 1085 | 49 |
| **adaptive** min45 def90 cold90 k3 b60 | 68.1 | 43 | 1836 | 2580 | 1101 | 50 |