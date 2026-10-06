#!/usr/bin/env bash
# Builds the Sirius engine (build/release/extension/sirius/libsirius.so, which the CN links).
# Initializes submodules first: a fresh clone or worktree doesn't. CLEAN=1 wipes build/release
# first, which a failed or half-configured build needs before the next configure.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"
require_sirius

cd "$SIRIUS_DIR"
echo "== Sirius $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
git submodule update --init --recursive
if [[ "${CLEAN:-0}" == 1 ]]; then
    pixi run make clean
fi
pixi run make
ls -l build/release/extension/sirius/libsirius.so
