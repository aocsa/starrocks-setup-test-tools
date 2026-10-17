# TPC-H with the SF10000 reference parameters

The queries of `tests/tpch` with their substitution parameters replaced by those of the saved
SF10000 GPU outputs in the spill reproducer package
(`reference/12xl-sf10k/lukewarm/q*/query.sql`), so a StarRocks run can be validated against those
outputs with the package's `result_validation.py`. Generated: each literal of a query body is
replaced, in order, by the reference query's; q6's discount range is the reference's
`0.03 - 0.01 .. 0.03 + 0.01` written out (0.02, 0.04). Use with `TPCH_SQL_DIR=tests/tpch-sf10k-ref`.
