#!/usr/bin/env bash
# FE + two Sirius CNs on GPU (or MIG) ordinals 0 and 1 run:
#   SELECT region, SUM(amount) FROM FILES("...") GROUP BY region
# Each CN's GPU pool is a NIXL-registered slab: the shuffle WRITEs a batch's
# buffers straight into receive buffers the peer allocated in its own slab.
# Control (Md, Alloc, Release, Packed) rides unpatched transmit_chunk on the
# advertised brpc port. Rows must match DuckDB (rel 1e-6). Tiny FILES() shards
# may all land on one CN; the other CN still runs the merge.
# Require a non-empty hop (`bytes=N` with N>0), a matching receive on the peer,
# and transmit_chunk in the logs.
#
# Requires a release CN linked to libsirius (`cargo build --release -p sirius-starrocks-cn`).
set -euo pipefail

# Shared boxes can serialize GPU runs with a lock: set GPU_LOCK_FILE to a lock that a wrapper
# holds (flock) while this script runs, and the script refuses to start unless it is held.
if [[ -n "${GPU_LOCK_FILE:-}" && -w "$(dirname "$GPU_LOCK_FILE")" ]]; then
    exec 8>"$GPU_LOCK_FILE"
    if flock -n 8; then
        flock -u 8
        exec 8>&-
        echo "refusing to start: GPU_LOCK_FILE=$GPU_LOCK_FILE is not held by a wrapper" >&2
        exit 2
    fi
    exec 8>&-
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../env.sh
source "$HERE/../env.sh"
require_sirius

# nixl / UCX paths, UCX_TLS, and LD_LIBRARY_PATH (engine .so, nixl, UCX, pixi).
# shellcheck source=/dev/null
source "$SR_DIR/scripts/cn-env.sh"

E2E=${SIRIUS_2CN_E2E_DIR:-$RUN_ROOT_BASE/2cn-files-group-by/run}
CN_BIN=${CN_BIN:-$SR_DIR/target/release/sirius-starrocks-cn}
STARROCKS_FE=${STARROCKS_FE:-$SR_DIR/starrocks/output/fe}
MYSQL=${MYSQL:-$SR_DIR/.pixi/envs/client/bin/mysql}
PYTHON=${PYTHON:-$REPO_ROOT/.pixi/envs/default/bin/python}
SIRIUS_LIB=${SIRIUS_LIB:-$REPO_ROOT/build/release/extension/sirius}

# Off the StarRocks defaults (9030/8030/9020/9010): another FE may already hold them.
FE_QUERY_PORT=${FE_QUERY_PORT:-9031}
FE_HTTP_PORT=${FE_HTTP_PORT:-8031}
FE_RPC_PORT=${FE_RPC_PORT:-9021}
FE_EDIT_LOG_PORT=${FE_EDIT_LOG_PORT:-9011}
PORT_BASE=${PORT_BASE:-9100}
PORT_STRIDE=${PORT_STRIDE:-10}
export UCX_TLS=${UCX_TLS:-cuda_copy,cuda_ipc,tcp,self}

[ -x "$CN_BIN" ] || {
    echo "no CN binary at $CN_BIN — build with: cargo build --release -p sirius-starrocks-cn" >&2
    exit 1
}
[ -x "$STARROCKS_FE/bin/start_fe.sh" ] || {
    echo "no packaged StarRocks FE at $STARROCKS_FE" >&2
    exit 1
}
[ -x "$MYSQL" ] || {
    echo "mysql client not found at $MYSQL" >&2
    exit 1
}
[ -x "$PYTHON" ] || {
    echo "python not found at $PYTHON" >&2
    exit 1
}
[ -e "$SIRIUS_LIB/libsirius.so" ] || {
    echo "libsirius.so missing under $SIRIUS_LIB — build the engine first" >&2
    exit 1
}

export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-21-amazon-corretto}
# A leftover CUDA_VISIBLE_DEVICES in the operator shell would pin both CNs to one MIG.
unset CUDA_VISIBLE_DEVICES

