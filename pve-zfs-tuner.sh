#!/usr/bin/env bash
# Proxmox VE ZFS ARC Tuner: calculates, applies and persists ZFS ARC limits.

VERSION="1.0.0"

# System paths, overridable for testing
ZFS_PARAMS_DIR="${ZFS_PARAMS_DIR:-/sys/module/zfs/parameters}"
ARCSTATS_FILE="${ARCSTATS_FILE:-/proc/spl/kstat/zfs/arcstats}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
CONFIG_FILE="${CONFIG_FILE:-/etc/modprobe.d/zfs.conf}"

MIB=1048576
GIB=1073741824
TIB=1099511627776

# ZFS ignores zfs_arc_max below 64 MiB and zfs_arc_min below 32 MiB
MIN_ARC_MAX_BYTES=$((64 * MIB))
MIN_ARC_MIN_BYTES=$((32 * MIB))

# Baseline sizing formula recommended by Proxmox: 2 GiB + 1 GiB per TiB of raw storage
BASE_BYTES=$((2 * GIB))
PER_TIB_BYTES=$((1 * GIB))

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

info() { echo -e "$*"; }
warn() { echo -e "${YELLOW}[WARNING] $*${NC}"; }
error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
die() {
    error "$*"
    exit 1
}

usage() {
    cat <<EOF
Proxmox VE ZFS ARC Tuner ${VERSION}

Calculates a recommended ZFS ARC size, applies it to the running kernel and
optionally saves it to ${CONFIG_FILE}.

Usage: $(basename "$0") [options]

Without options, the tuner runs interactively.

Target (pick one):
  --recommended         Apply the smart recommendation
  --min SIZE --max SIZE Apply custom limits (e.g. 4G, 512M; a plain number means GiB)
  --reset               Remove the limits and return to the ZFS defaults

Options:
  --persist             Save the limits to ${CONFIG_FILE} without asking
  --no-persist          Apply the limits to the running kernel only
  -y, --yes             Answer yes to all questions (non-interactive)
  --dry-run             Show what would be done without changing anything
  --wait SECONDS        Seconds to monitor cache eviction after applying (default: 10)
  -h, --help            Show this help
  --version             Show the version
EOF
}

# Formats bytes as GiB with two decimals
format_gib() {
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1073741824 }'
}

# Parses a size such as "4", "4G" or "512M" into bytes; a plain number means GiB
parse_size() {
    local value="$1" number unit
    [[ "$value" =~ ^([0-9]+)([MmGg]?)$ ]] || return 1
    number=$((10#${BASH_REMATCH[1]}))
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        M | m) echo $((number * MIB)) ;;
        *) echo $((number * GIB)) ;;
    esac
}

# Prints a value from arcstats, or 0 if it is missing
read_arcstat() {
    awk -v name="$1" '$1 == name { print $3; found = 1 } END { if (!found) print 0 }' "$ARCSTATS_FILE" 2>/dev/null || echo 0
}

# Prints a ZFS module parameter, or 0 if it is missing
read_param() {
    cat "${ZFS_PARAMS_DIR}/$1" 2>/dev/null || echo 0
}

total_ram_bytes() {
    awk '/^MemTotal:/ { printf "%.0f", $2 * 1024 }' "$MEMINFO_FILE"
}

total_pool_bytes() {
    command -v zpool >/dev/null 2>&1 || {
        echo 0
        return
    }
    zpool list -p -H -o size 2>/dev/null | awk '{ sum += $1 } END { printf "%.0f", sum }'
}

root_is_zfs() {
    [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = "zfs" ]
}

# Prints "<min> <max> <baseline> <capped>" for the given RAM and raw pool size in bytes:
# - baseline: 2 GiB + 1 GiB per TiB of raw storage, rounded up to the next TiB
# - min: 50% of the baseline, max: 2x the baseline
# - if max exceeds 10% of RAM, max is capped to 10% of RAM and min set to 25% of it
recommend_limits() {
    local ram="$1" pool="$2" tib baseline min max cap capped=0
    tib=$(((pool + TIB - 1) / TIB))
    baseline=$((BASE_BYTES + PER_TIB_BYTES * tib))
    min=$((baseline / 2))
    max=$((baseline * 2))
    cap=$((ram / 10))
    if [ "$max" -gt "$cap" ]; then
        max=$cap
        min=$((max / 4))
        capped=1
    fi
    echo "$min $max $baseline $capped"
}

