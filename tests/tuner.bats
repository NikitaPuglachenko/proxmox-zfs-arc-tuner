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

# The kernel currently has other limits than the recommendation
set_storage() {
    export FAKE_POOL_BYTES=$((7 * TIB / 2))
    write_arcstats size=$((2 * GIB)) c_min=$((1 * GIB)) c_max=$((8 * GIB))
}

# The kernel already runs with the recommended limits
set_applied() {
    export FAKE_POOL_BYTES=$((7 * TIB / 2))
    write_arcstats size=$((2 * GIB)) c_min="$REC_MIN" c_max="$REC_MAX"
    echo "$REC_MIN" >"${ZFS_PARAMS_DIR}/zfs_arc_min"
    echo "$REC_MAX" >"${ZFS_PARAMS_DIR}/zfs_arc_max"
}

# Sizing

@test "recommendation: min is 50% and max 2x of the baseline" {
    run recommend_limits $((256 * GIB)) $((7 * TIB / 2))
    [ "$output" = "$REC_MIN $REC_MAX $((6 * GIB)) formula" ]
}

@test "recommendation: without pools the baseline is 2 GiB" {
    run recommend_limits $((256 * GIB)) 0
    [ "$output" = "$((1 * GIB)) $((4 * GIB)) $((2 * GIB)) formula" ]
}

@test "recommendation: max is capped to 10% of RAM and min set to 25% of it" {
    run recommend_limits $((64 * GIB)) $((7 * TIB / 2))
    local cap=$((64 * GIB / 10))
    [ "$output" = "$((cap / 4)) $cap $((6 * GIB)) ram_cap" ]
}

@test "recommendation: max is limited to the memory left after the guests" {
    # 64 GiB RAM, 56 GiB for guests, 5% (3.2 GiB) reserved for the host: 4.8 GiB left
    local headroom=$((64 * GIB - 56 * GIB - 64 * GIB / 20))
    run recommend_limits $((64 * GIB)) $((7 * TIB / 2)) $((56 * GIB))
    [ "$output" = "$((32 * 1048576)) $headroom $((6 * GIB)) guests" ]
}

@test "recommendation: guests with enough memory left do not change it" {
    run recommend_limits $((256 * GIB)) $((7 * TIB / 2)) $((64 * GIB))
    [ "$output" = "$REC_MIN $REC_MAX $((6 * GIB)) formula" ]
}

@test "recommendation: the host reserve is at least 2 GiB" {
    run guest_headroom $((16 * GIB)) $((10 * GIB))
    [ "$output" = $((4 * GIB)) ]
}

@test "recommendation: overcommitted hosts get the smallest valid max" {
    run guest_headroom $((16 * GIB)) $((20 * GIB))
    [ "$output" = $((64 * 1048576)) ]
}

@test "guests: memory of running VMs and containers is summed" {
    fake_pvesh '[{"vmid":100,"status":"running","maxmem":2147483648},{"vmid":101,"status":"stopped","maxmem":8589934592}]' \
        '[{"vmid":200,"status":"running","maxmem":1073741824}]'
    [ "$(guest_memory_bytes)" = $((3 * GIB)) ]
}

@test "guests: unknown without pvesh" {
    run guest_memory_bytes
    [ "$status" -ne 0 ]
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

# Guests

@test "running guests are shown and limit the recommendation" {
    set_storage
    write_meminfo $((64 * GIB))
    fake_pvesh '[{"status":"running","maxmem":'$((56 * GIB))'}]' '[]'
    run "$TUNER" --recommended --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Running VMs/CTs Memory: 56.00 GiB (headroom for ARC: 4.80 GiB)"* ]]
    [[ "$output" == *"Limited to the memory left after running VMs/CTs"* ]]
    [[ "$output" == *"zfs_arc_min: 0.03 GiB"* ]]
}

@test "--ignore-guests skips the guest memory" {
    set_storage
    write_meminfo $((64 * GIB))
    fake_pvesh '[{"status":"running","maxmem":'$((56 * GIB))'}]' '[]'
    run "$TUNER" --recommended --dry-run --ignore-guests
    [[ "$output" != *"Running VMs/CTs"* ]]
    [[ "$output" == *"Capped to 10% of host RAM"* ]]
}

# Idempotency and exit codes

@test "nothing is done when the limits are already applied and saved" {
    set_applied
    export FAKE_ROOT_FSTYPE=zfs
    echo "options zfs zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX}" >"$CONFIG_FILE"
    run "$TUNER" --recommended --yes --detailed-exitcode
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already configured, nothing to change."* ]]
    [ ! -e "$FAKE_INITRAMFS_LOG" ]
    run bash -c "ls '${CONFIG_FILE}'.bak.* 2>/dev/null"
    [ -z "$output" ]
}

@test "only the config is saved when the kernel already has the limits" {
    set_applied
    export FAKE_ROOT_FSTYPE=zfs
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 0 ]
    [[ "$output" != *"[Step 1]"* ]]
    [ "$(cat "$FAKE_INITRAMFS_LOG")" = "-u -k all" ]
}

