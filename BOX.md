# Box: 4× GB200

The reference machine. `box.sh` holds its settings; this file holds what else is specific to it.

## Hardware

4× GB200 (189 GB each), aarch64, 144 cores, 1.7 TB RAM, Ubuntu 24.04, driver 580, CUDA 13.0. One CN per GPU, each bound to its GPU's CPU socket; NVLink between GPUs.

## Paths and pitfalls

- **Data:** `/scratch/sirius/datasets/tpch_sf{1,10,…,1000,3000,10000}` (GPFS), the default `DATA_ROOT` here. `/opt/sirius-ci/datasets` is a different copy, 3–6× slower; don't use it for baselines.
- **`$HOME` is NFS with a ~200 GB per-user quota.** Filling it breaks git, builds and pixi, so never generate data there. Pixi redirects its repodata cache off NFS on its own.
- **`/raid` (14 TB, local) is root-owned:** `sudo mkdir -p /raid/aocsa && sudo chown aocsa:aocsa /raid/aocsa`.
- **`gh` and `pixi`** are in `~/.pixi/bin`, which isn't on the default PATH (`env.sh` adds it).

## Build times

`setup/all.sh`: 6 minutes with warm pixi/cargo/Maven caches. Cold: about 15 minutes for the engine, 10 for the FE and 10 for UCX/NIXL (in parallel), then 2 for the CN.

## Reference results

One CN per GPU (156 GiB pool each), data in `/scratch/sirius/datasets`. Single runs vary a lot (SF3000 q05 has ranged 28–41 s), so treat differences under about 20% as noise.

**SF1000, 7 join queries, 3 iterations, byte-range splits** (Oct 8, Sirius stack with #2043's review fixes): 21/21 passed. Medians:

| q05 | q07 | q08 | q09 | q12 | q14 | q19 |
|---:|---:|---:|---:|---:|---:|---:|
| 1.80 s | 2.09 s | 2.04 s | 2.33 s | 1.34 s | 4.72 s | 1.84 s |

**Earlier runs** (Sirius `f4780e74`, runtime filters on):

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

- **SF3000 settings:** `HOST_BYTES=$((256 << 30))`, `scripts/bench.sh --sf 3000` and `--fresh-per-query`.
- **Why q12 fails in the sequence:** after the FE cancels q09, q09's fragments keep running on the other CNs and hold their GPU memory. q12 then can't allocate exchange buffers ("0 available"). Interrupting cancelled fragments is an open item in Sirius.
- **Smoke test** (2 CNs, freshly generated SF1): 7/7, 28 s in total.
