| kind | eltype | op | n | infrastore (µs/op) | is4 (µs/op) | speedup |
|---|---|---|---:|---:|---:|---:|
| sts | float64 | bulk_add | 100000 | 11.9 | 98.9 | 8.31× |
| sts | float64 | get_full | 100000 | 57.2 | 1678 | 29.3× |
| sts | float64 | get_sliced | 100000 | 50.1 | 1678 | 33.5× |
| sts | float64 | read_by_timestamp | 2400000 | 1.33 | 704 | 529× |
| sts | ntuple2 | bulk_add | 100000 | 13.2 | 112 | 8.48× |
| sts | ntuple2 | get_full | 100000 | 65.1 | 2233 | 34.3× |
| sts | ntuple2 | get_sliced | 100000 | 55.0 | 2233 | 40.6× |
| sts | linear | bulk_add | 100000 | 13.0 | 106 | 8.21× |
| sts | linear | get_full | 100000 | 63.2 | 1863 | 29.5× |
| sts | linear | get_sliced | 100000 | 53.3 | 1861 | 34.9× |
| sts | quadratic | bulk_add | 100000 | 13.4 | 109 | 8.09× |
| sts | quadratic | get_full | 100000 | 63.9 | 2233 | 35.0× |
| sts | quadratic | get_sliced | 100000 | 53.7 | 2230 | 41.5× |
| sts | pwl | bulk_add | 100000 | 21.2 | 132 | 6.23× |
| sts | pwl | get_full | 100000 | 83.1 | 3847 | 46.3× |
| sts | pwl | get_sliced | 100000 | 62.7 | 4799 | 76.5× |
| nst | float64 | bulk_add | 100000 | 37.2 | not_supported_on_branch | — |
| nst | float64 | get_full | 100000 | 68.1 | — | — |
| nst | ntuple2 | bulk_add | 100000 | 44.6 | not_supported_on_branch | — |
| nst | ntuple2 | get_full | 100000 | 76.7 | — | — |
| nst | linear | bulk_add | 100000 | 44.0 | not_supported_on_branch | — |
| nst | linear | get_full | 100000 | 73.1 | — | — |
| nst | quadratic | bulk_add | 100000 | 44.5 | not_supported_on_branch | — |
| nst | quadratic | get_full | 100000 | 74.1 | — | — |
| nst | pwl | bulk_add | 100000 | 52.3 | not_supported_on_branch | — |
| nst | pwl | get_full | 100000 | 86.3 | — | — |
| det | float64 | bulk_add | 100000 | 50.8 | 137 | 2.7× |
| det | float64 | get_full | 100000 | 88.3 | 2188 | 24.8× |
| det | float64 | get_window | 100000 | 55.1 | 2165 | 39.3× |
| det | float64 | read_by_window | 1200000 | 5.42 | 1516 | 280× |
| det | ntuple2 | bulk_add | 100000 | 68.7 | 160 | 2.33× |
| det | ntuple2 | get_full | 100000 | 126 | 2565 | 20.3× |
| det | ntuple2 | get_window | 100000 | 64.5 | 2086 | 32.3× |
| det | linear | bulk_add | 100000 | 66.2 | 157 | 2.37× |
| det | linear | get_full | 100000 | 108 | 2076 | 19.2× |
| det | linear | get_window | 100000 | 62.5 | 1999 | 32.0× |
| det | quadratic | bulk_add | 100000 | 72.1 | 162 | 2.25× |
| det | quadratic | get_full | 100000 | 111 | 3260 | 29.4× |
| det | quadratic | get_window | 100000 | 61.3 | 3173 | 51.8× |
| det | pwl | bulk_add | 100000 | 126 | 1423 | 11.3× |
| det | pwl | get_full | 100000 | 167 | 4992 | 29.8× |
| det | pwl | get_window | 100000 | 72.3 | 4693 | 64.9× |
| prob | float64 | bulk_add | 100000 | 74.8 | 139 | 1.86× |
| prob | float64 | get_full | 100000 | 120 | 5054 | 42.0× |
| prob | float64 | get_window | 100000 | 61.1 | 5009 | 82.0× |
| scen | float64 | bulk_add | 100000 | 74.0 | 138 | 1.86× |
| scen | float64 | get_full | 100000 | 119 | 5484 | 46.0× |
| scen | float64 | get_window | 100000 | 60.6 | 5438 | 89.7× |
| dst | float64 | transform | 100000 | 10.4 | 20.6 | 1.97× |
| dst | float64 | get_window | 100000 | 84.8 | 20245 | 239× |
| dst | float64 | read_by_window | 1300000 | 15.1 | 2814 | 187× |
| sts_shared | float64 | bulk_add | 100000 | 8.43 | 14.8 | 1.75× |
| sts_shared | float64 | get_full | 100000 | 47.8 | 7209 | 151× |
| sts_shared | float64 | get_sliced | 100000 | 48.3 | 7249 | 150× |
| sts_shared | float64 | read_by_timestamp | 2400000 | 1.25 | 609 | 488× |
| det_shared | float64 | bulk_add | 100000 | 22.8 | 24.7 | 1.08× |
| det_shared | float64 | get_full | 100000 | 61.1 | 6007 | 98.3× |
| det_shared | float64 | get_window | 100000 | 55.2 | 5985 | 108× |
| det_shared | float64 | read_by_window | 1200000 | 2.02 | 1467 | 725× |
| has_ts | float64 | bulk_add | 100000 | 12.1 | 30.7 | 2.54× |
| has_ts | float64 | has_hit | 100000 | 4.81 | 4.59 | 0.954× |
| has_ts | float64 | has_miss | 100000 | 10.8 | 17.6 | 1.64× |
| serialize | float64 | to_json | 100000 | 5.04 | 50.5 | 10.0× |
| serialize | float64 | from_json | 100000 | 15.9 | 89.9 | 5.64× |
| serialize | float64 | reload_read_one | 1 | 1614 | 28678 | 17.8× |
| remove | float64 | remove_all | 100000 | 37.6 | — | — |

| kind | eltype | infrastore disk (MB) | is4 disk (MB) |
|---|---|---:|---:|
| sts | float64 | 106 | 80.8 |
| sts | ntuple2 | 126 | 101 |
| sts | linear | 127 | 101 |
| sts | quadratic | 146 | 124 |
| sts | pwl | 292 | 246 |
| nst | float64 | 158 | — |
| nst | ntuple2 | 179 | — |
| nst | linear | 179 | — |
| nst | quadratic | 198 | — |
| nst | pwl | 344 | — |
| det | float64 | 231 | 171 |
| det | ntuple2 | 343 | 281 |
| det | linear | 344 | 282 |
| det | quadratic | 454 | 392 |
| det | pwl | 1333 | 1161 |
| prob | float64 | 677 | 610 |
| scen | float64 | 671 | 610 |
| sts_shared | float64 | 81.4 | 0.00264 |
| det_shared | float64 | 86.9 | 0.00355 |
| serialize | float64 | 80.5 | 112 |
