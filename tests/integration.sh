#!/usr/bin/env bash
# Integration test against the real ZFS kernel module, run as root in CI.
# Creates a file-backed pool, exercises both scripts on the live module and
# checks the kernel behavior the tuner relies on.
set -euo pipefail

cd "$(dirname "$0")/.."
TUNER=./pve-zfs-tuner.sh
ANALYZER=./pve-zfs-analyzer.sh
PARAMS=/sys/module/zfs/parameters
ARCSTATS=/proc/spl/kstat/zfs/arcstats
WORK=$(mktemp -d)
export CONFIG_FILE="${WORK}/zfs.conf"
export NO_COLOR=1
MIB=1048576

arcstat() { awk -v n="$1" '$1 == n { print $3 }' "$ARCSTATS"; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
pass() { echo "ok - $*"; }

cleanup() {
    zpool destroy -f itpool 2>/dev/null || true
    echo 0 >"${PARAMS}/zfs_arc_min" || true
    echo 0 >"${PARAMS}/zfs_arc_max" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

truncate -s 1G "${WORK}/pool.img"
zpool create itpool "${WORK}/pool.img"
dd if=/dev/urandom of=/itpool/data bs=1M count=64 status=none
sync

default_max=$(arcstat c_max)
echo "ZFS $(cat /sys/module/zfs/version), default c_max $((default_max / MIB)) MiB"

# Assumption: ZFS silently ignores zfs_arc_max below 64 MiB
echo $((32 * MIB)) >"${PARAMS}/zfs_arc_max"
[ "$(arcstat c_max)" -eq "$default_max" ] || fail "ZFS applied zfs_arc_max below 64 MiB"
echo 0 >"${PARAMS}/zfs_arc_max"
pass "ZFS ignores zfs_arc_max below 64 MiB"

# Dry run changes nothing
$TUNER --recommended --dry-run >"${WORK}/out" || fail "dry run failed"
[ "$(cat "${PARAMS}/zfs_arc_max")" -eq 0 ] || fail "dry run changed zfs_arc_max"
pass "dry run"

# Custom limits are accepted by the kernel
$TUNER --min 256M --max 1G --yes --no-persist --wait 0 >"${WORK}/out" || fail "apply failed: $(cat "${WORK}/out")"
grep -q "did not accept" "${WORK}/out" && fail "tuner reports limits not accepted: $(cat "${WORK}/out")"
[ "$(arcstat c_min)" -eq $((256 * MIB)) ] || fail "c_min is $(arcstat c_min)"
[ "$(arcstat c_max)" -eq $((1024 * MIB)) ] || fail "c_max is $(arcstat c_max)"
pass "custom limits applied"

# Raising MIN above the current MAX works thanks to the write order
$TUNER --min 1536M --max 2G --yes --no-persist --wait 0 >"${WORK}/out" || fail "raise failed: $(cat "${WORK}/out")"
[ "$(arcstat c_min)" -eq $((1536 * MIB)) ] || fail "c_min after raise is $(arcstat c_min)"
[ "$(arcstat c_max)" -eq $((2048 * MIB)) ] || fail "c_max after raise is $(arcstat c_max)"
pass "raising MIN above the current MAX"

# Lowering both below the current MIN works as well
$TUNER --min 128M --max 512M --yes --no-persist --wait 0 >"${WORK}/out" || fail "lower failed: $(cat "${WORK}/out")"
[ "$(arcstat c_min)" -eq $((128 * MIB)) ] || fail "c_min after lower is $(arcstat c_min)"
[ "$(arcstat c_max)" -eq $((512 * MIB)) ] || fail "c_max after lower is $(arcstat c_max)"
pass "lowering the limits"

# Persisting writes the config (root is not on ZFS on the runner)
echo "options zfs zfs_txg_timeout=10" >"$CONFIG_FILE"
$TUNER --min 256M --max 1G --yes --persist --wait 0 >"${WORK}/out" || fail "persist failed"
grep -qx "options zfs zfs_txg_timeout=10" "$CONFIG_FILE" || fail "other options lost: $(cat "$CONFIG_FILE")"
grep -qx "options zfs zfs_arc_min=$((256 * MIB)) zfs_arc_max=$((1024 * MIB))" "$CONFIG_FILE" || fail "limits not saved: $(cat "$CONFIG_FILE")"
pass "persisted config"

# Reset returns to the defaults
$TUNER --reset --yes >"${WORK}/out" || fail "reset failed"
[ "$(arcstat c_max)" -eq "$default_max" ] || fail "c_max after reset is $(arcstat c_max), default $default_max"
grep -q zfs_arc "$CONFIG_FILE" && fail "limits left in config after reset"
pass "reset"

# Analyzer reads the live statistics
cat /itpool/data >/dev/null
$ANALYZER --interval 2 >"${WORK}/out" || fail "analyzer failed: $(cat "${WORK}/out")"
grep -q "Current ARC Size" "${WORK}/out" || fail "analyzer output: $(cat "${WORK}/out")"
grep -q "Metadata Cache" "${WORK}/out" || fail "analyzer output: $(cat "${WORK}/out")"
pass "analyzer"

echo "All integration checks passed"
