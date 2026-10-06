# Hinted TPC-H join queries

Same answers as `../tpch/`, different join orders. FILES() tables have no statistics, so
StarRocks' optimizer can't see which filters are selective, and for q05, q08 and q09 it
hash-shuffles all of `lineitem` against `orders` first. At SF3000 on 4 GPUs that shuffle needs
about 220 GB per CN, more than the GPU pool holds.

Each variant turns off join reordering (`SET disable_join_reorder = true`) and
broadcast-joins the selective side into the `lineitem` scan, so `lineitem` shrinks before
anything is shuffled:

| query | broadcast into the `lineitem` scan | `lineitem` kept |
|---|---|---|
| q05 | `supplier ⋈ nation ⋈ region` where `r_name = 'ASIA'` | about 1/5 |
| q08 | `part` where `p_type = 'ECONOMY ANODIZED STEEL'` | about 1/150 |
| q09 | `part` where `p_name LIKE '%green%'` | about 1/18 |

Run them with `harness/bench.sh --hinted`, or `TPCH_SQL_DIR=tests/tpch-hinted` for the test
script. The DuckDB oracle, and its answer cache, always use the standard query, so a variant is
checked against the official text. These aren't the official TPC-H texts: report their results
as "hinted".