rm -rf "$E2E"
mkdir -p "$E2E/sales" "$E2E/cn0" "$E2E/cn1" "$E2E/fe/"{conf,meta,log}

cn0_pid=""
cn1_pid=""
dump_logs_on_fail=1

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ "$dump_logs_on_fail" -eq 1 && "$status" -ne 0 ]]; then
        echo "---- fe.out (tail) ----" >&2
        tail -n 80 "$E2E/fe/log/fe.out" 2>/dev/null || tail -n 80 "$E2E/fe-start.log" 2>/dev/null || true
        echo "---- cn0.log (tail) ----" >&2
        tail -n 120 "$E2E/cn0.log" 2>/dev/null || true
        echo "---- cn1.log (tail) ----" >&2
        tail -n 120 "$E2E/cn1.log" 2>/dev/null || true
    fi
    if [[ -x "$E2E/fe/bin/stop_fe.sh" ]]; then
        "$E2E/fe/bin/stop_fe.sh" >/dev/null 2>&1 || true
    fi
    for pid in $cn0_pid $cn1_pid; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    sleep 1
    for pid in $cn0_pid $cn1_pid; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    exit "$status"
}
trap cleanup EXIT INT TERM

set_fe_conf() {
    local file=$1 key=$2 value=$3
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        printf '%s = %s\n' "$key" "$value" >>"$file"
    fi
}

wait_port() {
    local host=$1 port=$2 timeout=$3
    "$PYTHON" - "$host" "$port" "$timeout" <<'PY'
import socket, sys, time
host, port, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
deadline = time.time() + timeout
while time.time() < deadline:
    sock = socket.socket()
    sock.settimeout(1)
    try:
        if sock.connect_ex((host, port)) == 0:
            sys.exit(0)
    finally:
        sock.close()
    time.sleep(0.25)
sys.exit(1)
PY
}

mysql_exec() {
    "$MYSQL" --host 127.0.0.1 --port "$FE_QUERY_PORT" --user root --batch --raw --skip-column-names "$@"
}

mysql_table() {
    "$MYSQL" --host 127.0.0.1 --port "$FE_QUERY_PORT" --user root --batch --raw "$@"
}

echo "== writing sales parquet =="
"$PYTHON" - "$E2E/sales" <<'PY'
import sys
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
schema = pa.schema([("region", pa.string()), ("amount", pa.int64())])
pq.write_table(
    pa.table(
        {
            "region": ["east", "west", "east", "north", "south"],
            "amount": [10, 20, 5, 3, 8],
        },
        schema=schema,
    ),
    out / "sales_0.parquet",
)
pq.write_table(
    pa.table(
        {
            "region": ["west", "east", "north", "south", "midwest"],
            "amount": [7, 3, 11, 1, 4],
        },
        schema=schema,
    ),
    out / "sales_1.parquet",
)
PY

# The NIXL transport needs the slab pool, which reserves usage_limit_fraction of the GPU up front.
cat >"$E2E/sirius.yaml" <<'YAML'
sirius:
  topology:
    num_gpus: 1
  memory:
    gpu:
      usage_limit_fraction: 0.85
      allocator: slab
    host:
      capacity_bytes: 17179869184
  executor:
    pipeline:
      num_threads: 4
YAML

