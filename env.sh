# Shared settings for the setup scripts, the tests and scripts/. Source it; don't run it.
#
# Precedence, highest first: the environment, then the box profile (box.sh, committed on the
# box/* branches for a specific machine), then the machine-independent defaults below, which
# size themselves from this machine's GPUs and RAM.
#
# Layout it assumes by default (every path can be overridden from the environment):
#
#   $WORK/
#     starrocks-setup-test-tools/   this repo
#     sirius/                       the Sirius checkout under test (SIRIUS_DIR)
#     tools/                        UCX and NIXL installs (TOOLS_DIR)

TOOLS_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A box profile sets values for one machine with `: "${VAR:=value}"`, so the environment still
# wins. BOX_PROFILE=/dev/null ignores it.
BOX_PROFILE=${BOX_PROFILE:-$TOOLS_REPO/box.sh}
if [[ -f "$BOX_PROFILE" ]]; then
    # shellcheck source=/dev/null
    source "$BOX_PROFILE"
fi

WORK=${WORK:-$(cd "$TOOLS_REPO/.." && pwd)}

# Sirius checkout and branch the scripts drive: the top of the StarRocks PR stack
# (sirius-db/sirius#2037 ... #2062). Use main once the stack has merged.
SIRIUS_DIR=${SIRIUS_DIR:-$WORK/sirius}
SIRIUS_BRANCH=${SIRIUS_BRANCH:-stacked/sr-runtime-filters}
SIRIUS_REMOTE=${SIRIUS_REMOTE:-https://github.com/sirius-db/sirius.git}

# Derived paths the tests use. SR_DIR is Sirius's StarRocks integration; REPO_ROOT is the Sirius
# repo root (engine build, repo-root pixi env).
SR_DIR=$SIRIUS_DIR/experimental/starrocks
REPO_ROOT=$SIRIUS_DIR

# UCX and NIXL installs. Sirius's scripts/cn-env.sh reads TOOLS_DIR.
export TOOLS_DIR=${TOOLS_DIR:-$WORK/tools}

# The FE was built with the StarRocks fe pixi env's JDK 17.
export JAVA_HOME=${JAVA_HOME:-$SR_DIR/.pixi/envs/fe/lib/jvm}

# TPC-H parquet, one directory per scale factor: $DATA_ROOT/tpch_sf<N>/<table>/*.parquet.
DATA_ROOT=${DATA_ROOT:-$WORK/datasets}

# Where runs write logs, results and the cached DuckDB answers. Must be writable and should be
# local disk.
RUN_ROOT_BASE=${RUN_ROOT_BASE:-/tmp/$USER/sirius-starrocks-runs}

# One CN per listed GPU; by default every GPU nvidia-smi reports.
if [[ -z "${GPUS:-}" ]]; then
    GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr '\n' ' ')
    GPUS=${GPUS:-0}
fi
GPUS=$(echo $GPUS)

# Memory per CN. The CNs and the DuckDB check share host RAM, so each CN's host spill tier gets
# 40% of RAM split across the CNs; DuckDB gets another 40%, capped at 512 GB.
_ram_gib=$(awk '/^MemTotal:/ {print int($2 / 1048576)}' /proc/meminfo 2>/dev/null)
_ram_gib=${_ram_gib:-64}
_num_gpus=$(wc -w <<<"$GPUS")
_host_gib=$((_ram_gib * 40 / 100 / _num_gpus))
((_host_gib < 1)) && _host_gib=1
HOST_BYTES=${HOST_BYTES:-$((_host_gib << 30))}
_duckdb_gb=$((_ram_gib * 40 / 100))
((_duckdb_gb > 512)) && _duckdb_gb=512
export DUCKDB_MEMORY_LIMIT=${DUCKDB_MEMORY_LIMIT:-${_duckdb_gb}GB}
# Share of each GPU the CN's memory pool reserves up front: 85%, but never leaving less than
# 5.25 GiB outside the pool, for the CUDA context, NIXL and the ring exchange's rings (up to
# 1.25 GiB on a small GPU). Sized from the smallest listed GPU.
_gpu_mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
    -i "$(tr ' ' ',' <<<"$GPUS")" 2>/dev/null | sort -n | head -1)
_gpu_mib=${_gpu_mib:-32768}
GPU_FRACTION=${GPU_FRACTION:-$(awk -v m="$_gpu_mib" \
    'BEGIN { f = 1 - 5376 / m; if (f > 0.85) f = 0.85; if (f < 0.5) f = 0.5; printf "%.2f", f }')}
# Engine threads per CN: 4 when the pool has at least 48 GiB, else 2, so concurrent tasks'
# reservations don't push a small pool into out-of-memory retries.
PIPELINE_THREADS=${PIPELINE_THREADS:-$(awk -v m="$_gpu_mib" -v f="$GPU_FRACTION" \
    'BEGIN { print (m * f >= 48 * 1024) ? 4 : 2 }')}
# The ring exchange runs on the capped async pool.
export GPU_ALLOCATOR=${GPU_ALLOCATOR:-async_capped}
unset _ram_gib _num_gpus _host_gib _duckdb_gb _gpu_mib

# pixi, installed per user by https://pixi.sh.
export PATH="$HOME/.pixi/bin:$PATH"

# Fails with a hint if SIRIUS_DIR does not look like a Sirius checkout with the StarRocks CN.
require_sirius() {
    if [[ ! -f "$SR_DIR/scripts/cn-env.sh" ]]; then
        echo "no Sirius checkout with experimental/starrocks at SIRIUS_DIR=$SIRIUS_DIR" >&2
        echo "clone it next to this repo, or set SIRIUS_DIR (see README.md)" >&2
        return 1
    fi
}