@test "the initramfs is not updated when only the running kernel changes" {
    set_storage
    export FAKE_ROOT_FSTYPE=zfs
    echo "options zfs zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX}" >"$CONFIG_FILE"
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Step 1]"* ]]
    [ ! -e "$FAKE_INITRAMFS_LOG" ]
}

@test "--detailed-exitcode returns 2 when something changed" {
    set_storage
    run "$TUNER" --recommended --yes --wait 0 --detailed-exitcode
    [ "$status" -eq 2 ]
}

@test "--detailed-exitcode returns 2 for a dry run with pending changes" {
    set_storage
    run "$TUNER" --recommended --dry-run --detailed-exitcode
    [ "$status" -eq 2 ]
}

@test "changes are recorded in the system journal" {
    set_storage
    run "$TUNER" --recommended --yes --wait 0
    [ "$status" -eq 0 ]
    [[ "$(cat "$FAKE_LOGGER_LOG")" == *"-t pve-zfs-tuner -- Applied zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX}"* ]]
    [[ "$(cat "$FAKE_LOGGER_LOG")" == *"Saved zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX} to ${CONFIG_FILE}"* ]]
}

# Reset and restore

@test "reset explains that the running kernel keeps its limits until a reboot" {
    echo $((4 * GIB)) >"${ZFS_PARAMS_DIR}/zfs_arc_max"
    run "$TUNER" --reset --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"the ZFS defaults apply after a reboot"* ]]
}

@test "restore brings back the most recent backup" {
    set_storage
    export FAKE_ROOT_FSTYPE=zfs
    echo "options zfs zfs_arc_min=1 zfs_arc_max=2" >"${CONFIG_FILE}.bak.20260101-000000"
    echo "options zfs zfs_arc_min=$((1 * GIB)) zfs_arc_max=$((2 * GIB)) zfs_txg_timeout=5" >"${CONFIG_FILE}.bak.20260201-000000"
    echo "options zfs zfs_arc_min=${REC_MIN} zfs_arc_max=${REC_MAX}" >"$CONFIG_FILE"
    run "$TUNER" --restore --yes --wait 0
    [ "$status" -eq 0 ]
    [ "$(cat "$CONFIG_FILE")" = "options zfs zfs_arc_min=$((1 * GIB)) zfs_arc_max=$((2 * GIB)) zfs_txg_timeout=5" ]
    [ "$(cat "${ZFS_PARAMS_DIR}/zfs_arc_max")" = $((2 * GIB)) ]
    [ "$(cat "$FAKE_INITRAMFS_LOG")" = "-u -k all" ]
    # The replaced config is backed up as well, so the restore can be undone
    run bash -c "ls '${CONFIG_FILE}'.bak.* | wc -l"
    [ "$output" -eq 3 ]
}

@test "restore without a backup fails" {
    run "$TUNER" --restore --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"No backup"* ]]
}

@test "restore cannot be combined with --no-persist" {
    run "$TUNER" --restore --no-persist
    [ "$status" -eq 1 ]
}

@test "larger limits are suggested when the 10% cap applies but the guests leave more memory" {
    set_storage
    export FAKE_POOL_BYTES=$((8 * TIB))
    write_meminfo $((64 * GIB))
    # 48 GiB for guests and 3.2 GiB for the host leave 12.8 GiB
    fake_pvesh '[{"status":"running","maxmem":'$((48 * GIB))'}]' '[]'
    run "$TUNER" --recommended --dry-run
    [[ "$output" == *"leave 12.80 GiB, so larger limits fit:"* ]]
    [[ "$output" == *"--min 3072M --max 12G"* ]]
}