echo "== packaging isolated FE =="
cp -a "$STARROCKS_FE/bin" "$E2E/fe/bin"
cp -a "$STARROCKS_FE/conf/." "$E2E/fe/conf/"
ln -sfn "$STARROCKS_FE/lib" "$E2E/fe/lib"
ln -sfn "$STARROCKS_FE/webroot" "$E2E/fe/webroot"
ln -sfn "$STARROCKS_FE/hive-udf" "$E2E/fe/hive-udf"
ln -sfn "$STARROCKS_FE/spark-dpp" "$E2E/fe/spark-dpp"
# plugins/ is FE runtime state, absent from a freshly built package; a symlink to it
# dangles and the FE dies with "failed to create FE plugin dir".
mkdir -p "$E2E/fe/plugins"
set_fe_conf "$E2E/fe/conf/fe.conf" meta_dir "$E2E/fe/meta"
set_fe_conf "$E2E/fe/conf/fe.conf" sys_log_dir "$E2E/fe/log"
set_fe_conf "$E2E/fe/conf/fe.conf" audit_log_dir "$E2E/fe/log"
set_fe_conf "$E2E/fe/conf/fe.conf" priority_networks "127.0.0.1/32"
set_fe_conf "$E2E/fe/conf/fe.conf" qe_query_timeout_second 600
set_fe_conf "$E2E/fe/conf/fe.conf" query_port "$FE_QUERY_PORT"
set_fe_conf "$E2E/fe/conf/fe.conf" http_port "$FE_HTTP_PORT"
set_fe_conf "$E2E/fe/conf/fe.conf" rpc_port "$FE_RPC_PORT"
set_fe_conf "$E2E/fe/conf/fe.conf" edit_log_port "$FE_EDIT_LOG_PORT"

echo "== starting FE =="
"$E2E/fe/bin/start_fe.sh" --daemon >"$E2E/fe-start.log" 2>&1
wait_port 127.0.0.1 "$FE_QUERY_PORT" 180 || {
    echo "FE did not accept MySQL on :$FE_QUERY_PORT" >&2
    exit 1
}
# start_fe.sh can return before catalog bootstrap is finished.
for _ in $(seq 1 60); do
    if mysql_exec -e "SHOW FRONTENDS" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
mysql_exec -e "SHOW FRONTENDS" >/dev/null

start_cn() {
    local i=$1
    local base=$((PORT_BASE + i * PORT_STRIDE))
    local dir="$E2E/cn$i"
    mkdir -p "$dir"
    # Pin the process to one MIG. CUDA remaps it to ordinal 0 inside the process;
    # never pass CUDA_VISIBLE_DEVICES=MIG-<uuid> (cucascade NVML count fails).
    # NO_COLOR keeps tracing fields as plain key=value for the log checks below.
    setsid env \
        CUDA_VISIBLE_DEVICES="$i" \
        NO_COLOR=1 \
        UCX_TLS="$UCX_TLS" \
        NIXL_PREFIX="${NIXL_PREFIX:-}" \
        NIXL_PLUGIN_DIR="${NIXL_PLUGIN_DIR:-}" \
        NIXL_NO_STUBS_FALLBACK="${NIXL_NO_STUBS_FALLBACK:-1}" \
        LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
        RUST_LOG="${RUST_LOG:-sirius_starrocks_cn=info}" \
        RUST_BACKTRACE=1 \
        stdbuf -oL -eL \
        "$CN_BIN" \
        --fe-host 127.0.0.1 \
        --fe-query-port "$FE_QUERY_PORT" \
        --advertise-host 127.0.0.1 \
        --heartbeat-port "$base" \
        --thrift-port $((base + 1)) \
        --brpc-port $((base + 2)) \
        --http-port $((base + 3)) \
        --starlet-port $((base + 4)) \
        --sirius-config "$E2E/sirius.yaml" \
        < /dev/null >"$E2E/cn$i.log" 2>&1 &
    local pid=$!
    echo "$pid" >"$E2E/cn$i.pid"
    echo "CN$i gpu=$i heartbeat=$base brpc=$((base + 2)) http=$((base + 3)) pid=$pid"
}

echo "== starting CNs =="
start_cn 0
cn0_pid=$(<"$E2E/cn0.pid")
start_cn 1
cn1_pid=$(<"$E2E/cn1.pid")

echo "== waiting for two Alive compute nodes =="
"$PYTHON" - "$MYSQL" "$FE_QUERY_PORT" <<'PY'
import subprocess, sys, time

