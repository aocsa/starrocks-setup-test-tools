# 4-GPU TPC-H joins: build, set up and run from scratch

This runs seven TPC-H join queries (q14, q05, q07, q08, q09, q12, q19) on one StarRocks FE and
four Sirius compute nodes (CNs), one CN per GPU. The CNs exchange data over NIXL. Every result
is checked against DuckDB on the same parquet.

The driver is [`4cn_tpch_joins_sf1000.sh`](4cn_tpch_joins_sf1000.sh); despite its name it runs
any scale factor (`SF=3000`) and any number of GPUs (`GPUS="0 1"`). The [`setup/`](../setup)
scripts do every build step below. This document explains what they do and why, for when a step
fails or a box differs.

## Layout

Commands assume `bash` and this layout. Override any path in the environment (`env.sh`):

```bash
export WORK=$HOME                  # any directory
# $WORK/starrocks-setup-test-tools  this repo
# $WORK/sirius                      Sirius, branch feat/tpch-groupby-join-nixl (SIRIUS_DIR)
# $WORK/tools                       UCX and NIXL installs (TOOLS_DIR); Sirius's scripts/cn-env.sh looks here
```

## What to expect

Reference runs on 2026-10-06: 4× GB200 (185 GiB each), 156.4 GiB slab pool per CN, 1.7 TB host
RAM.

| query | SF1000 | SF3000 |
|---|---|---|
| q14 | PASS 4 s | PASS 20 s |
| q05 | PASS 3 s | GPU out of memory |
| q07 | PASS 2 s | PASS 24 s |
| q08 | PASS 2 s | GPU out of memory |
| q09 | PASS 6 s | GPU out of memory |
| q12 | PASS 1 s | PASS 8 s |
| q19 | PASS 2 s | PASS 20 s |

- **Times** count only the StarRocks query. These are single runs, with parquet likely in the OS
  page cache from earlier runs; a first run on a cold cache is slower.
- **The DuckDB check.** On the first run DuckDB computes each oracle answer after its query.
  That's about a minute per query at SF1000 and several minutes at SF3000. The answers are cached
  (keyed by SQL hash and data path), so later runs skip it.
- **The SF3000 failures.** q05, q08 and q09 shuffle the unfiltered `lineitem` before any
  selective join, which needs about 220 GB per CN against a 168 GB pool.

## 1. Box prerequisites

`setup/check-prereqs.sh` checks all of these:

- **GPUs:** NVIDIA GPUs with no MIG, and the driver installed. Tested on GB200 (aarch64).
- **CUDA toolkit:** at `/usr/local/cuda`, for building UCX and NIXL. 13.0 works.
- **System toolchain:** `gcc`/`g++`, `make`, `pkg-config`, `git`, `numactl`, `curl`, `python3`.
- **RDMA headers:** `libibverbs-dev` / `rdma-core`. MLNX OFED provides them.
- **[pixi](https://pixi.sh) ≥ 0.71:** installs everything else (CUDA 13 libraries, libcudf, Rust,
  JDK 17, Maven, Thrift, the mysql client, Python with DuckDB).
- **Network access:** the first builds download conda packages, Maven artifacts, Cargo crates and
  a Go module.
- **Data:** TPC-H parquet at `$DATA_ROOT/tpch_sf<N>/<table>/*.parquet` for all eight tables.
  SF1000 is about 266 GB and SF3000 about 1.2 TB. Use fast local or parallel storage, not NFS.
- **Ports:** the FE uses 9031, 8031, 9021 and 9011, and the CNs use 9100–9134. These are off the
  StarRocks defaults so another FE can run alongside. The script checks they're free.

## 2. Get the code

```bash
cd $WORK
git clone git@github.com:aocsa/starrocks-setup-test-tools.git
git clone --branch feat/tpch-groupby-join-nixl git@github.com:aocsa/sirius.git
git -C sirius submodule update --init --recursive
```

