# Box profile: AWS g7e (NVIDIA RTX PRO 6000 Blackwell, 96 GB each, x86_64). Sourced by env.sh;
# the environment still wins. Setup and sizing notes: BOX.md. Not yet run on AWS.
#
#   size        GPUs  vCPUs  RAM GiB  instance store
#   2xlarge        1      8       64  1x 1.9 TB
#   4xlarge        1     16      128  1x 1.9 TB
#   8xlarge        1     32      256  1x 1.9 TB
#   12xlarge       2     48      512  1x 3.8 TB
#   24xlarge       4     96     1024  2x 3.8 TB
#   48xlarge       8    192     2048  4x 3.8 TB
#
# env.sh's defaults already scale with the size, read from nvidia-smi and /proc/meminfo: one CN
# per GPU, host spill at 40% of RAM per CN (25 GiB on a 2xlarge, capped at 128 GiB), DuckDB's
# check at another 40%. So this profile only sets what is specific to AWS.

# Data and runs on the instance-store NVMe (the Deep Learning AMI mounts it at /opt/dlami/nvme;
# BOX.md mounts it at /mnt/nvme otherwise). The root EBS volume is too small for SF1000.
for _nvme in /opt/dlami/nvme /mnt/nvme; do
    if [[ -d "$_nvme" && -w "$_nvme" ]]; then
        : "${DATA_ROOT:=$_nvme/datasets}"
        : "${RUN_ROOT_BASE:=$_nvme/runs/$USER}"
        break
    fi
done
unset _nvme

# 85% of each 96 GB GPU for the CN's pool (about 76 GiB). No NVLink: CNs exchange over PCIe.
: "${GPU_FRACTION:=0.85}"
: "${PIPELINE_THREADS:=4}"
