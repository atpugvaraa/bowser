# Policy simulation — 500 tabs, 14 days, seed 2, 48214 tab activations
Model: 25 hot / 100 warm / 375 cold tabs, waking hours 08-24, project bursts every 3 days. Live tab ≈ 43 MB (measured), restore ≈ 110 ms (measured). Policy pass every 5 sim-minutes.

| policy | live-hit % | avg live tabs | avg live MB | p95 live MB | restores/day | premature (<30 min) % |
|---|---|---|---|---|---|---|
| fixed idle 5 min | 30.3 | 9 | 380 | 774 | 2402 | 67 |
| fixed idle 15 min | 56.2 | 24 | 1019 | 1892 | 1508 | 55 |
| fixed idle 30 min | 73.2 | 37 | 1585 | 2838 | 923 | 39 |
| fixed idle 60 min | 83.5 | 52 | 2237 | 3870 | 568 | 20 |
| fixed idle 120 min | 88.3 | 71 | 3074 | 5031 | 403 | 10 |
| fixed idle 240 min | 91.6 | 99 | 4255 | 6450 | 289 | 7 |
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2090 | 64 |
| LRU budget 40 | 60.9 | 39 | 1678 | 1720 | 1345 | 53 |
| LRU budget 60 | 75.5 | 59 | 2517 | 2580 | 843 | 40 |
| LRU budget 100 | 88.8 | 97 | 4191 | 4300 | 385 | 15 |
| **adaptive RELAXED preset** (product default) | 83.0 | 55 | 2374 | 4171 | 585 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 73.7 | 34 | 1481 | 2795 | 905 | 37 |
| **adaptive** min30 def60 cold45 k3 b100 | 78.2 | 41 | 1780 | 3182 | 751 | 31 |
| **adaptive** min30 def60 cold90 k3 b100 | 79.8 | 49 | 2123 | 3784 | 696 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 83.0 | 55 | 2374 | 4171 | 585 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.3 | 66 | 2854 | 4300 | 542 | 24 |
| **adaptive** min20 def60 cold120 k3 b100 | 78.5 | 54 | 2320 | 4257 | 741 | 36 |
| **adaptive** min30 def120 cold120 k4 b100 | 81.6 | 59 | 2557 | 4300 | 632 | 29 |
| **adaptive** min60 def120 cold240 k4 b100 | 74.2 | 75 | 3243 | 4300 | 889 | 55 |
| **adaptive** min30 def60 cold90 k3 b60 | 69.7 | 41 | 1770 | 2580 | 1042 | 47 |
| **adaptive** min45 def90 cold90 k3 b60 | 69.5 | 43 | 1833 | 2580 | 1050 | 48 |