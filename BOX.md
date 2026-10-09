# Box: AWS g7e (RTX PRO 6000 Blackwell)

**Not yet run on AWS.** The settings follow from the instance specs and from runs on the GB200 box; the first run on each size should confirm them. Record what you measure here.

| size | GPUs | GPU memory | vCPUs | RAM | instance store | network |
|---|---:|---:|---:|---:|---|---:|
| g7e.2xlarge | 1 | 96 GB | 8 | 64 GiB | 1× 1.9 TB | 50 Gbps |
| g7e.4xlarge | 1 | 96 GB | 16 | 128 GiB | 1× 1.9 TB | 50 Gbps |
| g7e.8xlarge | 1 | 96 GB | 32 | 256 GiB | 1× 1.9 TB | 100 Gbps |
| g7e.12xlarge | 2 | 192 GB | 48 | 512 GiB | 1× 3.8 TB | 400 Gbps |
| g7e.24xlarge | 4 | 384 GB | 96 | 1024 GiB | 2× 3.8 TB | 800 Gbps |
| g7e.48xlarge | 8 | 768 GB | 192 | 2048 GiB | 4× 3.8 TB | 1600 Gbps |

## What differs from the GB200 box

- **x86_64, sm_120.** The engine already builds for sm_120 (`CMAKE_CUDA_ARCHITECTURES` includes `120a`). Use a CUDA 13 driver (580 or newer).
- **No NVLink.** CNs exchange batches over PCIe; NIXL/UCX uses `cuda_ipc` where peer access works and falls back otherwise.
- **One GPU on the 2xlarge, 4xlarge and 8xlarge.** The test then runs a single CN and skips the NIXL hop check. The multi-CN paths need a 12xlarge or larger.
- **Less GPU memory per CN** (about 76 GiB of pool against 156 GiB on GB200), so the same scale factor needs more CNs or more host spill.

## Setup

```bash
# 1. Instance-store NVMe (skip on the Deep Learning AMI, which mounts it at /opt/dlami/nvme).
#    One disk: format it. Several (24xlarge, 48xlarge): stripe them first. This erases the disks.
lsblk                                                   # find the instance-store devices
sudo mkfs.xfs /dev/nvme1n1                              # or: sudo mdadm --create /dev/md0 --level=0 --raid-devices=2 /dev/nvme1n1 /dev/nvme2n1 && sudo mkfs.xfs /dev/md0
sudo mkdir -p /mnt/nvme && sudo mount /dev/nvme1n1 /mnt/nvme && sudo chown "$USER" /mnt/nvme

# 2. Work on the NVMe too: builds take ~31 GB.
export WORK=/mnt/nvme
git clone -b box/aws-g7e https://github.com/aocsa/starrocks-setup-test-tools.git $WORK/starrocks-setup-test-tools
cd $WORK/starrocks-setup-test-tools
setup/check-prereqs.sh && setup/all.sh

# 3. Data and a first run (DATA_ROOT defaults to the NVMe)
setup/gen-data.sh 1
SF=1 tests/4cn_tpch_joins_sf1000.sh                     # one CN per GPU
```

Instance store is wiped when the instance stops: keep generated data on an EBS volume or S3 if you need it again.

## Sizing (estimates)

The GB200 box runs SF1000 comfortably and SF3000 per query on 4× 156 GiB of pool. By total pool:

| size | CNs × pool | start with | then try |
|---|---|---|---|
| 2xlarge, 4xlarge, 8xlarge | 1 × 76 GiB | SF1, SF100 | SF300 |
| 12xlarge | 2 × 76 GiB | SF100 | SF300–1000 |
| 24xlarge | 4 × 76 GiB | SF300 | SF1000 |
| 48xlarge | 8 × 76 GiB | SF1000 | SF3000 |

- **Build on a large size.** A cold engine build is CPU-bound; on a 2xlarge (8 vCPUs) it takes hours. Build once on a big instance and reuse the image, or raise the size for the build.
- **RAM on the small sizes.** A 2xlarge has 64 GiB, so the defaults give the CN 25 GiB of host spill and DuckDB's check 25 GB. Keep SF small there.