`setup/all.sh` does steps 3–6 (and clones Sirius if it's missing), building UCX/NIXL, the engine
and the FE in parallel.

## 3. UCX and NIXL — `setup/build-ucx-nixl.sh`

These live outside the repos, in `$WORK/tools`:

- **UCX 1.21.0** with CUDA: `./configure --prefix=$WORK/tools/ucx-install --with-cuda=/usr/local/cuda --enable-mt`.
- **NIXL** at commit `4d030b94` (`v1.3.1-81`), built with meson against that UCX into
  `$WORK/tools/nvda_nixl`.

Two things break the obvious recipe, and the script handles both:

- **Installing meson, ninja and pybind11.** On Ubuntu 24.04 `pip install --user` is blocked
  (PEP 668), and `python3 -m venv` fails without `python3.12-venv`. The script installs them with
  `pip install --target $WORK/tools/pydeps`.
- **NFS home directories.** meson aborts with `Clock skew detected` when its build dir is on an
  NFS home. The script builds NIXL in `NIXL_BUILD_DIR` on local disk (default
  `/tmp/$USER-nixl-build`).

Check that the UCX plugin was built:

```bash
ls $WORK/tools/nvda_nixl/lib/*-linux-gnu/plugins/libplugin_UCX.so
```

## 4. Sirius engine — `setup/build-engine.sh`

`pixi run make` in `$WORK/sirius` builds `build/release/extension/sirius/libsirius.so`, which
the CN links against. If a build fails, rebuild with `CLEAN=1`: a half-configured
`build/release` breaks the next configure.

## 5. StarRocks FE — `setup/build-fe.sh`

The FE needs [`patches/starrocks-fe-files-query-whole-file-ranges.patch`](patches/starrocks-fe-files-query-whole-file-ranges.patch):

- **What it fixes.** Without it, the FE cuts FILES() scans of large parquet files into byte ranges
  spread across CNs. The CN refuses them with `byte-range splits do not tile the parquet file`.
- **What it adds.** An FE setting, `files_query_whole_file_ranges`, that hands out whole files
  instead. The run script turns it on and stops if the FE doesn't recognize it.
- **Why stock StarRocks can't avoid this.** FILES() marks every file splittable, so there's no
  setting to stop the cuts.
- **Pinning.** Pinned tables serve whole-file scans only, so they need the patch too.

The script applies the patch idempotently to `$WORK/sirius/experimental/starrocks/starrocks`,
then runs:

```bash
cd $WORK/sirius/experimental/starrocks
pixi install --all
THRIFT=$PWD/.pixi/envs/cn/bin/thrift pixi run fe-build
```

- **The `THRIFT=` override is required.** StarRocks 4.1.3 builds against libthrift 0.23, but the
  pixi `fe` env pins the 0.20 Thrift compiler, whose generated Java doesn't compile against it
  (`wrong number of type arguments; required 3`). The `cn` env's compiler generates compatible
  code.
- **Rebuilding.** The FE ends up in `starrocks/output/fe`. Before rebuilding over an older FE,
  use `CLEAN=1`: `fe-build` doesn't remove old jars, and two versions of a jar end up on the
  classpath.

## 6. CN — `setup/build-cn.sh`

The CN builds with Sirius's `scripts/cn-env.sh` sourced, not `pixi run cn-build`. The env script
sets the NIXL and UCX paths, the clang headers bindgen needs for `nixl-sys`, and the system
linker.

The link also needs a workaround:

- **The problem.** The repo-root pixi env ships a `libcusolver.so.12` without symbol versioning,
  while `libcuvs` asks for versioned symbols. The final link fails with
  `undefined reference to cusolverDn...@libcusolver.so.12`.
- **The fix.** The script points the link at the StarRocks env's versioned copy (12.2) through a
  one-file shim directory, for the link only.
- **At run time** the unversioned library (12.3) works; the CN only warns
  `no version information available`.

With `TEST=1` the script also runs the CN unit tests.

## 7. Run

```bash
cd $WORK/starrocks-setup-test-tools
tests/4cn_tpch_joins_sf1000.sh 2>&1 | tee 4cn.log            # SF1000, 4 GPUs
SF=3000 TPCH_QUERIES="q14 q07 q12 q19" tests/4cn_tpch_joins_sf1000.sh
GPUS="0 1" SF=1 INJECT_FAILURE_QUERY=q05 tests/4cn_tpch_joins_sf1000.sh
```

**Before it starts.** The script refuses to start while one of the selected GPUs has compute
processes, because each CN reserves 85% of its GPU up front. Override with `ALLOW_BUSY_GPUS=1`.

**What the script does:**

1. starts an isolated FE (its own config, metadata and logs);
2. starts one CN per GPU, each bound to the CPU socket of its GPU;
3. waits until the FE reports all of them alive;
4. runs each query, compares the result with DuckDB, and checks that every CN's
   `leak counters` are back to zero;
5. checks that the CNs shipped data to each other over NIXL;
6. prints a summary and shuts everything down.

A query that fails doesn't stop the run. A CN that dies does: the remaining queries are reported
as SKIP.

**Output** goes under `RUN_ROOT` (default `$RUN_ROOT_BASE/tpch-joins-sf$SF`):

- `run/` holds each query's result (`qNN.tsv`) and errors (`qNN.err`), the FE logs (`fe/log/`),
  and each CN's log (`cnN.log`). It's wiped at the start of each run.
- `oracle/` holds the cached DuckDB answers, which are kept between runs.

For timings across iterations and scale factors, use [`harness/bench.sh`](../harness/bench.sh).

## Settings

All of these are environment variables:

| variable | default | meaning |
|---|---|---|
| `SF` | `1000` | scale factor; picks `TPCH_DATA` |
| `TPCH_DATA` | `$DATA_ROOT/tpch_sf$SF` | dataset root |
| `TPCH_QUERIES` | `q14 q05 q07 q08 q09 q12 q19` | queries from `tests/tpch/` |
| `GPUS` | `0 1 2 3` | one CN per listed GPU |
| `GPU_FRACTION` | `0.85` | share of each GPU reserved for the CN's slab pool |
| `HOST_BYTES` | 128 GiB | host spill memory per CN |
| `PIPELINE_THREADS` | `4` | engine pipeline threads per CN |
| `NUMA_BIND` | `1` | bind each CN to its GPU's CPU socket |
| `QUERY_TIMEOUT_S` | `3600` | FE query timeout |
| `DUCKDB_MEMORY_LIMIT` | `512GB` | cap for the DuckDB oracle |
| `INJECT_FAILURE_QUERY` | unset | first run this query with one fragment failed on purpose, and require the CNs to hold nothing afterwards |
| `RESULTS_CSV`, `ITERATION` | unset, `0` | append `engine,query,iteration,runtime_s,status` per query (`harness/bench.sh` sets these) |
| `FE_QUERY_PORT`, `FE_HTTP_PORT`, `FE_RPC_PORT`, `FE_EDIT_LOG_PORT` | 9031, 8031, 9021, 9011 | FE ports |
| `PORT_BASE`, `PORT_STRIDE` | 9100, 10 | CN *i* uses ports `PORT_BASE + i*PORT_STRIDE` to `+4` |
| `RUN_ROOT` | `$RUN_ROOT_BASE/tpch-joins-sf$SF` | run and oracle directories |
| `ALLOW_BUSY_GPUS` | `0` | `1` skips the check that the selected GPUs are idle |

## Troubleshooting

See the table in the [README](../README.md#troubleshooting).
