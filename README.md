# StarRocks + Sirius: setup, tests and benchmark harness

Scripts to build and benchmark [Sirius](https://github.com/sirius-db/sirius) as GPU compute nodes
(CNs) for a StarRocks FE. Each CN runs one GPU. The FE plans the query and the CNs run its
fragments on the GPU, shuffling batches between GPU pools over NIXL. Every query result is
checked against DuckDB on the same parquet.

The Sirius side is branch [`feat/tpch-groupby-join-nixl`](https://github.com/aocsa/sirius/tree/feat/tpch-groupby-join-nixl),
PR [sirius-db/sirius#2016](https://github.com/sirius-db/sirius/pull/2016).

## Layout

```
env.sh       shared paths (SIRIUS_DIR, TOOLS_DIR, DATA_ROOT, RUN_ROOT_BASE); every script sources it
setup/       check-prereqs.sh, build-ucx-nixl.sh, build-engine.sh, build-fe.sh, build-cn.sh, all.sh
tests/       2cn_files_group_by.sh   2 CNs, GROUP BY over generated parquet
             2cn_tpch_joins.sh       2 CNs, TPC-H joins at SF1
             4cn_tpch_joins_sf1000.sh  N CNs (default 4), TPC-H joins at any SF
             tpch/*.sql, tpch_files_compare.py (DuckDB oracle), patches/ (StarRocks FE patch)
harness/     bench.sh (SF x queries x iterations -> runtimes.csv, summary.md), cn_leak_check.sh
```

By default the scripts expect this layout. Override any path in the environment (see `env.sh`):

```
$WORK/starrocks-setup-test-tools   this repo
$WORK/sirius                       Sirius checkout (SIRIUS_DIR)
$WORK/tools                        UCX + NIXL installs (TOOLS_DIR)
```

## Quick start

```bash
export WORK=$HOME
git clone git@github.com:aocsa/starrocks-setup-test-tools.git $WORK/starrocks-setup-test-tools
cd $WORK/starrocks-setup-test-tools
setup/all.sh                                  # clones Sirius if needed, checks the box, builds everything
tests/4cn_tpch_joins_sf1000.sh                # 4 CNs, SF1000, all 7 queries, checked against DuckDB
harness/bench.sh --sf 1000 --iterations 3     # timings
```

`setup/all.sh` builds UCX/NIXL, the engine and the FE in parallel, then the CN. On 4× GB200:
engine about 15 min, FE about 10 min, UCX+NIXL about 10 min, CN about 2 min. Each step also runs
on its own (`setup/build-*.sh`), and every step can be rerun.

## Prerequisites

`setup/check-prereqs.sh` checks all of these and lists what's missing:

- **GPUs:** NVIDIA GPUs without MIG, one CN per GPU. Tested on 4× GB200 (aarch64, 185 GiB each).
- **Toolchain:** CUDA toolkit at `/usr/local/cuda` (13.0 works), `gcc`/`g++`, `make`,
  `pkg-config`, `git`, `curl`, `numactl`, `python3`, and RDMA headers (`libibverbs-dev` or MLNX
  OFED).
- **[pixi](https://pixi.sh) ≥ 0.71:** `curl -fsSL https://pixi.sh/install.sh | bash`. It
  installs everything else: CUDA libraries, libcudf, Rust, JDK 17, Maven, Thrift, the mysql
  client, and Python with DuckDB.
- **Data:** TPC-H parquet at `$DATA_ROOT/tpch_sf<N>/<table>/*.parquet` (default `DATA_ROOT` is
  `/scratch/sirius/datasets`). Use local or parallel storage, not NFS. SF1000 is about 266 GB,
  SF3000 about 1.2 TB.
- **Network access** for the first builds: conda packages, Maven, Cargo crates, a Go module.

## Running tests

| script | what it checks |
|---|---|
| `tests/4cn_tpch_joins_sf1000.sh` | TPC-H q14 q05 q07 q08 q09 q12 q19 on N CNs; NIXL hops; per-query leak check |
| `tests/2cn_tpch_joins.sh` | the same queries on 2 CNs at SF1 |
| `tests/2cn_files_group_by.sh` | a two-phase GROUP BY across 2 CNs |

Settings for the 4-CN script, all through the environment:

| variable | default | meaning |
|---|---|---|
| `SF` / `TPCH_DATA` | `1000` / `$DATA_ROOT/tpch_sf$SF` | scale factor / dataset root |
| `TPCH_QUERIES` | `q14 q05 q07 q08 q09 q12 q19` | queries from `tests/tpch/` |
| `GPUS` | `0 1 2 3` | one CN per listed GPU |
| `GPU_FRACTION` | `0.85` | share of each GPU reserved for the CN's slab pool |
| `HOST_BYTES` | 128 GiB | host spill memory per CN |
| `PIPELINE_THREADS` | `4` | engine pipeline threads per CN |
| `RUN_ROOT` | `$RUN_ROOT_BASE/tpch-joins-sf$SF` | logs (`run/`) and cached DuckDB answers (`oracle/`) |
| `PIN`, `PIN_TIER`, `PIN_COMPRESSION` | `0`, `host`, `0` | pin `lineitem` + `orders` on every CN before the queries (`harness/pin.sh`) |
| `FE_WHOLE_FILE_RANGES` | `$PIN` | whole files per CN (FE patch) instead of byte ranges |
| `INJECT_FAILURE_QUERY` | unset | first run this query with one fragment failed on purpose, and require the CNs to hold nothing afterwards |
| `ENGINE_LOGS` | `0` | `1` writes each CN's engine log to `run/engine-cn<i>/` (`SIRIUS_LOG_LEVEL`, default `info`) |
| `ALLOW_BUSY_GPUS` | `0` | `1` skips the check that the selected GPUs are idle |
| `FE_*_PORT`, `PORT_BASE`, `PORT_STRIDE` | 9031/8031/9021/9011, 9100, 10 | FE ports and CN port range; non-default so another FE can run alongside |

Every run checks, after each query, that every CN's `leak counters` are back to zero
(`harness/cn_leak_check.sh`). A failed query must not leave GPU memory behind. This needs a CN
with the failed-query cleanup (Sirius `8979372b` or later); an older CN logs no counters, and the
check passes trivially.

## Benchmarks

```bash
harness/bench.sh --sf "1000 3000" --queries "q14 q07 q12 q19" --iterations 3
harness/bench.sh --sf 3000 --fresh-per-query --label cold      # new cluster for every query
harness/bench.sh --sf 3000 --queries "q05 q08 q09" --hinted    # join-hinted SQL from tests/tpch-hinted/
```

`--hinted` runs the queries in `tests/tpch-hinted/` instead of `tests/tpch/` (any query without
a hinted file uses the standard text). Results are still checked against DuckDB on the standard
text. See [`tests/tpch-hinted/README.md`](tests/tpch-hinted/README.md) for the join orders.

Each iteration starts a fresh FE and fresh CNs. Results go to
`$RUN_ROOT_BASE/bench/<timestamp>_<label>/`: `runtimes.csv`
(`engine,query,iteration,runtime_s,status,sf`), `summary.md` (min, median and max of the passing
runs), and each cluster's logs. Times are the StarRocks query wall time, to the millisecond.

### Reference results (4× GB200, one CN per GPU, 156 GiB pool each)

| run | passing | times |
|---|---|---|
| SF1000, byte ranges (stock FE) | 7/7 | q14 5.6 s, q05 2.0 s, q07 2.1 s, q08 2.5 s, q09 5.7 s, q12 1.3 s, q19 1.6 s |
| SF1000, whole files, unpinned | 6/7 | q14 6.3 s, q05 2.1 s, q07 2.4 s, q08 2.8 s, q12 1.4 s, q19 2.0 s; q09 out of GPU memory |
| SF1000, whole files, `PIN=1 PIN_COMPRESSION=1` | 6/7 | pin 45 s; q14 2.7 s, q05 1.0 s, q07 4.6 s, q08 1.1 s, q12 1.1 s, q19 1.8 s; q09 out of GPU memory |
| SF3000 | 4/7 | q14 20 s, q07 24 s, q12 8 s, q19 20 s |
| SF3000, exchange spill (Sirius `36235217`), `HOST_BYTES=256GiB` | q05 q08 pass | q05 39.5 s, q08 34.9 s; q09 out of GPU memory |
| SF3000, exchange spill + `--hinted`, `HOST_BYTES=256GiB` | 3/3 | q05 56.3 s, q08 33.4 s, q09 28.3 s |

These are single runs. The pinned run used `HOST_BYTES=320GiB` per CN, and each CN pinned all of
`lineitem` and `orders`.

q05, q08 and q09 run out of GPU memory at SF3000. Each one shuffles the unfiltered `lineitem`
before any selective join: about 126 GB of scan output per CN plus about 94 GB arriving from
peers, against a 168 GB pool. Fixes are tracked in the PR: runtime filters, streaming the scan
output, and spilling.

## The StarRocks FE patch

`tests/patches/starrocks-fe-files-query-whole-file-ranges.patch` adds the FE setting
`files_query_whole_file_ranges`. With it on, FILES() scans hand each CN whole parquet files.
`setup/build-fe.sh` applies it.

**Only pinned runs need it.** Stock StarRocks cuts files at instance byte boundaries, so one
parquet file can be split across CNs (FILES() marks every file splittable).

- **The current CN (Sirius `a9c4b340` and later)** reads exactly the row groups its byte ranges
  own, using StarRocks' start-offset rule, so unpinned runs work with stock FE behavior. That's
  the default: `FE_WHOLE_FILE_RANGES=0`.
- **Pinned tables** serve a scan whose file set is a subset of the pin, never a byte range of a
  file. So `PIN=1` turns whole files on, and the script stops if the FE doesn't know the setting.
- **Older CNs** refuse split files ("byte-range splits do not tile the parquet file") and need
  `FE_WHOLE_FILE_RANGES=1`.

## Troubleshooting

| symptom | cause and fix |
|---|---|
| `port N is already in use` | Another FE or CN holds it. Set `FE_*_PORT` / `PORT_BASE`. |
| `GPUs ... already have compute processes` | Someone else is on the selected GPUs. Pick others with `GPUS`, or wait. |
| `mkdir: cannot create directory '/scratch/...'` | Set `RUN_ROOT_BASE` to a writable local directory. |
| `FE ... lacks files_query_whole_file_ranges` | The FE was built without the patch. Rerun `setup/build-fe.sh` (`CLEAN=1` if an older FE was built). |
| FE build: `wrong number of type arguments; required 3` | Built without the `THRIFT=` override. Use `setup/build-fe.sh`. |
| `pip install --user` blocked (PEP 668), or no `python3-venv` | `setup/build-ucx-nixl.sh` installs meson/ninja/pybind11 with `pip --target`. |
| meson: `Clock skew detected` | The build dir is on NFS. `setup/build-ucx-nixl.sh` builds in `NIXL_BUILD_DIR` on local disk. |
| CN build: `'stdbool.h' file not found` (nixl-sys) | Built without Sirius's `scripts/cn-env.sh`. Use `setup/build-cn.sh`. |
| CN link: `undefined reference to cusolverDn...@libcusolver.so.12` | Needs the cuSOLVER link shim. Use `setup/build-cn.sh`. |
| engine configure: `patch does not apply` | `build/release` is stale. Run `CLEAN=1 setup/build-engine.sh`. |
| CN log: `backend 'UCX' not found` | The UCX plugin didn't load. Check `$TOOLS_DIR/nvda_nixl/lib/*-linux-gnu/plugins/libplugin_UCX.so`. |
| `out_of_memory ... Maximum pool size exceeded` | The query needs more than one CN's GPU pool (q05, q08 and q09 at SF3000). |

The step-by-step version of the 4-CN setup, with the reasoning behind each workaround, is in
[`tests/4cn_tpch_joins_sf1000.md`](tests/4cn_tpch_joins_sf1000.md).
