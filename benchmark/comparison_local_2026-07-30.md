# Local comparison run — 2026-07-30 (superseded by the HPC run)

**Do not publish these ratios.** Generated from `results_full_branch_w4.csv`
(branch, single undisturbed process) and `results_full_is4_p1..p4.csv` (IS4,
split across 4 concurrent processes on the same laptop). The two sides were
measured under different machine load, which inflates the branch's advantage
on read-heavy paths — read speedups here run ~3x the values the more
symmetric 2026-07-29 campaign measured. Metadata-bound ops (has_ts, dst
transform) are largely unaffected.

Kept as a shape check for the HPC run, not as a result.

- Machine: Apple M3 Max, 14 cores (10P/4E), 36 GB, macOS 26.6, Julia 1.12.6
- Branch: IS `f3eceb1f` + infrastore `f0c075e` (v0.4.0), release build
- IS4: `c63d9a281` + PR #594 cherry-pick
- N = 100,000 series; IS4 `remove` not run (never completes at this scale)

| kind | eltype | op | n | infrastore (µs/op) | is4 (µs/op) | speedup |
|---|---|---|---:|---:|---:|---:|
| sts | float64 | bulk_add | 100000 | 10.6 | 94.9 | 8.97× |
| sts | float64 | get_full | 100000 | 80.5 | 5214 | 64.8× |
| sts | float64 | get_sliced | 100000 | 73.8 | 5607 | 76.0× |
| sts | float64 | read_by_timestamp | 2400000 | 1.07 | 526 | 492× |
| sts | ntuple2 | bulk_add | 100000 | 10.4 | 105 | 10.1× |
| sts | ntuple2 | get_full | 100000 | 89.6 | 1584 | 17.7× |
| sts | ntuple2 | get_sliced | 100000 | 81.0 | 1468 | 18.1× |
| sts | linear | bulk_add | 100000 | 10.2 | 105 | 10.2× |
| sts | linear | get_full | 100000 | 88.6 | 2540 | 28.7× |
| sts | linear | get_sliced | 100000 | 79.6 | 2035 | 25.6× |
| sts | quadratic | bulk_add | 100000 | 11.1 | 93.0 | 8.35× |
| sts | quadratic | get_full | 100000 | 90.1 | 1695 | 18.8× |
| sts | quadratic | get_sliced | 100000 | 83.8 | 1899 | 22.7× |
| sts | pwl | bulk_add | 100000 | 13.6 | 98.4 | 7.26× |
| sts | pwl | get_full | 100000 | 97.5 | 1183 | 12.1× |
| sts | pwl | get_sliced | 100000 | 86.0 | 1098 | 12.8× |
| nst | float64 | bulk_add | 100000 | 33.8 | not_supported_on_branch | — |
| nst | float64 | get_full | 100000 | 89.1 | — | — |
| nst | ntuple2 | bulk_add | 100000 | 36.3 | not_supported_on_branch | — |
| nst | ntuple2 | get_full | 100000 | 94.6 | — | — |
| nst | linear | bulk_add | 100000 | 35.4 | not_supported_on_branch | — |
| nst | linear | get_full | 100000 | 92.6 | — | — |
| nst | quadratic | bulk_add | 100000 | 37.2 | not_supported_on_branch | — |
| nst | quadratic | get_full | 100000 | 95.6 | — | — |
| nst | pwl | bulk_add | 100000 | 43.4 | not_supported_on_branch | — |
| nst | pwl | get_full | 100000 | 99.1 | — | — |
| det | float64 | bulk_add | 100000 | 44.3 | 123 | 2.79× |
| det | float64 | get_full | 100000 | 98.5 | 638 | 6.47× |
| det | float64 | get_window | 100000 | 81.9 | 618 | 7.54× |
| det | float64 | read_by_window | 1200000 | 4.06 | 1014 | 250× |
| det | ntuple2 | bulk_add | 100000 | 52.2 | 141 | 2.7× |
| det | ntuple2 | get_full | 100000 | 118 | 1086 | 9.22× |
| det | ntuple2 | get_window | 100000 | 85.4 | 1012 | 11.9× |
| det | linear | bulk_add | 100000 | 50.4 | 137 | 2.73× |
| det | linear | get_full | 100000 | 113 | 1068 | 9.45× |
| det | linear | get_window | 100000 | 86.2 | 999 | 11.6× |
| det | quadratic | bulk_add | 100000 | 54.2 | 137 | 2.53× |
| det | quadratic | get_full | 100000 | 112 | 1087 | 9.67× |
| det | quadratic | get_window | 100000 | 86.7 | 1048 | 12.1× |
| det | pwl | bulk_add | 100000 | 95.3 | 1139 | 11.9× |
| det | pwl | get_full | 100000 | 135 | 1148 | 8.51× |
| det | pwl | get_window | 100000 | 87.1 | 921 | 10.6× |
| prob | float64 | bulk_add | 100000 | 59.2 | 115 | 1.94× |
| prob | float64 | get_full | 100000 | 117 | 1173 | 10.0× |
| prob | float64 | get_window | 100000 | 83.1 | 1122 | 13.5× |
| scen | float64 | bulk_add | 100000 | 60.3 | 116 | 1.92× |
| scen | float64 | get_full | 100000 | 112 | 1350 | 12.1× |
| scen | float64 | get_window | 100000 | 81.7 | 1332 | 16.3× |
| dst | float64 | transform | 100000 | 20.7 | 15.9 | 0.772× |
| dst | float64 | get_window | 100000 | 102 | 8933 | 87.3× |
| dst | float64 | read_by_window | 1300000 | 14.7 | 1208 | 82.4× |
| sts_shared | float64 | bulk_add | 100000 | 7.83 | 12.9 | 1.64× |
| sts_shared | float64 | get_full | 100000 | 76.3 | 1255 | 16.5× |
| sts_shared | float64 | get_sliced | 100000 | 76.1 | 1283 | 16.9× |
| sts_shared | float64 | read_by_timestamp | 2400000 | 1.01 | 105 | 103× |
| det_shared | float64 | bulk_add | 100000 | 15.9 | 19.9 | 1.25× |
| det_shared | float64 | get_full | 100000 | 83.5 | 1273 | 15.2× |
| det_shared | float64 | get_window | 100000 | 81.1 | 1276 | 15.7× |
| det_shared | float64 | read_by_window | 1200000 | 1.72 | 213 | 124× |
| has_ts | float64 | bulk_add | 100000 | 9.2 | 26.8 | 2.91× |
| has_ts | float64 | has_hit | 100000 | 3.73 | 3.47 | 0.931× |
| has_ts | float64 | has_miss | 100000 | 8.39 | 14.0 | 1.67× |
| serialize | float64 | to_json | 100000 | 2.32 | 38.2 | 16.5× |
| serialize | float64 | from_json | 100000 | 13.1 | 60.1 | 4.58× |
| serialize | float64 | reload_read_one | 1 | 1034 | 5619 | 5.43× |
| remove | float64 | remove_all | 100000 | 79.3 | — | — |

| kind | eltype | infrastore disk (MB) | is4 disk (MB) |
|---|---|---:|---:|
| sts | float64 | 112 | 80.8 |
| sts | ntuple2 | 130 | 101 |
| sts | linear | 132 | 101 |
| sts | quadratic | 152 | 123 |
| sts | pwl | 298 | 246 |
| nst | float64 | 260 | — |
| nst | ntuple2 | 279 | — |
| nst | linear | 279 | — |
| nst | quadratic | 297 | — |
| nst | pwl | 444 | — |
| det | float64 | 231 | 171 |
| det | ntuple2 | 347 | 281 |
| det | linear | 349 | 282 |
| det | quadratic | 459 | 392 |
| det | pwl | 1338 | 1161 |
| prob | float64 | 677 | 610 |
| scen | float64 | 671 | 610 |
| sts_shared | float64 | 87.5 | 0.00264 |
| det_shared | float64 | 86.9 | 0.00355 |
| serialize | float64 | 83.6 | 113 |
