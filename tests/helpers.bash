# Test fixture: a fake ZFS host in a temporary directory.
# System paths of the scripts point into it, and zpool, findmnt and
# update-initramfs are replaced by stubs controlled with FAKE_* variables.

ROOT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TUNER="${ROOT_DIR}/pve-zfs-tuner.sh"
ANALYZER="${ROOT_DIR}/pve-zfs-analyzer.sh"

GIB=1073741824
TIB=1099511627776

setup_fixture() {
    FIXTURE="${BATS_TEST_TMPDIR}/host"
    mkdir -p "${FIXTURE}/params" "${FIXTURE}/bin" "${FIXTURE}/pressure"

    export ZFS_PARAMS_DIR="${FIXTURE}/params"
    export ARCSTATS_FILE="${FIXTURE}/arcstats"
    export MEMINFO_FILE="${FIXTURE}/meminfo"
    export CONFIG_FILE="${FIXTURE}/zfs.conf"
    export PSI_DIR="${FIXTURE}/pressure"
    export ZFS_TUNER_SKIP_ROOT_CHECK=1
    export NO_COLOR=1

    echo 0 >"${ZFS_PARAMS_DIR}/zfs_arc_min"
    echo 0 >"${ZFS_PARAMS_DIR}/zfs_arc_max"

    export FAKE_POOL_BYTES=0
    export FAKE_ROOT_FSTYPE=ext4
    export FAKE_INITRAMFS_LOG="${FIXTURE}/initramfs.log"

    cat >"${FIXTURE}/bin/zpool" <<'STUB'
#!/usr/bin/env bash
echo "$FAKE_POOL_BYTES"
STUB
    cat >"${FIXTURE}/bin/findmnt" <<'STUB'
#!/usr/bin/env bash
echo "$FAKE_ROOT_FSTYPE"
STUB
    cat >"${FIXTURE}/bin/update-initramfs" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_INITRAMFS_LOG"
STUB
    chmod +x "${FIXTURE}/bin/"*
    export PATH="${FIXTURE}/bin:${PATH}"

    write_meminfo $((256 * GIB))
    write_arcstats size=$((2 * GIB)) c_min=$((1 * GIB)) c_max=$((8 * GIB))
}

write_meminfo() {
    echo "MemTotal:       $(($1 / 1024)) kB" >"$MEMINFO_FILE"
}

# write_arcstats name=value ...: writes an arcstats file in the kstat format
write_arcstats() {
    {
        echo "13 1 0x01 123 33456 1234567890 1234567890"
        echo "name                            type data"
        local pair
        for pair in "$@"; do
            printf '%-32s4    %s\n' "${pair%%=*}" "${pair#*=}"
        done
    } >"$ARCSTATS_FILE"
}
