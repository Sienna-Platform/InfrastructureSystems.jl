| kind | eltype | op | n | infrastore (µs/op) | is4 (µs/op) | speedup |
|---|---|---|---:|---:|---:|---:|
| sts | float64 | bulk_add | 100000 | 13.9 | 98.9 | 7.12× |
| sts | float64 | get_full | 100000 | 67.9 | 1678 | 24.7× |
| sts | float64 | get_sliced | 100000 | 59.5 | 1678 | 28.2× |
| sts | float64 | read_by_timestamp | 2400000 | 2.04 | 704 | 344× |
| sts | ntuple2 | bulk_add | 100000 | 17.1 | 112 | 6.54× |
| sts | ntuple2 | get_full | 100000 | 80.6 | 2233 | 27.7× |
| sts | ntuple2 | get_sliced | 100000 | 70.4 | 2233 | 31.7× |
| sts | linear | bulk_add | 100000 | 17.4 | 106 | 6.12× |
| sts | linear | get_full | 100000 | 79.8 | 1863 | 23.4× |
| sts | linear | get_sliced | 100000 | 69.9 | 1861 | 26.6× |
| sts | quadratic | bulk_add | 100000 | 17.7 | 109 | 6.13× |
| sts | quadratic | get_full | 100000 | 80.6 | 2233 | 27.7× |
| sts | quadratic | get_sliced | 100000 | 70.0 | 2230 | 31.8× |
| sts | pwl | bulk_add | 100000 | 24.8 | 132 | 5.33× |
| sts | pwl | get_full | 100000 | 94.7 | 3847 | 40.6× |
| sts | pwl | get_sliced | 100000 | 77.0 | 4799 | 62.3× |
| nst | float64 | bulk_add | 100000 | 37.9 | not_supported_on_branch | — |
| nst | float64 | get_full | 100000 | 81.3 | — | — |
| nst | ntuple2 | bulk_add | 100000 | 42.6 | not_supported_on_branch | — |
| nst | ntuple2 | get_full | 100000 | 92.0 | — | — |
| nst | linear | bulk_add | 100000 | 43.0 | not_supported_on_branch | — |
| nst | linear | get_full | 100000 | 90.8 | — | — |
| nst | quadratic | bulk_add | 100000 | 44.1 | not_supported_on_branch | — |
| nst | quadratic | get_full | 100000 | 91.4 | — | — |
| nst | pwl | bulk_add | 100000 | 50.2 | not_supported_on_branch | — |
| nst | pwl | get_full | 100000 | 104 | — | — |
| det | float64 | bulk_add | 100000 | 56.1 | 137 | 2.44× |
| det | float64 | get_full | 100000 | 106 | 2188 | 20.6× |
| det | float64 | get_window | 100000 | 67.6 | 2165 | 32.0× |
| det | float64 | read_by_window | 1200000 | 5.76 | 1516 | 263× |
| det | ntuple2 | bulk_add | 100000 | 71.6 | 160 | 2.23× |
| det | ntuple2 | get_full | 100000 | 146 | 2565 | 17.6× |
| det | ntuple2 | get_window | 100000 | 77.4 | 2086 | 26.9× |
| det | linear | bulk_add | 100000 | 68.7 | 157 | 2.28× |
| det | linear | get_full | 100000 | 122 | 2076 | 17.0× |
| det | linear | get_window | 100000 | 75.3 | 1999 | 26.6× |
| det | quadratic | bulk_add | 100000 | 74.7 | 162 | 2.17× |
| det | quadratic | get_full | 100000 | 125 | 3260 | 26.1× |
| det | quadratic | get_window | 100000 | 74.9 | 3173 | 42.4× |
| det | pwl | bulk_add | 100000 | 123 | 1423 | 11.6× |
| det | pwl | get_full | 100000 | 181 | 4992 | 27.5× |
| det | pwl | get_window | 100000 | 87.1 | 4693 | 53.9× |
| prob | float64 | bulk_add | 100000 | 80.7 | 139 | 1.72× |
| prob | float64 | get_full | 100000 | 134 | 5054 | 37.7× |
| prob | float64 | get_window | 100000 | 74.9 | 5009 | 66.9× |
| scen | float64 | bulk_add | 100000 | 80.5 | 138 | 1.71× |
| scen | float64 | get_full | 100000 | 130 | 5484 | 42.3× |
| scen | float64 | get_window | 100000 | 71.6 | 5438 | 75.9× |
| dst | float64 | transform | 100000 | 28.7 | 20.6 | 0.718× |
| dst | float64 | get_window | 100000 | 109 | 20245 | 185× |
| dst | float64 | read_by_window | 1300000 | 16.2 | 2814 | 173× |
| sts_shared | float64 | bulk_add | 100000 | 12.5 | 14.8 | 1.18× |
| sts_shared | float64 | get_full | 100000 | 63.2 | 7209 | 114× |
| sts_shared | float64 | get_sliced | 100000 | 63.7 | 7249 | 114× |
| sts_shared | float64 | read_by_timestamp | 2400000 | 1.83 | 609 | 332× |
| det_shared | float64 | bulk_add | 100000 | 26.6 | 24.7 | 0.928× |
| det_shared | float64 | get_full | 100000 | 79.3 | 6007 | 75.7× |
| det_shared | float64 | get_window | 100000 | 72.6 | 5985 | 82.5× |
| det_shared | float64 | read_by_window | 1200000 | 2.98 | 1467 | 492× |
| has_ts | float64 | bulk_add | 100000 | 18.4 | 30.7 | 1.67× |
| has_ts | float64 | has_hit | 100000 | 5.49 | 4.59 | 0.836× |
| has_ts | float64 | has_miss | 100000 | 12.4 | 17.6 | 1.42× |
| serialize | float64 | to_json | 100000 | 5.66 | 50.5 | 8.93× |
| serialize | float64 | from_json | 100000 | 16.5 | 89.9 | 5.43× |
| serialize | float64 | reload_read_one | 1 | 2114 | 28678 | 13.6× |
| remove | float64 | remove_all | 100000 | 38.1 | — | — |

| kind | eltype | infrastore disk (MB) | is4 disk (MB) |
|---|---|---:|---:|
| sts | float64 | 112 | 80.8 |
| sts | ntuple2 | 130 | 101 |
| sts | linear | 132 | 101 |
| sts | quadratic | 152 | 124 |
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
| serialize | float64 | 83.6 | 112 |
