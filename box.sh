# Box profile: 4x GB200 (189 GB each), aarch64, 144 cores, 1.7 TB RAM. Sourced by env.sh; the
# environment still wins. Notes and reference results: BOX.md.

# The original TPC-H datasets on GPFS. /opt/sirius-ci/datasets is a different, 3-6x slower
# copy; don't use it for baselines.
: "${DATA_ROOT:=/scratch/sirius/datasets}"
# Local disk; also where the cached DuckDB answers live.
: "${RUN_ROOT_BASE:=/tmp/$USER/sirius-starrocks-runs}"

# One CN per GPU, 85% of each GPU's 189 GB for its pool (about 156 GiB).
: "${GPUS:=0 1 2 3}"
: "${GPU_FRACTION:=0.85}"
# 128 GiB of host spill per CN. SF3000 wants $((256 << 30)); 4 CNs then hold about 1 TiB.
: "${HOST_BYTES:=$((128 << 30))}"
: "${DUCKDB_MEMORY_LIMIT:=512GB}"
: "${PIPELINE_THREADS:=4}"
