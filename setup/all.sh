#!/usr/bin/env bash
# Sets up a fresh box end to end: clones Sirius if it isn't there, checks prerequisites, builds
# UCX/NIXL, the engine and the FE in parallel (they're independent), then the CN.
# Each build logs to $RUN_ROOT_BASE/setup-logs/<step>.log; a failed step prints its log tail.
#
# Reference build times on 4x GB200: engine ~15 min, FE ~10 min, UCX+NIXL ~10 min, CN ~2 min.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"

LOGS=$RUN_ROOT_BASE/setup-logs
mkdir -p "$LOGS"

if [[ ! -d "$SIRIUS_DIR/.git" ]]; then
    echo "== cloning Sirius $SIRIUS_BRANCH into $SIRIUS_DIR"
    git clone --branch "$SIRIUS_BRANCH" "$SIRIUS_REMOTE" "$SIRIUS_DIR"
fi
git -C "$SIRIUS_DIR" submodule update --init --recursive

"$HERE/check-prereqs.sh"

step() {
    local name=$1
    shift
    if "$@" >"$LOGS/$name.log" 2>&1; then
        echo "   done: $name"
    else
        echo "   FAILED: $name (log: $LOGS/$name.log)" >&2
        tail -n 30 "$LOGS/$name.log" >&2
        return 1
    fi
}

echo "== building UCX/NIXL, the engine and the FE in parallel (logs in $LOGS)"
pids=()
step ucx-nixl "$HERE/build-ucx-nixl.sh" & pids+=($!)
step engine "$HERE/build-engine.sh" & pids+=($!)
step fe "$HERE/build-fe.sh" & pids+=($!)
failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
done
[[ "$failed" -eq 0 ]] || exit 1

echo "== building the CN"
step cn "$HERE/build-cn.sh"
echo "setup complete; next: setup/gen-data.sh if the data isn't there, then tests/4cn_tpch_joins_sf1000.sh (README.md)"
