SET disable_join_reorder = true;
WITH
customer AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/customer/*.parquet","format"="parquet")),
lineitem AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/lineitem/*.parquet","format"="parquet")),
nation AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/nation/*.parquet","format"="parquet")),
orders AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/orders/*.parquet","format"="parquet")),
part AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/part/*.parquet","format"="parquet")),
partsupp AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/partsupp/*.parquet","format"="parquet")),
region AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/region/*.parquet","format"="parquet")),
supplier AS (SELECT * FROM FILES("path"="file://__TPCH_DATA__/supplier/*.parquet","format"="parquet"))
SELECT
    sn.n_name,
    sum(l_extendedprice * (1 - l_discount)) AS revenue
FROM
    lineitem
    JOIN [BROADCAST] (
        SELECT s_suppkey, s_nationkey, n_name
        FROM supplier
            JOIN nation ON s_nationkey = n_nationkey
            JOIN region ON n_regionkey = r_regionkey
        WHERE r_name = 'ASIA') sn ON l_suppkey = sn.s_suppkey
    JOIN [SHUFFLE] orders ON l_orderkey = o_orderkey
    JOIN [SHUFFLE] customer ON c_custkey = o_custkey AND c_nationkey = sn.s_nationkey
WHERE
    o_orderdate >= CAST('1994-01-01' AS date)
    AND o_orderdate < CAST('1995-01-01' AS date)
GROUP BY
    sn.n_name
ORDER BY
    revenue DESC;
