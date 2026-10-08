# StarRocks + Sirius on GPUs: setup, tests and benchmarks

Scripts that build [Sirius](https://github.com/sirius-db/sirius) as GPU compute nodes (CNs) for a StarRocks FE and run TPC-H on them.
- **How a query runs:** the FE plans it; each CN runs fragments on one GPU; CNs exchange GPU batches directly over NIXL.
- **Correctness:** every query result is checked against DuckDB on the same parquet.

**Sirius code under test:** the StarRocks PR stack, [sirius-db/sirius#2037](https://github.com/sirius-db/sirius/pull/2037) through [#2062](https://github.com/sirius-db/sirius/pull/2062), branch `stacked/sr-runtime-filters` (set in `env.sh`). Switch to `main` once the stack has merged.

## Fresh machine, start to finish

Tested on 4× GB200 (aarch64), 1.7 TB RAM, Ubuntu 24.04, driver 580, CUDA 13.0.

```bash
# 0. System packages (once, as root) and pixi (once, as you)
sudo apt install build-essential pkg-config git curl numactl python3-pip libibverbs-dev
curl -fsSL https://pixi.sh/install.sh | bash        # then open a new shell

# 1. Code and builds: clones Sirius next to this repo; builds UCX/NIXL, the engine, the FE and the CN
export WORK=$HOME                                    # any local directory; builds use ~31 GB, caches ~9 GB in $HOME
git clone https://github.com/aocsa/starrocks-setup-test-tools.git $WORK/starrocks-setup-test-tools
cd $WORK/starrocks-setup-test-tools
setup/all.sh

# 2. Data: TPC-H parquet under $DATA_ROOT (default /scratch/sirius/datasets)
export DATA_ROOT=/scratch/sirius/datasets            # skip generation if the data is already there
setup/gen-data.sh 1 1000 3000                        # SF1000 ~266 GB, SF3000 ~1.13 TB

# 3. Smoke test: 2 CNs, SF1, under a minute
GPUS="0 1" SF=1 tests/4cn_tpch_joins_sf1000.sh

# 4. The benchmarks: 4 CNs, the 7 TPC-H join queries, each checked against DuckDB
tests/4cn_tpch_joins_sf1000.sh                                  # SF1000
SF=3000 HOST_BYTES=$((256 << 30)) tests/4cn_tpch_joins_sf1000.sh # SF3000 (needs host spill)

# 5. Timings across iterations: runtimes.csv + summary.md per run
harness/bench.sh --sf 1000 --iterations 3
HOST_BYTES=$((256 << 30)) harness/bench.sh --sf 3000 --fresh-per-query
```

**How long it takes:**
- **`setup/all.sh`:** 6 minutes with warm pixi/cargo/Maven caches (measured on 4× GB200, 144 cores). On an empty machine it also downloads about 9 GB of packages. Earlier cold builds took about 15 minutes for the engine, 10 for the FE and 10 for UCX/NIXL (these three run in parallel), then 2 for the CN.
- **Data:** SF1 takes a minute.
- **First run at a scale factor:** DuckDB computes the reference answers, several minutes per query at SF3000. They're cached in `$RUN_ROOT_BASE/oracle`, so later runs skip that.

Every script can be rerun. `setup/check-prereqs.sh` lists anything missing on the box. Each build step also runs alone (`setup/build-{ucx-nixl,engine,fe,cn}.sh`); its log is in `$RUN_ROOT_BASE/setup-logs/`.

## Layout

```
env.sh      paths every script sources: WORK, SIRIUS_DIR, SIRIUS_BRANCH, TOOLS_DIR, DATA_ROOT, RUN_ROOT_BASE
setup/      check-prereqs.sh, build-ucx-nixl.sh, build-engine.sh, build-fe.sh, build-cn.sh, all.sh, gen-data.sh
tests/      4cn_tpch_joins_sf1000.sh   N CNs (default 4) at any SF; despite the name, SF and GPUS are settings
            2cn_tpch_joins.sh, 2cn_files_group_by.sh   older 2-CN checks
            tpch/q01..q22.sql          TPC-H over FILES(); tpch-hinted/ join-ordered q05/q08/q09
            tpch_files_compare.py      the DuckDB check; patches/ the optional FE patch
harness/    bench.sh (SF x queries x iterations), cn_leak_check.sh, pin.sh
```

Default directory layout (override any path in the environment):

```
$WORK/starrocks-setup-test-tools   this repo
$WORK/sirius                       Sirius checkout (SIRIUS_DIR)
$WORK/tools                        UCX + NIXL installs (TOOLS_DIR)
$RUN_ROOT_BASE                     logs, results, cached DuckDB answers (default /tmp/$USER/sirius-starrocks-runs)
```

## What a run does and checks

`tests/4cn_tpch_joins_sf1000.sh` runs these steps:
1. starts an isolated FE and one CN per GPU, each CN bound to its GPU's CPU socket;
2. waits until the FE sees every CN;
3. runs each query, compares the result with DuckDB, and checks that every CN's `leak counters` are back to zero;
4. checks that the CNs actually shipped data to each other over NIXL;
5. prints PASS/FAIL per query and shuts everything down.

A failed query doesn't stop the run. A dead CN does: the remaining queries show SKIP.

**Comparison:** rows must match DuckDB. Identifiers and dates must match exactly; measures within a relative 5e-3, because the CN computes decimals in FP64.

**Output:**
- `$RUN_ROOT/run/`: per-query results and errors, FE logs, and `cn<i>.log`.
- `harness/bench.sh` writes `$RUN_ROOT_BASE/bench/<timestamp>_<label>/`, with `runtimes.csv` (`engine,query,iteration,runtime_s,status,sf`) and `summary.md`.
- Every bench iteration starts a fresh cluster. `--fresh-per-query` also restarts it for every query.

## Settings

All are environment variables.

| variable | default | meaning |
|---|---|---|
| `SF` / `TPCH_DATA` | `1000` / `$DATA_ROOT/tpch_sf$SF` | scale factor / dataset directory |
| `TPCH_QUERIES` | `q14 q05 q07 q08 q09 q12 q19` | any of `tests/tpch/q01`–`q22`; the CN runs the 7 join queries and q06 today |
| `GPUS` | `0 1 2 3` | one CN per listed GPU |
| `HOST_BYTES` | 128 GiB | host memory per CN for spilling GPU data; SF3000 needs `$((256 << 30))` |
| `GPU_FRACTION` | `0.85` | share of each GPU reserved for the CN's memory pool |
| `PIPELINE_THREADS` | `4` | engine pipeline threads per CN |
| `QUERY_TIMEOUT_S` | `3600` | FE query timeout |
| `DUCKDB_MEMORY_LIMIT` | `512GB` | cap for the DuckDB check |
| `PIN`, `PIN_COMPRESSION` | `0`, `0` | pin `lineitem` + `orders` on every CN first (needs the FE patch below) |
| `INJECT_FAILURE_QUERY` | unset | run this query once with a fragment failed on purpose, then require the CNs to hold nothing |
| `ENGINE_LOGS` | `0` | `1` keeps each CN's engine log in `run/engine-cn<i>/` |
| `ALLOW_BUSY_GPUS` | `0` | `1` skips the check that the GPUs are idle |
| `FE_*_PORT`, `PORT_BASE`, `PORT_STRIDE` | 9031/8031/9021/9011, 9100, 10 | non-default ports, so another FE can run alongside |

Sirius CN settings that matter for benchmarks:
- `SIRIUS_CN_RUNTIME_FILTERS=0` turns off runtime filters (on by default).
- `SIRIUS_CN_STREAM_OUTPUT=0` ships a fragment's output after it finishes instead of while it runs.

`harness/bench.sh --hinted` runs the join-ordered q05/q08/q09 from `tests/tpch-hinted/` instead (see its README).

## Reference results

4× GB200, one CN per GPU (156 GiB pool each), Sirius at the top of the stack (`f4780e74`, runtime filters on), data in `/scratch/sirius/datasets`. These are single runs, and the spread between runs is large (SF3000 q05 has ranged 28–41 s), so treat differences under about 20% as noise.

| query | SF1000 (Oct 6) | SF3000, each query on a fresh cluster (Oct 8) | SF3000, all 7 in sequence on one cluster (Oct 8) |
|---|---|---|---|
| q14 | 5.2 s | 26.4 s | 35.1 s |
| q05 | 1.9 s | 28.7 s | 31.2 s |
| q07 | 2.0 s | 32.9 s | 23.1 s |
| q08 | 2.1 s | 55.9 s | 26.5 s |
| q09 | 2.4 s | 36.0 s | FAIL: out of GPU memory in its scan |
| q12 | 1.7 s | 29.5 s | FAIL: fallout from q09 |
| q19 | 1.6 s | 31.2 s | 12.2 s |
| **passing** | **7/7** | **7/7** | **5/7** |

- **SF3000 settings:** `HOST_BYTES=$((256 << 30))`, `harness/bench.sh --sf 3000` and `--fresh-per-query`.
- **Why q12 fails in the sequence:** after the FE cancels q09, q09's fragments keep running on the other CNs and hold their GPU memory. q12 then can't allocate exchange buffers ("0 available"). Interrupting cancelled fragments is an open item in Sirius.
- **Smoke test** (2 CNs, freshly generated SF1): 7/7, 28 s in total.

## The optional FE patch

`tests/patches/starrocks-fe-files-query-whole-file-ranges.patch` adds the FE setting `files_query_whole_file_ranges`, which hands each CN whole parquet files. `setup/build-fe.sh` applies it.
- **Only pinned runs (`PIN=1`) need it.** A pinned table serves whole files.
- **Unpinned runs work on a stock FE.** The CN reads the byte ranges the FE assigns it.

## Troubleshooting

| symptom | cause and fix |
|---|---|
| `port N is already in use` | Another FE or CN holds it. Set `FE_*_PORT` / `PORT_BASE`. |
| `GPUs ... already have compute processes` | Someone else is on those GPUs. Pick others with `GPUS`, or wait. |
| `mkdir: cannot create directory '/scratch/...'` | Set `RUN_ROOT_BASE` to a writable local directory. |
| `... exists but has no parquet for: ...` (`gen-data.sh`) | An earlier generation stopped part way. Remove that directory and rerun. |
| `FE ... lacks files_query_whole_file_ranges` | The FE was built without the patch (only `PIN=1` needs it). Rerun `CLEAN=1 setup/build-fe.sh`. |
| FE build: `wrong number of type arguments; required 3` | Built without the `THRIFT=` override. Use `setup/build-fe.sh`. |
| meson: `Clock skew detected` | The NIXL build dir is on NFS. `setup/build-ucx-nixl.sh` builds in `NIXL_BUILD_DIR` on local disk. |
| CN build: `'stdbool.h' file not found` (nixl-sys) | Built without Sirius's `scripts/cn-env.sh`. Use `setup/build-cn.sh`. |
| CN link: `undefined reference to cusolverDn...@libcusolver.so.12` | Needs the cuSOLVER link shim. Use `setup/build-cn.sh`. |
| engine configure: `patch does not apply` | `build/release` is stale. Run `CLEAN=1 setup/build-engine.sh`. |
| CN log: `backend 'UCX' not found` | The UCX plugin didn't load. Check `$TOOLS_DIR/nvda_nixl/lib/*-linux-gnu/plugins/libplugin_UCX.so`. |
| `out_of_memory ... Maximum pool size exceeded`, or `OOM at operator` | The query needs more than one CN's GPU pool. At SF3000 set `HOST_BYTES=$((256 << 30))`. q09 can still run out in a long sequence (see the results). |

Why each build workaround exists is explained in [`tests/4cn_tpch_joins_sf1000.md`](tests/4cn_tpch_joins_sf1000.md).
