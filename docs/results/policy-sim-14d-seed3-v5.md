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
| LRU budget 20 | 39.3 | 20 | 839 | 860 | 2090 | 64 |
| LRU budget 40 | 60.9 | 39 | 1678 | 1720 | 1348 | 53 |
| LRU budget 60 | 75.6 | 59 | 2517 | 2580 | 841 | 38 |
| LRU budget 100 | 88.7 | 97 | 4191 | 4300 | 389 | 15 |
| **adaptive RELAXED preset** (product default) | 81.9 | 50 | 2132 | 3698 | 622 | 23 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 72.3 | 33 | 1419 | 2666 | 953 | 38 |
| **adaptive** min30 def60 cold45 k3 b100 | 77.5 | 40 | 1740 | 3096 | 775 | 30 |
| **adaptive** min30 def60 cold90 k3 b100 | 78.5 | 43 | 1855 | 3268 | 742 | 29 |
| **adaptive** min45 def90 cold90 k3 b100 | 81.9 | 50 | 2132 | 3698 | 622 | 23 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.8 | 60 | 2593 | 4300 | 524 | 18 |
| **adaptive** min20 def60 cold120 k3 b100 | 76.6 | 43 | 1869 | 3440 | 807 | 34 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.5 | 50 | 2139 | 3784 | 670 | 26 |
| **adaptive** min60 def120 cold240 k4 b100 | 79.6 | 73 | 3135 | 4300 | 703 | 43 |
| **adaptive** min30 def60 cold90 k3 b60 | 73.5 | 39 | 1660 | 2580 | 913 | 39 |
| **adaptive** min45 def90 cold90 k3 b60 | 73.4 | 41 | 1742 | 2580 | 915 | 40 |