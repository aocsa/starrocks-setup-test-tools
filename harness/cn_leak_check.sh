# Sourced by the multi-CN tests.
#
# A CN with the failed-query cleanup (Sirius d798509d and later) logs a "leak counters" line
# after each fragment, receiver drain and FE cancel: waiting receivers, parked senders, received
# batches, engine-parked fragments, and allocated direct-exchange buffers. Between queries every
# count must be zero. One that stays non-zero is GPU memory a finished or failed query left
# behind, which later queries then run out of. A CN without that cleanup logs no such lines, and
# the check passes trivially.

# cn_leaks E2E_DIR NUM_CNS [TIMEOUT_S]
# Waits up to TIMEOUT_S (default 20) for the last "leak counters" line of every
# E2E_DIR/cn<i>.log to read all zero. The wait covers the FE's cancel of a failed query, which
# reaches the CNs after the client already has its error. On timeout, prints what is still held
# and returns 1.
cn_leaks() {
    local e2e=$1 num_cns=$2 deadline=$((SECONDS + ${3:-20})) i line
    local -a held
    while true; do
        held=()
        for ((i = 0; i < num_cns; i++)); do
            line=$(grep 'leak counters' "$e2e/cn$i.log" | tail -n 1 || true)
            if grep -qE '\b(receivers|parked_senders|remote_batches|parked_fragments|direct_buffers)=[1-9]' <<<"$line"; then
                held+=("cn$i:${line#*leak counters}")
            fi
        done
        [[ ${#held[@]} -eq 0 ]] && return 0
        if [[ $SECONDS -ge $deadline ]]; then
            printf '   still held: %s\n' "${held[@]}" >&2
            return 1
        fi
        sleep 1
    done
}
