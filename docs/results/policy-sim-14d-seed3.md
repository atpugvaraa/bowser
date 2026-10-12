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
| LRU budget 20 | 39.2 | 20 | 839 | 860 | 2093 | 64 |
| LRU budget 40 | 60.8 | 39 | 1678 | 1720 | 1349 | 53 |
| LRU budget 60 | 75.6 | 59 | 2517 | 2580 | 841 | 38 |
| LRU budget 100 | 88.7 | 97 | 4191 | 4300 | 389 | 15 |
| **adaptive RELAXED preset** (product default) | 81.7 | 48 | 2083 | 3612 | 631 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 71.7 | 33 | 1398 | 2580 | 974 | 39 |
| **adaptive** min30 def60 cold45 k3 b100 | 77.2 | 40 | 1726 | 3053 | 784 | 31 |
| **adaptive** min30 def60 cold90 k3 b100 | 78.1 | 42 | 1802 | 3182 | 753 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 81.7 | 48 | 2083 | 3612 | 631 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.5 | 57 | 2472 | 4128 | 533 | 17 |
| **adaptive** min20 def60 cold120 k3 b100 | 75.7 | 40 | 1712 | 3096 | 836 | 34 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.0 | 46 | 1985 | 3440 | 690 | 26 |
| **adaptive** min60 def120 cold240 k4 b100 | 85.7 | 70 | 3007 | 4300 | 494 | 18 |
| **adaptive** min30 def60 cold90 k3 b60 | 72.3 | 38 | 1630 | 2580 | 953 | 40 |
| **adaptive** min45 def90 cold90 k3 b60 | 68.1 | 40 | 1716 | 2580 | 1098 | 48 |