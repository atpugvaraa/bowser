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
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2098 | 63 |
| LRU budget 40 | 60.4 | 39 | 1678 | 1720 | 1368 | 53 |
| LRU budget 60 | 74.9 | 59 | 2517 | 2580 | 868 | 39 |
| LRU budget 100 | 88.5 | 97 | 4192 | 4300 | 397 | 16 |
| **adaptive RELAXED preset** (product default) | 81.9 | 50 | 2163 | 3784 | 627 | 22 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 72.4 | 34 | 1441 | 2666 | 954 | 37 |
| **adaptive** min30 def60 cold45 k3 b100 | 77.3 | 41 | 1761 | 3139 | 786 | 31 |
| **adaptive** min30 def60 cold90 k3 b100 | 78.2 | 44 | 1887 | 3397 | 753 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 81.9 | 50 | 2163 | 3784 | 627 | 22 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.5 | 61 | 2614 | 4300 | 536 | 18 |
| **adaptive** min20 def60 cold120 k3 b100 | 76.4 | 44 | 1888 | 3483 | 817 | 34 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.2 | 50 | 2167 | 3870 | 686 | 27 |
| **adaptive** min60 def120 cold240 k4 b100 | 78.1 | 74 | 3164 | 4300 | 758 | 45 |
| **adaptive** min30 def60 cold90 k3 b60 | 72.8 | 39 | 1669 | 2580 | 941 | 40 |
| **adaptive** min45 def90 cold90 k3 b60 | 72.7 | 41 | 1750 | 2580 | 944 | 41 |