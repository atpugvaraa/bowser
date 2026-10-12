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
| LRU budget 20 | 39.4 | 20 | 839 | 860 | 2089 | 64 |
| LRU budget 40 | 61.0 | 39 | 1678 | 1720 | 1343 | 53 |
| LRU budget 60 | 75.6 | 59 | 2517 | 2580 | 842 | 39 |
| LRU budget 100 | 88.8 | 97 | 4191 | 4300 | 385 | 15 |
| **adaptive RELAXED preset** (product default) | 82.1 | 49 | 2126 | 3741 | 615 | 22 |
| **adaptive** default (min15 def60 cold45 k3 b100) | 72.6 | 33 | 1426 | 2666 | 944 | 39 |
| **adaptive** min30 def60 cold45 k3 b100 | 77.6 | 40 | 1740 | 3139 | 770 | 31 |
| **adaptive** min30 def60 cold90 k3 b100 | 78.5 | 43 | 1857 | 3311 | 739 | 30 |
| **adaptive** min45 def90 cold90 k3 b100 | 82.1 | 49 | 2126 | 3741 | 615 | 22 |
| **adaptive** min60 def90 cold120 k4 b100 | 84.8 | 60 | 2567 | 4300 | 522 | 17 |
| **adaptive** min20 def60 cold120 k3 b100 | 76.6 | 43 | 1846 | 3354 | 807 | 35 |
| **adaptive** min30 def120 cold120 k4 b100 | 80.5 | 49 | 2113 | 3698 | 670 | 27 |
| **adaptive** min60 def120 cold240 k4 b100 | 79.9 | 72 | 3091 | 4300 | 692 | 41 |
| **adaptive** min30 def60 cold90 k3 b60 | 73.7 | 39 | 1659 | 2580 | 905 | 39 |
| **adaptive** min45 def90 cold90 k3 b60 | 73.8 | 40 | 1741 | 2580 | 904 | 40 |