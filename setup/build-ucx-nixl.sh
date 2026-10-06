#!/usr/bin/env bash
# Builds UCX 1.21.0 (with CUDA) and NIXL at the pinned commit into $TOOLS_DIR, where Sirius's
# scripts/cn-env.sh finds them. Skips a component that is already installed; FORCE=1 rebuilds.
#
# Two things that break the obvious recipe:
#   - Ubuntu 24.04 blocks `pip install --user` (PEP 668), and python3-venv may be absent, so
#     meson, ninja and pybind11 go into $TOOLS_DIR/pydeps with `pip install --target`.
#   - meson aborts with "Clock skew detected" when its build dir is on NFS, so the NIXL build
#     dir is on local disk (NIXL_BUILD_DIR).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"

UCX_VERSION=${UCX_VERSION:-1.21.0}
NIXL_COMMIT=${NIXL_COMMIT:-4d030b94} # v1.3.1-81, the reference build
NIXL_BUILD_DIR=${NIXL_BUILD_DIR:-/tmp/$USER-nixl-build}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
FORCE=${FORCE:-0}

UCX_PREFIX=$TOOLS_DIR/ucx-install
NIXL_PREFIX=$TOOLS_DIR/nvda_nixl
PYDEPS=$TOOLS_DIR/pydeps
mkdir -p "$TOOLS_DIR"

if [[ "$FORCE" != 1 && -e "$UCX_PREFIX/lib/libucp.so" ]]; then
    echo "== UCX already installed at $UCX_PREFIX"
else
    echo "== building UCX $UCX_VERSION into $UCX_PREFIX"
    cd "$TOOLS_DIR"
    [[ -e "ucx-$UCX_VERSION.tar.gz" ]] ||
        curl -fLO "https://github.com/openucx/ucx/releases/download/v$UCX_VERSION/ucx-$UCX_VERSION.tar.gz"
    rm -rf "ucx-$UCX_VERSION"
    tar xzf "ucx-$UCX_VERSION.tar.gz"
    cd "ucx-$UCX_VERSION"
    ./configure --prefix="$UCX_PREFIX" --with-cuda="$CUDA_HOME" --enable-mt
    make -j"$(nproc)" install
fi

if [[ "$FORCE" != 1 ]] && compgen -G "$NIXL_PREFIX/lib/*-linux-gnu/plugins/libplugin_UCX.so" >/dev/null; then
    echo "== NIXL already installed at $NIXL_PREFIX"
    exit 0
fi

echo "== installing meson, ninja and pybind11 into $PYDEPS"
python3 -m pip install --quiet --target "$PYDEPS" meson ninja pybind11
export PATH="$PYDEPS/bin:$PATH" PYTHONPATH="$PYDEPS${PYTHONPATH:+:$PYTHONPATH}"

echo "== building NIXL $NIXL_COMMIT into $NIXL_PREFIX (build dir $NIXL_BUILD_DIR)"
cd "$TOOLS_DIR"
[[ -d nixl-src/.git ]] || git clone https://github.com/ai-dynamo/nixl nixl-src
git -C nixl-src fetch --quiet origin
git -C nixl-src checkout --quiet "$NIXL_COMMIT"
rm -rf "$NIXL_BUILD_DIR"
meson setup "$NIXL_BUILD_DIR" nixl-src \
    --prefix="$NIXL_PREFIX" \
    -Ducx_path="$UCX_PREFIX" \
    -Dcmake_prefix_path="$(python3 -m pybind11 --cmakedir)"
ninja -C "$NIXL_BUILD_DIR" install

plugin=$(compgen -G "$NIXL_PREFIX/lib/*-linux-gnu/plugins/libplugin_UCX.so" || true)
if [[ -z "$plugin" ]]; then
    echo "NIXL installed without its UCX plugin; check that UCX built with CUDA" >&2
    exit 1
fi
echo "== NIXL ready: $plugin"
