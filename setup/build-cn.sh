#!/usr/bin/env bash
# Builds the Rust StarRocks compute node (CN) against the engine and NIXL, then checks it starts.
# Needs setup/build-engine.sh (libsirius.so, repo-root pixi env) and setup/build-ucx-nixl.sh.
#
# Builds with Sirius's scripts/cn-env.sh sourced, not `pixi run cn-build`: the env script sets
# the NIXL and UCX paths, the clang headers bindgen needs for nixl-sys, and the system linker.
#
# The final link needs a cuSOLVER workaround. The repo-root pixi env's libcusolver.so.12 has no
# symbol versioning, while libcuvs asks for versioned symbols, so the link fails with
# "undefined reference to cusolverDn...@libcusolver.so.12". The link sees the StarRocks env's
# versioned copy through a one-file shim directory instead. At run time the unversioned library
# works; the CN only warns "no version information available".
#
# TEST=1 also runs the CN unit tests.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"
require_sirius

SHIM=$TOOLS_DIR/cusolver-link-shim
cd "$SR_DIR"
[[ -d .pixi/envs/default ]] || pixi install --all
cusolver=$(compgen -G "$SR_DIR/.pixi/envs/default/targets/*/lib/libcusolver.so.12.*" | head -1 || true)
if [[ -z "$cusolver" ]]; then
    echo "no versioned libcusolver.so.12.* in the StarRocks default pixi env" >&2
    exit 1
fi
mkdir -p "$SHIM"
ln -sf "$cusolver" "$SHIM/libcusolver.so.12"

run_in_cn_env() {
    SHIM=$SHIM pixi run -e default bash -c "source scripts/cn-env.sh && LD_LIBRARY_PATH=\"\$SHIM:\$LD_LIBRARY_PATH\" $1"
}

echo "== building the CN"
run_in_cn_env "cargo build --release -p sirius-starrocks-cn"
echo "== checking that it starts"
run_in_cn_env "target/release/sirius-starrocks-cn --help 2>&1" | grep -v "no version information available" | head -3
if [[ "${TEST:-0}" == 1 ]]; then
    echo "== CN unit tests"
    run_in_cn_env "cargo test --release -p sirius-starrocks-cn"
fi
ls -l target/release/sirius-starrocks-cn
