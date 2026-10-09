#!/usr/bin/env bash
# Benchmarks the TPC-H joins on Sirius StarRocks CNs: scale factors x queries x iterations.
# Every iteration starts a fresh FE and fresh CNs (tests/4cn_tpch_joins_sf1000.sh), so GPU state
# never carries over; --fresh-per-query also restarts the cluster for every query.
#
#   scripts/bench.sh --sf 1000 --iterations 3
#   scripts/bench.sh --sf "1000 3000" --queries "q14 q07 q12 q19" --fresh-per-query --label cold
#   scripts/bench.sh --sf 1 --gpus "0 1" --iterations 1
#   scripts/bench.sh --sf 1000 --pin --label pinned        # pin lineitem/orders first (PIN=1)
#   scripts/bench.sh --sf 1000 --whole-files               # whole files per CN, unpinned
#   scripts/bench.sh --sf 3000 --hinted                    # tests/tpch-hinted where it exists
#
# Writes $RUN_ROOT_BASE/bench/<timestamp>_<label>/:
#   runtimes.csv   engine,query,iteration,runtime_s,status,sf   (one row per query run)
#   summary.md     per SF and query: passes, then min / median / max seconds of the passing runs
#   runs/          each cluster's logs (cn*.log, FE logs, query results and errors)
# DuckDB answers are cached in $RUN_ROOT_BASE/oracle and shared across benches.
# Other settings pass through the environment (GPU_FRACTION, HOST_BYTES, PIPELINE_THREADS, ...).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

sfs=1000
queries="q14 q05 q07 q08 q09 q12 q19"
iterations=1
gpus=$GPUS # env.sh: every GPU unless set
fresh_per_query=0
label=bench
pin=0
whole_files=
sql_dir=
while [[ $# -gt 0 ]]; do
    case $1 in
    --sf) sfs=$2; shift 2 ;;
    --queries) queries=$2; shift 2 ;;
    --iterations) iterations=$2; shift 2 ;;
    --gpus) gpus=$2; shift 2 ;;
    --fresh-per-query) fresh_per_query=1; shift ;;
    --pin) pin=1; shift ;;
    --whole-files) whole_files=1; shift ;;
    --hinted) sql_dir=$TOOLS_REPO/tests/tpch-hinted; shift ;;
    --label) label=$2; shift 2 ;;
    -h | --help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

out=$RUN_ROOT_BASE/bench/$(date +%Y%m%d_%H%M%S)_$label
mkdir -p "$out/runs"
csv=$out/runtimes.csv
echo "engine,query,iteration,runtime_s,status,sf" >"$csv"
echo "== bench '$label': sf=[$sfs] queries=[$queries] iterations=$iterations gpus=[$gpus] pin=$pin -> $out"

# One cluster: runs `query_list` once at `sf`, appending to $csv tagged with the SF.
run_cluster() {
    local sf=$1 iteration=$2 query_list=$3 name=$4 part=$out/runs/$4.csv status=0
    echo "-- sf$sf iteration $iteration: $query_list"
    PIN=$pin FE_WHOLE_FILE_RANGES=${whole_files:-$pin} TPCH_SQL_DIR=$sql_dir \
        SF=$sf GPUS="$gpus" TPCH_QUERIES="$query_list" ITERATION=$iteration RESULTS_CSV=$part \
        RUN_ROOT=$out/runs/$name ORACLE_DIR=$RUN_ROOT_BASE/oracle \
        "$TOOLS_REPO/tests/4cn_tpch_joins_sf1000.sh" >"$out/runs/$name.log" 2>&1 || status=$?
    sed -n '/^== summary/,$p' "$out/runs/$name.log" | sed 's/^/   /'
    if [[ -s "$part" ]]; then
        sed "s/\$/,$sf/" "$part" >>"$csv"
    else
        echo "   no query ran (exit $status); see $out/runs/$name.log" >&2
    fi
}

for sf in $sfs; do
    for ((iteration = 0; iteration < iterations; iteration++)); do
        if [[ "$fresh_per_query" == 1 ]]; then
            for q in $queries; do
                run_cluster "$sf" "$iteration" "$q" "sf$sf-it$iteration-$q"
            done
        else
            run_cluster "$sf" "$iteration" "$queries" "sf$sf-it$iteration"
        fi
    done
done

python3 - "$csv" "$out/summary.md" "$label" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {}
for row in rows:
    by.setdefault((int(row["sf"]), row["query"]), []).append(row)
lines = [f"# {sys.argv[3]}", "", "| SF | query | passed | min s | median s | max s | other statuses |",
         "|---:|---|---:|---:|---:|---:|---|"]
for (sf, query), runs in sorted(by.items()):
    times = [float(r["runtime_s"]) for r in runs if r["status"] == "PASS"]
    other = sorted({r["status"] for r in runs if r["status"] != "PASS"})
    stats = (f"{min(times):.3f} | {statistics.median(times):.3f} | {max(times):.3f}"
             if times else "– | – | –")
    lines.append(f"| {sf} | {query} | {len(times)}/{len(runs)} | {stats} | {', '.join(other)} |")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
echo "== results: $csv, $out/summary.md"
