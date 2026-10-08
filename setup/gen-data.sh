#!/usr/bin/env bash
# Generates TPC-H parquet into $DATA_ROOT/tpch_sf<N>/<table>/*.parquet with Sirius's generator
# (test/tpch_performance/generate_tpch_data.sh, which builds tpchgen-rs on first use).
# Skips a scale factor whose eight tables are already there. Needs setup/build-engine.sh first
# (the repo-root pixi env).
#
#   setup/gen-data.sh 1                 # smoke-test data, about a minute
#   setup/gen-data.sh 1000 3000         # benchmark data: about 266 GB and 1.13 TB
#
# Size check: about 0.38 GB per scale factor. Write to local NVMe or a parallel filesystem, not NFS.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"
require_sirius

[[ $# -gt 0 ]] || { sed -n '2,10p' "$0" >&2; exit 2; }
TABLES="customer lineitem nation orders part partsupp region supplier"

for sf in "$@"; do
    out=$DATA_ROOT/tpch_sf$sf
    absent=()
    for table in $TABLES; do
        compgen -G "$out/$table/*.parquet" >/dev/null || absent+=("$table")
    done
    if [[ ${#absent[@]} -eq 0 ]]; then
        echo "== SF$sf already at $out"
        continue
    fi
    if [[ -e "$out" ]]; then
        # The generator skips an existing directory, so a partial one would never be completed.
        echo "$out exists but has no parquet for: ${absent[*]}; remove it and rerun" >&2
        exit 1
    fi
    need_gb=$(awk -v sf="$sf" 'BEGIN { printf "%d", sf * 0.38 + 1 }')
    mkdir -p "$DATA_ROOT"
    free_gb=$(df -BG --output=avail "$DATA_ROOT" | tail -1 | tr -dc 0-9)
    if [[ "$free_gb" -lt "$need_gb" ]]; then
        echo "SF$sf needs about ${need_gb} GB; $DATA_ROOT has ${free_gb} GB free" >&2
        exit 1
    fi
    echo "== generating SF$sf into $out (about ${need_gb} GB)"
    (cd "$SIRIUS_DIR" && pixi run bash test/tpch_performance/generate_tpch_data.sh "$sf" \
        --format parquet --output "$out" --jobs "$(nproc)")
done
