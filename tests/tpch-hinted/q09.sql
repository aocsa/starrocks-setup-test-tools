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
    nation,
    o_year,
    sum(amount) AS sum_profit
FROM (
    SELECT
        sn.n_name AS nation,
        extract(year FROM o_orderdate) AS o_year,
        l_extendedprice * (1 - l_discount) - ps_supplycost * l_quantity AS amount
    FROM
        lineitem
        JOIN [BROADCAST] part ON p_partkey = l_partkey
        JOIN [BROADCAST] (
            SELECT s_suppkey, n_name
            FROM supplier
                JOIN nation ON s_nationkey = n_nationkey) sn ON sn.s_suppkey = l_suppkey
        JOIN [SHUFFLE] partsupp ON ps_suppkey = l_suppkey AND ps_partkey = l_partkey
        JOIN [SHUFFLE] orders ON o_orderkey = l_orderkey
    WHERE
        p_name LIKE '%green%') AS profit
GROUP BY
    nation,
    o_year
ORDER BY
    nation,
    o_year DESC;
