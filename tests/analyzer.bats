#!/usr/bin/env bats

load helpers

setup() {
    setup_fixture
    # shellcheck source=../pve-zfs-analyzer.sh
    source "$ANALYZER"
}

write_psi() {
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=%s\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=%s\n' "$2" "$3" >"${PSI_DIR}/$1"
}

# Calculations

@test "hit rate is calculated with two decimals" {
    [ "$(calc_percent 1 3)" = "33.33" ]
    [ "$(calc_percent 5 5)" = "100.00" ]
    [ "$(calc_percent 0 0)" = "0.00" ]
}

@test "PSI stall share is calculated over the interval" {
    # 1.5 s of stall over 30 s
    [ "$(stall_percent 1500000 30)" = "5.00" ]
    [ "$(stall_percent 0 30)" = "0.00" ]
    [ "$(stall_percent 100 0)" = "0.00" ]
}

@test "PSI totals are read from the pressure files" {
    write_psi memory 111 222
    [ "$(get_psi_total some memory)" = 111 ]
    [ "$(get_psi_total full memory)" = 222 ]
}

@test "arcstats values are matched exactly" {
    write_arcstats hits=10 demand_data_hits=7 size=42
    [ "$(get_arc_stat hits)" = 10 ]
    [ "$(get_arc_stat size)" = 42 ]
    [ "$(get_arc_stat missing)" = 0 ]
}

# Verdicts: classify <hit rate> <metadata hit rate> <metadata requests> <evicted>
#                    <memory full stall> <I/O stall> <ghost hits of misses>

@test "verdict: memory stall is critical" {
    [ "$(classify 99.00 99.00 1000 0 6.00 0.00 0.00)" = critical_ram ]
}

@test "verdict: storage bottleneck with ghost hits suggests a larger ARC" {
    [ "$(classify 70.00 99.00 1000 0 0.00 20.00 40.00)" = storage_bottleneck_expand ]
}

@test "verdict: storage bottleneck without ghost hits points to the storage" {
    [ "$(classify 70.00 99.00 1000 0 0.00 20.00 5.00)" = storage_bottleneck ]
}

@test "verdict: low hit rate without I/O stall is stable" {
    [ "$(classify 70.00 99.00 1000 0 0.00 1.00 0.00)" = stable ]
}

@test "verdict: low metadata hit rate" {
    [ "$(classify 95.00 80.00 1000 0 0.00 1.00 0.00)" = metadata ]
}

@test "verdict: ghost hits mean the ARC is too small" {
    [ "$(classify 95.00 99.00 1000 0 0.00 1.00 25.00)" = arc_too_small ]
}

@test "verdict: churn without ghost hits" {
    [ "$(classify 95.00 99.00 1000 6000 0.00 1.00 0.00)" = churn ]
}

@test "verdict: excellent" {
    [ "$(classify 95.00 99.00 1000 0 0.00 1.00 0.00)" = excellent ]
}

@test "suggested max grows by the ghost hit share, rounded up to a GiB" {
    # 8 GiB + 25% = 10 GiB
    [ "$(suggest_max $((8 * GIB)) 25.00 $((32 * GIB)))" = $((10 * GIB)) ]
    # 8 GiB + 30% = 10.4 GiB, rounded up
    [ "$(suggest_max $((8 * GIB)) 30.00 $((32 * GIB)))" = $((11 * GIB)) ]
}

@test "suggested max grows by at most half of the available memory" {
    [ "$(suggest_max $((8 * GIB)) 100.00 $((4 * GIB)))" = $((10 * GIB)) ]
}

@test "descriptions include the suggested tuner command" {
    run describe arc_too_small 95.00 99.00 0 0.00 1.00 25.00 "Max 8.0 GB -> 10.0 GB, e.g. pve-zfs-tuner.sh --min 1024M --max 10G"
    [[ "$output" == *"25.00% of the misses were recently evicted data"* ]]
    [[ "$output" == *"pve-zfs-tuner.sh --min 1024M --max 10G"* ]]
}

# End to end

@test "metadata cache on OpenZFS 2.2+ uses metadata_size" {
    write_arcstats size=$((4 * GIB)) c_min=$GIB c_max=$((8 * GIB)) metadata_size=$((512 * 1048576))
    run "$ANALYZER" --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Metadata Cache:        512 MB (no fixed limit on OpenZFS 2.2+)"* ]]
    [[ "$output" == *"System is idling"* ]]
}

