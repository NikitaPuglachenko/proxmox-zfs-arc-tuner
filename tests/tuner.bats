#!/usr/bin/env bats

load helpers

setup() {
    setup_fixture
    # shellcheck source=../pve-zfs-tuner.sh
    source "$TUNER"
}

# 3.5 TiB of storage: baseline 2 GiB + 4 x 1 GiB = 6 GiB
REC_MIN=$((3 * 1073741824))
REC_MAX=$((12 * 1073741824))

set_storage() {
    export FAKE_POOL_BYTES=$((7 * TIB / 2))
    write_arcstats size=$((2 * GIB)) c_min="$REC_MIN" c_max="$REC_MAX"
}

# Sizing

@test "recommendation: min is 50% and max 2x of the baseline" {
    run recommend_limits $((256 * GIB)) $((7 * TIB / 2))
    [ "$output" = "$REC_MIN $REC_MAX $((6 * GIB)) 0" ]
}

@test "recommendation: without pools the baseline is 2 GiB" {
    run recommend_limits $((256 * GIB)) 0
    [ "$output" = "$((1 * GIB)) $((4 * GIB)) $((2 * GIB)) 0" ]
}

@test "recommendation: max is capped to 10% of RAM and min set to 25% of it" {
    run recommend_limits $((64 * GIB)) $((7 * TIB / 2))
    local cap=$((64 * GIB / 10))
    [ "$output" = "$((cap / 4)) $cap $((6 * GIB)) 1" ]
}

# Input

@test "sizes: plain numbers are GiB, M and G suffixes are supported" {
    [ "$(parse_size 4)" = $((4 * GIB)) ]
    [ "$(parse_size 4G)" = $((4 * GIB)) ]
    [ "$(parse_size 512M)" = $((512 * 1048576)) ]
}

@test "sizes: leading zeros are decimal, not octal" {
    [ "$(parse_size 08)" = $((8 * GIB)) ]
    [ "$(parse_size 09G)" = $((9 * GIB)) ]
}

@test "sizes: invalid values are rejected" {
    run parse_size abc
    [ "$status" -ne 0 ]
    run parse_size 1.5
    [ "$status" -ne 0 ]
    run parse_size 4T
    [ "$status" -ne 0 ]
    run parse_size ""
    [ "$status" -ne 0 ]
}

@test "limits: values ZFS would ignore are rejected" {
    run validate_limits $((16 * 1048576)) $((4 * GIB)) $((64 * GIB))
    [[ "$output" == *"at least 32 MiB"* ]]
    run validate_limits $((32 * 1048576)) $((48 * 1048576)) $((64 * GIB))
    [[ "$output" == *"at least 64 MiB"* ]]
    run validate_limits $((4 * GIB)) $((4 * GIB)) $((64 * GIB))
    [[ "$output" == *"greater than MIN"* ]]
    run validate_limits $((4 * GIB)) $((64 * GIB)) $((64 * GIB))
    [[ "$output" == *"less than the total host RAM"* ]]
    run validate_limits $((1 * GIB)) $((4 * GIB)) $((64 * GIB))
    [ "$status" -eq 0 ]
}

# Config file

@test "config: other ZFS options are kept" {
    cat >"$CONFIG_FILE" <<EOF
# ZFS tuning
options zfs zfs_txg_timeout=10 zfs_arc_max=123
options zfs zfs_arc_min=5
options zfs zfs_prefetch_disable=1
options kvm ignore_msrs=1
EOF
    update_modprobe_conf "$CONFIG_FILE" 100 200
    run cat "$CONFIG_FILE"
    [ "$output" = "# ZFS tuning
options zfs zfs_txg_timeout=10
options zfs zfs_prefetch_disable=1
options kvm ignore_msrs=1
options zfs zfs_arc_min=100 zfs_arc_max=200" ]
}

@test "config: reset removes only the ARC limits" {
    printf 'options zfs zfs_arc_min=1 zfs_arc_max=2 zfs_txg_timeout=10\n' >"$CONFIG_FILE"
    update_modprobe_conf "$CONFIG_FILE"
    [ "$(cat "$CONFIG_FILE")" = "options zfs zfs_txg_timeout=10" ]
}

@test "config: a missing file is created" {
    update_modprobe_conf "$CONFIG_FILE" 100 200
    [ "$(cat "$CONFIG_FILE")" = "options zfs zfs_arc_min=100 zfs_arc_max=200" ]
}

# End to end

@test "dry run changes nothing" {
    set_storage
    run "$TUNER" --recommended --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"zfs_arc_max: 12.00 GiB (${REC_MAX} bytes)"* ]]
    [[ "$output" == *"[DRY RUN]"* ]]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = 0 ]
    [ ! -e "$CONFIG_FILE" ]
}

