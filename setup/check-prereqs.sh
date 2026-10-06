#!/usr/bin/env bash
# Checks what a fresh box needs before the builds, and reports every problem at once.
# Exit status: 0 when nothing required is missing, 1 otherwise. Warnings don't fail.
#
#   setup/check-prereqs.sh            # also checks the default dataset (SF1000)
#   SCALE_FACTORS="1 3000" setup/check-prereqs.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"

missing=0
ok() { printf '  ok      %s\n' "$*"; }
warn() { printf '  WARN    %s\n' "$*"; }
miss() {
    printf '  MISSING %s\n' "$*"
    missing=$((missing + 1))
}

echo "== GPUs"
if command -v nvidia-smi >/dev/null; then
    gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
    [[ "$gpus" -ge 4 ]] && ok "$gpus GPUs" || warn "$gpus GPUs (the 4-CN run needs 4; set GPUS for fewer)"
    if nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | grep -q Enabled; then
        warn "MIG is enabled on some GPU; the 4-CN run expects whole GPUs"
    fi
    busy=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
    [[ "$busy" -eq 0 ]] || warn "$busy compute processes are using the GPUs right now"
else
    miss "nvidia-smi (NVIDIA driver)"
fi

echo "== toolchain"
[[ -x /usr/local/cuda/bin/nvcc ]] && ok "CUDA toolkit: $(/usr/local/cuda/bin/nvcc --version | grep -o 'release [0-9.]*')" ||
    miss "CUDA toolkit at /usr/local/cuda (builds UCX and NIXL)"
for tool in gcc g++ make pkg-config git curl numactl python3; do
    command -v "$tool" >/dev/null && ok "$tool" || miss "$tool"
done
[[ -e /usr/include/infiniband/verbs.h ]] && ok "RDMA headers (libibverbs-dev / rdma-core)" ||
    miss "RDMA headers: /usr/include/infiniband/verbs.h (libibverbs-dev or MLNX OFED)"
if command -v pixi >/dev/null; then
    version=$(pixi --version | awk '{print $2}')
    if printf '0.71\n%s\n' "$version" | sort -V -C; then ok "pixi $version"; else miss "pixi >= 0.71 (have $version)"; fi
else
    miss "pixi: curl -fsSL https://pixi.sh/install.sh | bash"
fi

echo "== checkouts"
if require_sirius 2>/dev/null; then
    branch=$(git -C "$SIRIUS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    ok "Sirius at $SIRIUS_DIR ($branch)"
    [[ "$branch" == "$SIRIUS_BRANCH" ]] || warn "Sirius is on $branch, not $SIRIUS_BRANCH"
    if git -C "$SIRIUS_DIR" submodule status 2>/dev/null | grep -q '^-'; then
        warn "Sirius submodules are not initialized (setup/build-engine.sh does it)"
    fi
else
    miss "Sirius checkout at SIRIUS_DIR=$SIRIUS_DIR (git clone -b $SIRIUS_BRANCH $SIRIUS_REMOTE)"
fi

echo "== filesystems"
if [[ "$(stat -f -c %T "$WORK" 2>/dev/null)" == nfs* ]]; then
    warn "$WORK is on NFS: build NIXL with a local build dir (setup/build-ucx-nixl.sh does)"
fi
mkdir -p "$RUN_ROOT_BASE" 2>/dev/null && [[ -w "$RUN_ROOT_BASE" ]] && ok "run root $RUN_ROOT_BASE is writable" ||
    miss "writable RUN_ROOT_BASE ($RUN_ROOT_BASE)"

echo "== datasets"
for sf in ${SCALE_FACTORS:-1000}; do
    dir=$DATA_ROOT/tpch_sf$sf
    absent=()
    for table in customer lineitem nation orders part partsupp region supplier; do
        compgen -G "$dir/$table/*.parquet" >/dev/null || absent+=("$table")
    done
    if [[ ${#absent[@]} -eq 0 ]]; then ok "TPC-H SF$sf at $dir"; else miss "TPC-H SF$sf at $dir (no parquet for: ${absent[*]})"; fi
done

echo
if [[ "$missing" -eq 0 ]]; then
    echo "prerequisites OK"
else
    echo "$missing prerequisite(s) missing"
    exit 1
fi