@test "metadata cache before OpenZFS 2.2 uses the fixed limit" {
    write_arcstats size=$((4 * GIB)) c_min=$GIB c_max=$((8 * GIB)) arc_meta_used=$GIB arc_meta_limit=$((6 * GIB))
    run "$ANALYZER" --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Metadata Cache:        1.0 GB / 6.0 GB (limit)"* ]]
}

@test "missing PSI is reported instead of failing" {
    run "$ANALYZER" --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"PSI is not available"* ]]
}

@test "PSI is shown when available" {
    write_psi memory 0 0
    write_psi io 0 0
    run "$ANALYZER" --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAM Stall Pressure:"* ]]
}

@test "missing ZFS is reported" {
    rm -f "$ARCSTATS_FILE"
    run "$ANALYZER" --interval 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"ZFS module is not loaded"* ]]
}

@test "invalid interval is rejected" {
    run "$ANALYZER" --interval 0
    [ "$status" -eq 1 ]
    run "$ANALYZER" --interval abc
    [ "$status" -eq 1 ]
}

@test "root is required" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    unset ZFS_TUNER_SKIP_ROOT_CHECK
    run "$ANALYZER" --interval 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

# Writes arcstats twice: before and in the middle of a 3 second analyzer run
run_with_counter_change() {
    write_arcstats $1
    (
        sleep 1
        write_arcstats $2
    ) &
    run "$ANALYZER" --interval 3 "${@:3}"
    wait
}

@test "hit rates are measured from the counter changes during the interval" {
    run_with_counter_change \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=1000 misses=0 demand_data_hits=1000 demand_data_misses=0 deleted=0" \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=1900 misses=100 demand_data_hits=1900 demand_data_misses=100 deleted=10"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total Efficiency:         90.00% (Total Requests: 1000, Misses: 100)"* ]]
    [[ "$output" == *"Evicted Blocks (Cache):   10"* ]]
    [[ "$output" == *"[EXCELLENT]"* ]]
}

@test "ghost hits lead to a suggested max and a tuner command" {
    echo "MemAvailable:   $((32 * GIB / 1024)) kB" >"$MEMINFO_FILE"
    run_with_counter_change \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=0 misses=0 demand_data_hits=0 demand_data_misses=0 mru_ghost_hits=0 mfu_ghost_hits=0" \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=900 misses=100 demand_data_hits=900 demand_data_misses=100 mru_ghost_hits=20 mfu_ghost_hits=10"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ghost Hits:               30.00% of misses"* ]]
    [[ "$output" == *"ARC is too small"* ]]
    [[ "$output" == *"Max 8.0 GB -> 11.0 GB, e.g. pve-zfs-tuner.sh --min 1024M --max 11G"* ]]
}

@test "JSON output" {
    echo "MemAvailable:   $((32 * GIB / 1024)) kB" >"$MEMINFO_FILE"
    write_psi memory 0 0
    write_psi io 0 0
    run_with_counter_change \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) metadata_size=1024 hits=0 misses=0 mru_ghost_hits=0 l2_size=$GIB l2_hits=0 l2_misses=0" \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) metadata_size=1024 hits=900 misses=100 mru_ghost_hits=30 l2_size=$GIB l2_hits=40 l2_misses=60" \
        --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .verdict)" = arc_too_small ]
    echo "$output" | jq -e ".hit_rate.total == 90"
    echo "$output" | jq -e ".ghost_hit_percent == 30"
    [ "$(echo "$output" | jq .suggested_max_bytes)" = $((11 * GIB)) ]
    echo "$output" | jq -e ".l2arc.hit_rate == 40"
    echo "$output" | jq -e ".psi.io_some == 0"
    [ "$(echo "$output" | jq .arc.max_bytes)" = $((8 * GIB)) ]
}

@test "JSON output when idle" {
    run "$ANALYZER" --interval 1 --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .verdict)" = idle ]
    [ "$(echo "$output" | jq .psi)" = null ]
    [ "$(echo "$output" | jq .suggested_max_bytes)" = null ]
}

@test "L2ARC is shown when present" {
    run_with_counter_change \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=0 misses=0 l2_size=$((100 * GIB)) l2_hits=0 l2_misses=0" \
        "size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=900 misses=100 l2_size=$((100 * GIB)) l2_hits=75 l2_misses=25"
    [[ "$output" == *"L2ARC Size:            100.0 GB"* ]]
    [[ "$output" == *"L2ARC Efficiency:         75.00% (Requests: 100)"* ]]
}
