# Shared settings for the setup scripts, the tests and the harness. Source it; don't run it.
#
# Layout it assumes by default (every path can be overridden from the environment):
#
#   $WORK/
#     starrocks-setup-test-tools/   this repo
#     sirius/                       the Sirius checkout under test (SIRIUS_DIR)
#     tools/                        UCX and NIXL installs (TOOLS_DIR)

TOOLS_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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
DATA_ROOT=${DATA_ROOT:-/scratch/sirius/datasets}

# Where runs write logs, results and the cached DuckDB answers. Must be writable and should be
# local disk: /scratch/$USER only exists for some users.
RUN_ROOT_BASE=${RUN_ROOT_BASE:-/tmp/$USER/sirius-starrocks-runs}

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
