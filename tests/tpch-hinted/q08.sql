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
    o_year,
    sum(
        CASE WHEN nation = 'BRAZIL' THEN
            volume
        ELSE
            0
        END) / sum(volume) AS mkt_share
FROM (
    SELECT
        extract(year FROM o_orderdate) AS o_year,
        l_extendedprice * (1 - l_discount) AS volume,
        sn.nation AS nation
    FROM
        lineitem
        JOIN [BROADCAST] part ON p_partkey = l_partkey
        JOIN [BROADCAST] (
            SELECT s_suppkey, n2.n_name AS nation
            FROM supplier
                JOIN nation n2 ON s_nationkey = n2.n_nationkey) sn ON sn.s_suppkey = l_suppkey
        JOIN [SHUFFLE] orders ON l_orderkey = o_orderkey
        JOIN [SHUFFLE] customer ON o_custkey = c_custkey
        JOIN [BROADCAST] nation n1 ON c_nationkey = n1.n_nationkey
        JOIN [BROADCAST] region ON n1.n_regionkey = r_regionkey
    WHERE
        r_name = 'AMERICA'
        AND o_orderdate BETWEEN CAST('1995-01-01' AS date)
        AND CAST('1996-12-31' AS date)
        AND p_type = 'ECONOMY ANODIZED STEEL') AS all_nations
GROUP BY
    o_year
ORDER BY
    o_year;