@test "recommended limits are applied, saved with a backup, and the initramfs is left alone on ext4 root" {
    set_storage
    echo "options zfs zfs_txg_timeout=10" >"$CONFIG_FILE"
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_min")" = "$REC_MIN" ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = "$REC_MAX" ]
    [ "$(cat "$CONFIG_FILE")" = "options zfs zfs_txg_timeout=10
options zfs zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX}" ]
    run bash -c "cat '${CONFIG_FILE}'.bak.*"
    [ "$output" = "options zfs zfs_txg_timeout=10" ]
    [ ! -e "$FAKE_INITRAMFS_LOG" ]
}

@test "the initramfs is updated when the root filesystem is on ZFS" {
    set_storage
    export FAKE_ROOT_FSTYPE=zfs
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_INITRAMFS_LOG")" = "-u -k all" ]
    [[ "$output" == *"initramfs updated"* ]]
}

@test "a failed initramfs update is reported as an error" {
    set_storage
    export FAKE_ROOT_FSTYPE=zfs
    printf '#!/usr/bin/env bash\nexit 1\n' >"${FIXTURE}/bin/update-initramfs"
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"update-initramfs -u -k all' manually"* ]]
}

@test "--no-persist applies to the running kernel only" {
    set_storage
    run "$TUNER" --recommended --yes --no-persist --wait 0
    [ "$status" -eq 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = "$REC_MAX" ]
    [ ! -e "$CONFIG_FILE" ]
}

@test "limits not accepted by ZFS are reported" {
    set_storage
    write_arcstats size=$((2 * GIB)) c_min=$((1 * GIB)) c_max=$((8 * GIB))
    run "$TUNER" --recommended --yes --no-persist --wait 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"ZFS did not accept the limits"* ]]
}

@test "custom limits with leading zeros" {
    write_arcstats size=$((1 * GIB)) c_min=$((2 * GIB)) c_max=$((8 * GIB))
    run "$TUNER" --min 02 --max 08 --yes --no-persist --wait 0
    [ "$status" -eq 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_min")" = $((2 * GIB)) ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = $((8 * GIB)) ]
}

@test "custom limits with MIN above MAX are rejected" {
    run "$TUNER" --min 8 --max 4 --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"MAX must be greater than MIN"* ]]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = 0 ]
}

@test "raising MIN above the current MAX writes MAX first" {
    write_param() { echo "$1=$2" >>"${FIXTURE}/writes.log"; }
    write_arcstats c_max=$((2 * GIB))
    apply_runtime $((4 * GIB)) $((16 * GIB))
    [ "$(cat "${FIXTURE}/writes.log")" = "zfs_arc_max=$((16 * GIB))
zfs_arc_min=$((4 * GIB))" ]
}

@test "lowering the limits writes MIN first" {
    write_param() { echo "$1=$2" >>"${FIXTURE}/writes.log"; }
    write_arcstats c_max=$((16 * GIB))
    apply_runtime $((1 * GIB)) $((4 * GIB))
    [ "$(cat "${FIXTURE}/writes.log")" = "zfs_arc_min=$((1 * GIB))
zfs_arc_max=$((4 * GIB))" ]
}

@test "reset removes the limits from the kernel and the config" {
    echo $((4 * GIB)) >"${ZFS_PARAMS_DIR}/zfs_arc_max"
    echo "options zfs zfs_arc_min=1 zfs_arc_max=2 zfs_txg_timeout=10" >"$CONFIG_FILE"
    run "$TUNER" --reset --yes
    [ "$status" -eq 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_min")" = 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = 0 ]
    [ "$(cat "$CONFIG_FILE")" = "options zfs zfs_txg_timeout=10" ]
}

@test "a recommendation below the Proxmox guideline is pointed out" {
    set_storage
    write_meminfo $((32 * GIB))
    run "$TUNER" --recommended --dry-run
    [[ "$output" == *"below the Proxmox guideline of 6.00 GiB"* ]]
}

@test "interactive: option 1 applies and saves the recommendation" {
    set_storage
    run bash -c "printf '1\ny\n' | '$TUNER' --wait 0"
    [ "$status" -eq 0 ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = "$REC_MAX" ]
    [[ "$(cat "$CONFIG_FILE")" == *"zfs_arc_max=${REC_MAX}"* ]]
}

@test "interactive: no input cancels without changes" {
    run bash -c "'$TUNER' </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Operation cancelled"* ]]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = 0 ]
}

@test "root is required unless it is a dry run" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    unset ZFS_TUNER_SKIP_ROOT_CHECK
    run "$TUNER" --recommended --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
    run "$TUNER" --recommended --dry-run
    [ "$status" -eq 0 ]
}

@test "missing ZFS is reported" {
    rm -f "$ARCSTATS_FILE"
    run "$TUNER" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"ZFS module is not loaded"* ]]
}

@test "unknown options are rejected" {
    run "$TUNER" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
}