mysql, port = sys.argv[1], sys.argv[2]
deadline = time.time() + 180
last = ""
while time.time() < deadline:
    proc = subprocess.run(
        [
            mysql,
            "--host",
            "127.0.0.1",
            "--port",
            port,
            "--user",
            "root",
            "--batch",
            "--raw",
            "-e",
            "SHOW COMPUTE NODES",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    last = proc.stdout + proc.stderr
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode == 0 and len(lines) >= 2:
        headers = lines[0].split("\t")
        try:
            alive_idx = headers.index("Alive")
        except ValueError:
            alive_idx = None
        alive = 0
        if alive_idx is not None:
            for row in lines[1:]:
                cols = row.split("\t")
                if len(cols) > alive_idx and cols[alive_idx].lower() in {"true", "1"}:
                    alive += 1
        if alive >= 2:
            print(proc.stdout)
            sys.exit(0)
    time.sleep(2)
print(last, file=sys.stderr)
sys.exit(1)
PY

SALES_URI="file://$E2E/sales/sales_*.parquet"
QUERY=$(cat <<SQL
SELECT region, SUM(amount)
FROM FILES("path"="${SALES_URI}","format"="parquet")
GROUP BY region
SQL
)

echo "== running FILES() GROUP BY =="
mysql_table -e "SET query_timeout = 600; ${QUERY}" | tee "$E2E/query.tsv"
sleep 1

echo "== comparing to DuckDB and checking packed NIXL hops over transmit_chunk =="
"$PYTHON" - "$E2E" <<'PY'
import math
import re
import sys
from pathlib import Path

import duckdb

e2e = Path(sys.argv[1])
sales = e2e / "sales"
query_tsv = (e2e / "query.tsv").read_text()
got = {}
for line in query_tsv.splitlines():
    if not line.strip() or line.startswith("region") or line.startswith("SET "):
        continue
    parts = line.split("\t")
    if len(parts) != 2:
        continue
    region, raw = parts[0], parts[1]
    if region.lower() == "region":
        continue
    got[region] = float(raw)

con = duckdb.connect()
expected_rows = con.execute(
    """
    SELECT region, SUM(amount)
    FROM read_parquet(?)
    GROUP BY region
    ORDER BY region
    """,
    [str(sales / "sales_*.parquet")],
).fetchall()
expected = {region: float(total) for region, total in expected_rows}
if got.keys() != expected.keys():
    raise SystemExit(f"region set mismatch: fe={got} duckdb={expected}")
for region, want in expected.items():
    have = got[region]
    scale = max(abs(want), 1.0)
    if not math.isclose(have, want, rel_tol=1e-6, abs_tol=1e-6 * scale):
        raise SystemExit(f"{region}: fe={have} duckdb={want}")
print("rows match DuckDB:", expected)

hop_re = re.compile(r"shipping packed exchange hop.*\bbytes=(\d+)\b")
recv_re = re.compile(r"received remote packed batches.*\bbatches=(\d+)")
logs = {name: (e2e / f"{name}.log").read_text(errors="replace") for name in ("cn0", "cn1")}
shipped = {
    name: [int(m.group(1)) for m in hop_re.finditer(text) if int(m.group(1)) > 0]
    for name, text in logs.items()
}
received = {
    name: [int(m.group(1)) for m in recv_re.finditer(text) if int(m.group(1)) > 0]
    for name, text in logs.items()
}
if not any(shipped.values()):
    raise SystemExit(f"no non-empty remote packed hop logged (shipped={shipped})")
tc = {name: "transmit_chunk" in text for name, text in logs.items()}
if not any(tc.values()):
    raise SystemExit(f"no transmit_chunk in CN logs (transmit_chunk={tc})")
peer = {"cn0": "cn1", "cn1": "cn0"}
unmatched = [name for name in logs if shipped[name] and not received[peer[name]]]
if unmatched:
    raise SystemExit(
        f"{unmatched} shipped but the peer logged no receive "
        f"(shipped={shipped} received={received})"
    )
print(
    "cross-CN packed NIXL hop over transmit_chunk:",
    {"shipped": shipped, "received": received, "transmit_chunk": tc},
)
PY

dump_logs_on_fail=0
echo "OK: 2-CN FILES() GROUP BY matched DuckDB with a packed NIXL shuffle over transmit_chunk"
