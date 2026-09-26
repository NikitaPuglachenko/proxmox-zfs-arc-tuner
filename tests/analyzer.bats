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

# Recommendations

@test "recommendation: memory stall is critical" {
    run recommend 99.00 99.00 1000 0 6.00 0.00
    [[ "$output" == *"[CRITICAL RAM DEFICIT]"* ]]
}

@test "recommendation: low hit rate with I/O stall is a storage bottleneck" {
    run recommend 70.00 99.00 1000 0 0.00 20.00
    [[ "$output" == *"[WARNING: STORAGE BOTTLENECK]"* ]]
}

@test "recommendation: low hit rate without I/O stall is stable" {
    run recommend 70.00 99.00 1000 0 0.00 1.00
    [[ "$output" == *"[STABLE]"* ]]
}

@test "recommendation: low metadata hit rate" {
    run recommend 95.00 80.00 1000 0 0.00 1.00
    [[ "$output" == *"Reduced METADATA cache efficiency"* ]]
}

@test "recommendation: high churn" {
    run recommend 95.00 99.00 1000 6000 0.00 1.00
    [[ "$output" == *"High data churn rate"* ]]
}

@test "recommendation: excellent" {
    run recommend 95.00 99.00 1000 0 0.00 1.00
    [[ "$output" == *"[EXCELLENT]"* ]]
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

@test "hit rates are measured from the counter changes during the interval" {
    write_arcstats size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=1000 misses=0 \
        demand_data_hits=1000 demand_data_misses=0 deleted=0
    # Counters grow in the middle of the 3 second interval
    (
        sleep 1
        write_arcstats size=$GIB c_min=$GIB c_max=$((8 * GIB)) hits=1900 misses=100 \
            demand_data_hits=1900 demand_data_misses=100 deleted=10
    ) &
    run "$ANALYZER" --interval 3
    wait
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total Efficiency:         90.00% (Total Requests: 1000, Misses: 100)"* ]]
    [[ "$output" == *"Evicted Blocks (Cache):   10"* ]]
    [[ "$output" == *"[EXCELLENT]"* ]]
}
