# Build notes: why each setup step does what it does

The [README](../README.md) covers how to set up and run, and the `setup/` scripts do every step. This page explains the workarounds inside those scripts, for when a step fails or a machine differs.

## UCX and NIXL (`setup/build-ucx-nixl.sh`)

- **What it builds:** UCX 1.21.0 with CUDA (`--with-cuda=/usr/local/cuda --enable-mt`) and NIXL at commit `4d030b94` (v1.3.1-81), installed under `$TOOLS_DIR`. Sirius's `scripts/cn-env.sh` looks for them there.
- **meson, ninja and pybind11** go into `$TOOLS_DIR/pydeps` with `pip install --target`. Ubuntu 24.04 blocks `pip install --user` (PEP 668), and `python3 -m venv` fails without `python3.12-venv`.
- **The NIXL build directory is on local disk** (`NIXL_BUILD_DIR`, default `/tmp/$USER-nixl-build`). meson aborts with `Clock skew detected` on an NFS home.
- **Check:** `ls $TOOLS_DIR/nvda_nixl/lib/*-linux-gnu/plugins/libplugin_UCX.so`. Without that plugin the CN logs `backend 'UCX' not found`.

## Sirius engine (`setup/build-engine.sh`)

- `pixi run make` builds `build/release/extension/sirius/libsirius.so`, which the CN links.
- A fresh clone or worktree needs `git submodule update --init --recursive` first; the script does it.
- After a failed build, rebuild with `CLEAN=1`: a half-configured `build/release` breaks the next configure (`patch does not apply`).

## StarRocks FE (`setup/build-fe.sh`)

- **What it builds:** the StarRocks release that Sirius pins (4.1.3, in `experimental/starrocks/starrocks`), output to `starrocks/output/fe`.
- **`THRIFT=` override:** StarRocks 4.1.3 builds against libthrift 0.23, but the pixi `fe` env pins the 0.20 compiler, whose Java doesn't compile against it (`wrong number of type arguments; required 3`). The script uses the `cn` env's compiler.
- **The patch** (`patches/starrocks-fe-files-query-whole-file-ranges.patch`) adds `files_query_whole_file_ranges`, which hands each CN whole parquet files. Only pinned runs need it; unpinned runs use the FE's byte ranges. The script applies the patch idempotently.
- **Rebuilding over an older FE:** use `CLEAN=1`. `fe-build` doesn't remove old jars, so two versions of a jar would end up on the classpath.

## CN (`setup/build-cn.sh`)

- **It builds with Sirius's `scripts/cn-env.sh` sourced,** not `pixi run cn-build`. That script sets the NIXL and UCX paths, the clang headers that bindgen needs for `nixl-sys` (otherwise: `'stdbool.h' file not found`), and the system linker.
- **cuSOLVER link shim:**
  - **The problem:** the repo-root pixi env ships a `libcusolver.so.12` without symbol versioning, but `libcuvs` asks for versioned symbols, so the final link fails with `undefined reference to cusolverDn...@libcusolver.so.12`.
  - **The fix:** the script points the link, and only the link, at the StarRocks env's versioned copy through a one-file directory.
  - **At run time** the unversioned library works; the CN only warns `no version information available`.
- `TEST=1` also runs the CN unit tests.

## Data (`setup/gen-data.sh`)

- **The generator:** Sirius's `test/tpch_performance/generate_tpch_data.sh` with tpchgen-rs, which it clones and builds on first use. It writes `<table>/*.parquet`, the layout the tests expect.
- **Partial output:** the generator skips a directory that already exists, so `gen-data.sh` refuses a partial one instead of leaving it incomplete.
- **File layout differs from the reference results.** The reference results used the datasets at `/scratch/sirius/datasets` (for example 180 `lineitem` files at SF3000). Freshly generated data has different file and row-group sizes. The answers are the same, but timings can differ.

## The 4-CN run (`tests/4cn_tpch_joins_sf1000.sh`)

- **It refuses to start while a selected GPU has compute processes,** because each CN reserves `GPU_FRACTION` (85%) of its GPU up front. `ALLOW_BUSY_GPUS=1` overrides this.
- **Ports:** the FE uses 9031/8031/9021/9011 and CN *i* uses `PORT_BASE + i*PORT_STRIDE` to `+4`. These are off the StarRocks defaults, so another FE can run alongside.
- **The DuckDB answers** are cached by SQL hash and data path in `$RUN_ROOT_BASE/oracle` (`ORACLE_DIR`).
- **Leak check:** after every query each CN must log `leak counters` at zero (`harness/cn_leak_check.sh`). A failed query must not leave GPU memory behind.