# Checks the limits against what ZFS accepts; prints the reason and fails if invalid
validate_limits() {
    local min="$1" max="$2" ram="$3"
    if [ "$min" -lt "$MIN_ARC_MIN_BYTES" ]; then
        echo "MIN must be at least 32 MiB, otherwise ZFS ignores it"
        return 1
    fi
    if [ "$max" -lt "$MIN_ARC_MAX_BYTES" ]; then
        echo "MAX must be at least 64 MiB, otherwise ZFS ignores it"
        return 1
    fi
    if [ "$min" -ge "$max" ]; then
        echo "MAX must be greater than MIN, otherwise ZFS ignores it"
        return 1
    fi
    if [ "$max" -ge "$ram" ]; then
        echo "MAX must be less than the total host RAM ($(format_gib "$ram") GiB)"
        return 1
    fi
}

# Writes the config with zfs_arc_min/zfs_arc_max replaced, keeping all other ZFS options.
# Without min and max, only removes them (reset to the ZFS defaults).
update_modprobe_conf() {
    local file="$1" min="${2:-}" max="${3:-}" tmp
    tmp=$(mktemp)
    touch "$file"
    awk -v min="$min" -v max="$max" '
        $1 == "options" && $2 == "zfs" {
            line = "options zfs"
            for (i = 3; i <= NF; i++) {
                if ($i !~ /^zfs_arc_(min|max)=/) line = line " " $i
            }
            if (line != "options zfs") print line
            next
        }
        { print }
        END {
            if (max != "") print "options zfs zfs_arc_min=" min " zfs_arc_max=" max
        }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

backup_config() {
    local backup
    [ -s "$CONFIG_FILE" ] || return 0
    backup="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG_FILE" "$backup"
    info "  Backup saved to ${backup}"
}

write_param() {
    echo "$2" >"${ZFS_PARAMS_DIR}/$1"
}

# Writes the limits in an order the kernel accepts: when raising MIN above the
# current MAX, MAX has to be raised first, otherwise MIN is lowered first.
apply_runtime() {
    local min="$1" max="$2" current_max
    current_max=$(read_arcstat c_max)
    if [ "$min" -gt "$current_max" ]; then
        write_param zfs_arc_max "$max" || return 1
        write_param zfs_arc_min "$min" || return 1
    else
        write_param zfs_arc_min "$min" || return 1
        write_param zfs_arc_max "$max" || return 1
    fi
}

# Asks a yes/no question; --yes answers yes, no input (EOF) answers no
confirm() {
    local answer
    [ "$ASSUME_YES" -eq 1 ] && return 0
    read -r -p "$1 (y/n): " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

main() {
    set -euo pipefail

    local mode="" persist="ask" dry_run=0 wait_seconds=10 custom_min="" custom_max=""
    ASSUME_YES=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --recommended) mode="recommended" ;;
            --reset) mode="reset" ;;
            --min)
                custom_min="${2:-}"
                shift
                ;;
            --max)
                custom_max="${2:-}"
                shift
                ;;
            --persist) persist="yes" ;;
            --no-persist) persist="no" ;;
            -y | --yes) ASSUME_YES=1 ;;
            --dry-run) dry_run=1 ;;
            --wait)
                wait_seconds="${2:-}"
                [[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait expects a number of seconds"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --version)
                echo "$VERSION"
                exit 0
                ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    if [ -n "$custom_min" ] || [ -n "$custom_max" ]; then
        [ -z "$mode" ] || die "--min/--max cannot be combined with --${mode}"
        [ -n "$custom_min" ] && [ -n "$custom_max" ] || die "--min and --max must be used together"
        mode="custom"
    fi

    # 0. Preconditions (ZFS_TUNER_SKIP_ROOT_CHECK is used by the tests)
    if [ "$dry_run" -eq 0 ] && [ "$(id -u)" -ne 0 ] && [ -z "${ZFS_TUNER_SKIP_ROOT_CHECK:-}" ]; then
        die "This script must be run as root (via sudo). Use --dry-run to only see the recommendation."
    fi
    [ -d "$ZFS_PARAMS_DIR" ] && [ -r "$ARCSTATS_FILE" ] || die "ZFS module is not loaded."

    # 1. Current state
    local ram pool arc runtime_min runtime_max config_min="Not set" config_max="Not set"
    ram=$(total_ram_bytes)
    pool=$(total_pool_bytes)
    arc=$(read_arcstat size)
    runtime_min=$(read_param zfs_arc_min)
    runtime_max=$(read_param zfs_arc_max)
    if [ -f "$CONFIG_FILE" ]; then
        local value
        value=$(grep -E '^[[:space:]]*options[[:space:]]+zfs[[:space:]]' "$CONFIG_FILE" | grep -oE 'zfs_arc_min=[0-9]+' | tail -n 1 | cut -d= -f2 || true)
        [ -n "$value" ] && config_min="$(format_gib "$value") GiB"
        value=$(grep -E '^[[:space:]]*options[[:space:]]+zfs[[:space:]]' "$CONFIG_FILE" | grep -oE 'zfs_arc_max=[0-9]+' | tail -n 1 | cut -d= -f2 || true)
        [ -n "$value" ] && config_max="$(format_gib "$value") GiB"
    fi

    local runtime_min_text runtime_max_text
    runtime_min_text=$([ "$runtime_min" -eq 0 ] && echo "ZFS default ($(format_gib "$(read_arcstat c_min)") GiB)" || echo "$(format_gib "$runtime_min") GiB")
    runtime_max_text=$([ "$runtime_max" -eq 0 ] && echo "ZFS default ($(format_gib "$(read_arcstat c_max)") GiB)" || echo "$(format_gib "$runtime_max") GiB")

    # 2. Recommendation
    local rec_min rec_max baseline capped reason
    read -r rec_min rec_max baseline capped <<<"$(recommend_limits "$ram" "$pool")"
    if [ "$capped" -eq 1 ]; then
        reason="Capped to 10% of host RAM (formula exceeded the safe threshold)"
    else
        reason="Min = 50% of formula (2 GiB + 1 GiB/TiB), Max = 2x formula"
    fi

    info "${YELLOW}Current System State:${NC}"
    info "  Host Total RAM:         ${GREEN}$(format_gib "$ram") GiB${NC}"
    info "  Total Raw ZFS Storage:  ${GREEN}$(awk -v b="$pool" 'BEGIN { printf "%.2f", b / 1099511627776 }') TiB${NC}"
    info "  Current ARC Footprint:  ${GREEN}$(format_gib "$arc") GiB${NC} (actual RAM used)"
    info "  Active Kernel Limits:   ${GREEN}Min: ${runtime_min_text} / Max: ${runtime_max_text}${NC}"
    info "  Persistent Config:      ${GREEN}Min: ${config_min} / Max: ${config_max}${NC}\n"

    info "${YELLOW}Calculated Target Options:${NC}"
    info "  - 10% of Host RAM (Max Limit): ${BLUE}$(format_gib $((ram / 10))) GiB${NC}"
    info "  - Raw Formula (Max Limit):     ${BLUE}$(format_gib $((baseline * 2))) GiB${NC}"
    info "  * Smart Recommendation:        ${GREEN}Min: $(format_gib "$rec_min") GiB / Max: $(format_gib "$rec_max") GiB${NC}"
    info "                                 [Reason: ${reason}]"
    if [ "$rec_max" -lt "$baseline" ]; then
        warn "The recommended Max is below the Proxmox guideline of $(format_gib "$baseline") GiB (2 GiB + 1 GiB per TiB of storage)."
        info "  Consider more RAM, or custom limits if the host can spare the memory."
    fi
    info ""

    # 3. Target
    if [ -z "$mode" ]; then
        local choice=""
        info "${YELLOW}Choose your configuration target:${NC}"
        info "  1) Apply Smart Recommendation (Min: $(format_gib "$rec_min") GiB / Max: $(format_gib "$rec_max") GiB)"
        info "  2) Define custom limits manually"
        info "  3) Reset to the ZFS defaults"
        info "  *) Cancel and exit\n"
        read -r -p "Select option (1/2/3/*): " choice || true
        case "$choice" in
            1) mode="recommended" ;;
            2)
                mode="custom"
                read -r -p "Enter your custom MIN limit (e.g. 4G, 512M; a plain number means GiB): " custom_min || true
                read -r -p "Enter your custom MAX limit (e.g. 16G; a plain number means GiB): " custom_max || true
                ;;
            3) mode="reset" ;;
            *)
                info "${YELLOW}Operation cancelled.${NC}"
                exit 0
                ;;
        esac
        # The menu choice is the confirmation
        ASSUME_YES_APPLY=1
    fi

    local target_min="" target_max=""
    case "$mode" in
        recommended)
            target_min=$rec_min
            target_max=$rec_max
            ;;
        custom)
            target_min=$(parse_size "$custom_min") || die "Invalid MIN limit: '${custom_min}'"
            target_max=$(parse_size "$custom_max") || die "Invalid MAX limit: '${custom_max}'"
            ;;
    esac

    if [ "$mode" = "reset" ]; then
        info "${YELLOW}Target:${NC} remove zfs_arc_min/zfs_arc_max and return to the ZFS defaults"
    else
        local problem
        problem=$(validate_limits "$target_min" "$target_max" "$ram") || die "$problem"
        if [ "$target_max" -gt $((ram / 2)) ]; then
            warn "MAX is more than 50% of the host RAM, which leaves less memory for VMs and containers."
        fi
        info "${YELLOW}Target Limits:${NC}"
        info "  zfs_arc_min: $(format_gib "$target_min") GiB (${target_min} bytes)"
        info "  zfs_arc_max: $(format_gib "$target_max") GiB (${target_max} bytes)"
    fi

    if [ "$dry_run" -eq 1 ]; then
        info "\n${BLUE}[DRY RUN] Nothing was changed. The tuner would:${NC}"
        if [ "$mode" = "reset" ]; then
            info "  - write 0 to ${ZFS_PARAMS_DIR}/zfs_arc_min and zfs_arc_max"
        else
            info "  - write ${target_min} to ${ZFS_PARAMS_DIR}/zfs_arc_min and ${target_max} to zfs_arc_max"
        fi
        if [ "$persist" != "no" ]; then
            info "  - save ${CONFIG_FILE} (after a backup) with the ZFS options:"
            local preview
            preview=$(mktemp)
            [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$preview"
            update_modprobe_conf "$preview" "$target_min" "$target_max"
            grep -E '^options zfs' "$preview" | sed 's/^/      /' || info "      (no ZFS options)"
            rm -f "$preview"
            if root_is_zfs; then
                info "  - run update-initramfs -u -k all (root filesystem is on ZFS)"
            fi
        fi
        exit 0
    fi

    if [ "${ASSUME_YES_APPLY:-0}" -ne 1 ] && ! confirm "Apply these limits to the running kernel?"; then
        info "${YELLOW}Operation cancelled.${NC}"
        exit 0
    fi

    # 4. Apply to the running kernel
    if [ "$mode" = "reset" ]; then
        { write_param zfs_arc_min 0 && write_param zfs_arc_max 0; } ||
            die "Failed to reset the ZFS ARC parameters."
        info "${GREEN}[Step 1] ZFS ARC limits reset to the defaults in the running kernel.${NC}"
    else
        apply_runtime "$target_min" "$target_max" || die "Failed to update the ZFS ARC parameters."
        info "${GREEN}[Step 1] Target limits applied to the running kernel.${NC}"

        # ZFS accepts any value written to the parameters, but silently ignores invalid ones
        local c_min c_max
        c_min=$(read_arcstat c_min)
        c_max=$(read_arcstat c_max)
        if [ "$c_min" -ne "$target_min" ] || [ "$c_max" -ne "$target_max" ]; then
            warn "ZFS did not accept the limits: active Min $(format_gib "$c_min") GiB / Max $(format_gib "$c_max") GiB."
            info "  Check 'dmesg' for ZFS messages."
        fi

        if [ "$wait_seconds" -gt 0 ]; then
            echo -ne "${YELLOW}[Step 2] Waiting ${wait_seconds} seconds to monitor cache eviction... ${NC}"
            local i
            for ((i = wait_seconds; i > 0; i--)); do
                echo -n "$i.."
                sleep 1
            done
            info " Done."
            arc=$(read_arcstat size)
            if [ "$arc" -gt "$target_max" ]; then
                warn "ZFS cache footprint remains higher than Max: $(format_gib "$arc") GiB"
                info "  ZFS evicts data gradually as the system demands memory or activity decreases."
            else
                info "${GREEN}[SUCCESS] ZFS cache is within the target limits.${NC}"
            fi
        fi
    fi

    # 5. Persist
    if [ "$persist" = "ask" ]; then
        if confirm "Save this configuration permanently to ${CONFIG_FILE}?"; then
            persist="yes"
        else
            persist="no"
        fi
    fi
    if [ "$persist" = "no" ]; then
        info "${YELLOW}The limits are active until the next reboot and were not saved.${NC}"
        exit 0
    fi

    backup_config
    update_modprobe_conf "$CONFIG_FILE" "$target_min" "$target_max"
    info "${GREEN}[SUCCESS] Configuration saved to ${CONFIG_FILE}${NC}"

    # With the root filesystem on ZFS, the module options are read from the initramfs
    if root_is_zfs; then
        info "${YELLOW}Root filesystem is on ZFS, updating the initramfs...${NC}"
        if command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all; then
            info "${GREEN}[SUCCESS] initramfs updated, the limits apply after reboot.${NC}"
        else
            error "Failed to update the initramfs. Run 'update-initramfs -u -k all' manually, otherwise the limits are not applied after reboot."
            exit 1
        fi
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
