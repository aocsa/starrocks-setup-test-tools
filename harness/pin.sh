# Sourced by the multi-CN tests: pins tables on every CN through StarRocks' ADMIN EXECUTE, which
# the Sirius CN serves as `pin_table` (Sirius a2708237 and later).
#
# Each CN pins the whole glob of each table. At query time the FE hands a CN whole files (with
# files_query_whole_file_ranges on), and the CN serves that file subset from its pin. A scan of
# byte ranges is never served from a pin.
#
# The default column lists are the TPC-H columns that fit the memory budget. l_shipmode and the
# comment columns are left out, so queries that read them (q12, q19) miss the pin by design. Set
# PIN_LINEITEM_COLS / PIN_ORDERS_COLS to change that; an empty list pins every column.

PIN_TIER=${PIN_TIER:-host}
PIN_LINEITEM_COLS=${PIN_LINEITEM_COLS-l_orderkey,l_partkey,l_suppkey,l_quantity,l_extendedprice,l_discount,l_tax,l_returnflag,l_linestatus,l_shipdate,l_commitdate,l_receiptdate,l_shipinstruct}
PIN_ORDERS_COLS=${PIN_ORDERS_COLS-o_orderkey,o_custkey,o_orderstatus,o_totalprice,o_orderdate,o_orderpriority,o_shippriority}

# pin_command TABLE COLS: one pin_table line of the CN's admin grammar.
pin_command() {
    local table=$1 cols=$2
    printf 'pin_table path=%s/%s/*.parquet tier=%s name=%s%s' \
        "$TPCH_DATA" "$table" "$PIN_TIER" "$table" "${cols:+ cols=$cols}"
}

# pin_tables MYSQL_EXEC_FN: pins lineitem and orders on every alive CN, in parallel, with retries.
# Right after a cluster starts, the FE's brpc client can fail with "Unable to validate object"
# before the channel is usable, which would silently leave a CN unpinned. Prints one line per CN;
# returns 1 if any CN could not pin.
pin_tables() {
    local exec_fn=$1 ids id
    ids=$("$exec_fn" -e "SHOW COMPUTE NODES" | awk -F'\t' '{print $1}')
    [[ -n "$ids" ]] || {
        echo "pin: no compute nodes" >&2
        return 1
    }
    local script
    script="$(pin_command lineitem "$PIN_LINEITEM_COLS")
$(pin_command orders "$PIN_ORDERS_COLS")"
    local pids=() status=0
    for id in $ids; do
        (
            local try out started=$EPOCHREALTIME
            for try in 1 2 3 4 5; do
                if out=$("$exec_fn" -e "ADMIN EXECUTE ON $id '$script';" 2>&1); then
                    printf '   pinned on CN %s in %ss: %s\n' "$id" \
                        "$(awk -v s="$started" -v n="$EPOCHREALTIME" 'BEGIN { printf "%.1f", n - s }')" \
                        "$(tr '\n' ' ' <<<"$out")"
                    exit 0
                fi
                echo "   pin on CN $id, try $try, failed: $out" >&2
                sleep 15
            done
            exit 1
        ) &
        pids+=($!)
    done
    for id in "${pids[@]}"; do
        wait "$id" || status=1
    done
    return "$status"
}
