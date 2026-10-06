#!/usr/bin/env bash
# Builds the StarRocks FE that Sirius's StarRocks integration pins, with this repo's FE patch.
#
# The patch adds `files_query_whole_file_ranges`, so FILES() scans hand each CN whole parquet
# files; without it the CN refuses byte-range splits of large files ("byte-range splits do not
# tile the parquet file"). Applying it is idempotent.
#
# THRIFT points at the `cn` env's Thrift compiler: StarRocks builds against libthrift 0.23, and
# the `fe` env's 0.20 compiler generates Java that doesn't compile against it ("wrong number of
# type arguments; required 3").
#
# CLEAN=1 runs `pixi run fe-clean` first. Do that before rebuilding over an older FE: fe-build
# doesn't remove old jars, and two versions of a jar end up on the classpath.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"
require_sirius

PATCH=$TOOLS_REPO/tests/patches/starrocks-fe-files-query-whole-file-ranges.patch

cd "$SR_DIR"
if git -C starrocks apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "== FE patch already applied"
else
    echo "== applying $(basename "$PATCH")"
    git -C starrocks apply "$PATCH"
fi

pixi install --all
if [[ "${CLEAN:-0}" == 1 ]]; then
    pixi run fe-clean
fi
THRIFT=$SR_DIR/.pixi/envs/cn/bin/thrift pixi run fe-build
ls -l starrocks/output/fe/bin/start_fe.sh
