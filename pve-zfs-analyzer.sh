#!/usr/bin/env bash
# Proxmox VE ZFS ARC Analyzer: measures ARC efficiency and PSI pressure (read-only).

VERSION="1.0.0"

# System paths, overridable for testing
ARCSTATS_FILE="${ARCSTATS_FILE:-/proc/spl/kstat/zfs/arcstats}"
PSI_DIR="${PSI_DIR:-/proc/pressure}"

INTERVAL=30 # Sampling interval in seconds

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' NC=''
fi

usage() {
    cat <<EOF
Proxmox VE ZFS ARC Analyzer ${VERSION}

Measures ZFS ARC efficiency and memory/I/O pressure over an interval and
recommends whether the ARC size should change. Does not modify the system.

Usage: $(basename "$0") [options]

Options:
  -i, --interval SECONDS  Sampling interval (default: ${INTERVAL})
  -h, --help              Show this help
  --version               Show the version
EOF
}

# Prints a value from arcstats, or 0 if it is missing
get_arc_stat() {
    awk -v name="$1" '$1 == name { print $3; found = 1 } END { if (!found) print 0 }' "$ARCSTATS_FILE" 2>/dev/null || echo 0
}

has_arc_stat() {
    awk -v name="$1" '$1 == name { found = 1 } END { exit !found }' "$ARCSTATS_FILE" 2>/dev/null
}

# Prints the cumulative stall time in microseconds ("total=") of a PSI line, e.g. "some memory"
get_psi_total() {
    local file="${PSI_DIR}/$2"
    [ -r "$file" ] || return 1
    awk -v type="$1" '$1 == type { for (i = 2; i <= NF; i++) if ($i ~ /^total=/) { sub(/^total=/, "", $i); print $i } }' "$file"
}

# Prints the share of the interval spent stalled, in percent with two decimals
stall_percent() {
    local stalled_us="$1" seconds="$2"
    awk -v us="$stalled_us" -v s="$seconds" 'BEGIN { printf "%.2f", (s > 0 ? us / (s * 10000) : 0) }'
}

calc_percent() {
    local hit=$1
    local total=$2
    if [ "$total" -le 0 ]; then
        echo "0.00"
        return
    fi
    awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.2f", h * 100 / t }'
}

format_size() {
    local bytes=$1
    local mb=$((bytes / 1024 / 1024))
    if [ "$mb" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b / 1073741824 }'
    else
        echo "${mb} MB"
    fi
}

# Prints the analysis for the given measurements:
# total and metadata hit rates (%), metadata requests, evicted blocks,
# full memory stall and I/O stall (% of the interval)
recommend() {
    local hr_total="$1" hr_meta="$2" meta_requests="$3" evicted="$4" psi_mem_full="$5" psi_io="$6"
    local hr_total_int=${hr_total%.*} hr_meta_int=${hr_meta%.*}
    local psi_mem_full_int=${psi_mem_full%.*} psi_io_int=${psi_io%.*}

    if [ "$psi_mem_full_int" -gt 5 ]; then
        echo -e "${RED}[CRITICAL RAM DEFICIT] System is paralyzed due to lack of memory (${psi_mem_full}% stall time).${NC}"
        echo -e "-> ZFS ARC is heavily constrained, or VMs have overcommitted host RAM."
        echo -e "-> Recommendation: Add physical RAM, or reduce VM memory allocation."
    elif [ "$hr_total_int" -lt 80 ] && [ "$psi_io_int" -gt 15 ]; then
        echo -e "${RED}[WARNING: STORAGE BOTTLENECK] Low cache hit rate (${hr_total}%) causes stalls on I/O (${psi_io}%).${NC}"
        echo -e "-> VM processes are noticeably lagging while waiting for physical disks."
        echo -e "-> Recommendation: Expand ZFS ARC (by at least 8-16 GB). If RAM is low, consider adding NVMe for L2ARC."
    elif [ "$hr_total_int" -lt 85 ] && [ "$psi_io_int" -le 5 ]; then
        echo -e "${YELLOW}[STABLE] Cache efficiency is low (${hr_total}%), but storage handles requests fast enough before processes lag.${NC}"
        echo -e "-> I/O pressure is minimal (${psi_io}%). Expanding ARC is optional, but not urgently required right now."
    elif [ "$hr_meta_int" -lt 85 ] && [ "$meta_requests" -gt 500 ]; then
        echo -e "${RED}[WARNING] Reduced METADATA cache efficiency (${hr_meta}%)${NC}"
        echo -e "-> Recommendation: Increase total ARC limit so filesystem index structures don't get evicted."
    elif [ "$evicted" -gt 5000 ]; then
        echo -e "${YELLOW}[WARNING] High data churn rate (evicted: ${evicted} blocks).${NC}"
        echo -e "-> Recommendation: Consider expanding ARC by 4-8 GB to preserve the active working set."
    else
        echo -e "${GREEN}[EXCELLENT] High cache efficiency (${hr_total}%), no resource pressure detected.${NC}"
        echo -e "-> No limit adjustments required."
    fi
}

main() {
    set -euo pipefail

    while [ $# -gt 0 ]; do
        case "$1" in
            -i | --interval)
                INTERVAL="${2:-}"
                if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -eq 0 ]; then
                    echo -e "${RED}Error: --interval expects a positive number of seconds.${NC}" >&2
                    exit 1
                fi
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
            *)
                echo -e "${RED}Error: Unknown option: $1 (see --help)${NC}" >&2
                exit 1
                ;;
        esac
        shift
    done

    echo -e "${BLUE}=== ZFS ARC Efficiency & PSI Pressure Analyzer for Proxmox ===${NC}\n"

    if [ "$(id -u)" -ne 0 ] && [ -z "${ZFS_TUNER_SKIP_ROOT_CHECK:-}" ]; then
        echo -e "${RED}Error: This script must be run as root.${NC}" >&2
        exit 1
    fi
    if [ ! -r "$ARCSTATS_FILE" ]; then
        echo -e "${RED}Error: ZFS module is not loaded (${ARCSTATS_FILE} not found).${NC}" >&2
        exit 1
    fi

    local psi_available=1
    if [ ! -r "${PSI_DIR}/memory" ] || [ ! -r "${PSI_DIR}/io" ]; then
        psi_available=0
    fi

    echo -e "${BLUE}=== Gathering Initial ARC Metrics... ===${NC}"
    local h1 m1 dh1 dm1 mh1 mm1 pf_dh1 pf_dm1 pf_mh1 pf_mm1 del1
    h1=$(get_arc_stat hits)
    m1=$(get_arc_stat misses)
    dh1=$(get_arc_stat demand_data_hits)
    dm1=$(get_arc_stat demand_data_misses)
    mh1=$(get_arc_stat demand_metadata_hits)
    mm1=$(get_arc_stat demand_metadata_misses)
    pf_dh1=$(get_arc_stat prefetch_data_hits)
    pf_dm1=$(get_arc_stat prefetch_data_misses)
    pf_mh1=$(get_arc_stat prefetch_metadata_hits)
    pf_mm1=$(get_arc_stat prefetch_metadata_misses)
    del1=$(get_arc_stat deleted)

    local mem_full1=0 io_some1=0 mem_some1=0
    if [ "$psi_available" -eq 1 ]; then
        mem_some1=$(get_psi_total some memory)
        mem_full1=$(get_psi_total full memory)
        io_some1=$(get_psi_total some io)
    fi
    local started=$SECONDS

    echo -e "${YELLOW}Starting real-time activity & PSI analysis...${NC}"

    local i elapsed filled unfilled bar spaces
    for ((i = INTERVAL; i > 0; i--)); do
        if [ -t 1 ]; then
            elapsed=$((INTERVAL - i))
            filled=$(((elapsed * 20) / INTERVAL))
            unfilled=$((20 - filled))
            bar=$(printf "%-${filled}s" "#" | tr ' ' '#')
            spaces=$(printf "%-${unfilled}s" " ")
            printf "\r[${GREEN}%s${NC}%s] Time remaining: ${YELLOW}%2d${NC} sec..." "$bar" "$spaces" "$i"
        fi
        sleep 1
    done
    [ -t 1 ] && printf "\r%-60s\r" " "

    echo -e "${BLUE}=== Gathering Final ARC Metrics... ===${NC}"
    local h2 m2 dh2 dm2 mh2 mm2 pf_dh2 pf_dm2 pf_mh2 pf_mm2 del2
    h2=$(get_arc_stat hits)
    m2=$(get_arc_stat misses)
    dh2=$(get_arc_stat demand_data_hits)
    dm2=$(get_arc_stat demand_data_misses)
    mh2=$(get_arc_stat demand_metadata_hits)
    mm2=$(get_arc_stat demand_metadata_misses)
    pf_dh2=$(get_arc_stat prefetch_data_hits)
    pf_dm2=$(get_arc_stat prefetch_data_misses)
    pf_mh2=$(get_arc_stat prefetch_metadata_hits)
    pf_mm2=$(get_arc_stat prefetch_metadata_misses)
    del2=$(get_arc_stat deleted)

    # PSI stall share over the same interval as the ARC counters
    local seconds=$((SECONDS - started)) psi_mem_some="0.00" psi_mem_full="0.00" psi_io_some="0.00"
    if [ "$psi_available" -eq 1 ]; then
        psi_mem_some=$(stall_percent $(($(get_psi_total some memory) - mem_some1)) "$seconds")
        psi_mem_full=$(stall_percent $(($(get_psi_total full memory) - mem_full1)) "$seconds")
        psi_io_some=$(stall_percent $(($(get_psi_total some io) - io_some1)) "$seconds")
    fi

    local size c_min c_max
    size=$(get_arc_stat size)
    c_min=$(get_arc_stat c_min)
    c_max=$(get_arc_stat c_max)

    # OpenZFS 2.2+ removed the fixed metadata limit (arc_meta_limit/arc_meta_used)
    local meta_text
    if has_arc_stat arc_meta_limit; then
        meta_text="$(format_size "$(get_arc_stat arc_meta_used)") / $(format_size "$(get_arc_stat arc_meta_limit)") (limit)"
    else
        meta_text="$(format_size "$(get_arc_stat metadata_size)") (no fixed limit on OpenZFS 2.2+)"
    fi

    local d_hits=$((h2 - h1)) d_misses=$((m2 - m1))
    local d_total=$((d_hits + d_misses))
    local d_dhits=$((dh2 - dh1)) d_dmisses=$((dm2 - dm1))
    local d_dtotal=$((d_dhits + d_dmisses))
    local d_mhits=$((mh2 - mh1)) d_mmisses=$((mm2 - mm1))
    local d_mtotal=$((d_mhits + d_mmisses))
    local d_pfhits=$(((pf_dh2 - pf_dh1) + (pf_mh2 - pf_mh1)))
    local d_pfmisses=$(((pf_dm2 - pf_dm1) + (pf_mm2 - pf_mm1)))
    local d_pftotal=$((d_pfhits + d_pfmisses))
    local d_other_hits=$((d_hits - d_dhits - d_mhits - d_pfhits))
    local d_other_misses=$((d_misses - d_dmisses - d_mmisses - d_pfmisses))
    local d_othertotal=$((d_other_hits + d_other_misses))
    local d_deleted=$((del2 - del1))

    echo -e "\n${BLUE}=== CURRENT CACHE STATUS ===${NC}"
    echo -e "Current ARC Size:      ${GREEN}$(format_size "$size")${NC}"
    echo -e "ARC Limit Settings:    Min: ${YELLOW}$(format_size "$c_min")${NC}  /  Max: ${YELLOW}$(format_size "$c_max")${NC}"
    echo -e "Metadata Cache:        ${GREEN}${meta_text}${NC}"

    echo -e "\n${BLUE}=== OS RESOURCE PRESSURE (PSI, last ${seconds} sec) ===${NC}"
    if [ "$psi_available" -eq 1 ]; then
        echo -e "RAM Stall Pressure:    Processes waiting: ${YELLOW}${psi_mem_some}%${NC} | System paralyzed: ${RED}${psi_mem_full}%${NC}"
        echo -e "I/O Stall Pressure:    Processes waiting: ${YELLOW}${psi_io_some}%${NC}"
    else
        echo -e "${YELLOW}PSI is not available (${PSI_DIR}), pressure is not taken into account.${NC}"
    fi

    echo -e "\n${BLUE}=== CACHE EFFICIENCY FOR THE LAST ${seconds} SEC ===${NC}"

    if [ "$d_total" -eq 0 ]; then
        echo -e "${YELLOW}No disk requests detected in the last ${seconds} seconds. System is idling.${NC}"
        exit 0
    fi

    local hr_total hr_data hr_meta hr_prefetch
    hr_total=$(calc_percent "$d_hits" "$d_total")
    hr_data=$(calc_percent "$d_dhits" "$d_dtotal")
    hr_meta=$(calc_percent "$d_mhits" "$d_mtotal")
    hr_prefetch=$(calc_percent "$d_pfhits" "$d_pftotal")

    echo -e "Total Efficiency:         ${GREEN}${hr_total}%${NC} (Total Requests: ${d_total}, Misses: ${d_misses})"
    echo -e "  └─ Core DATA:           ${GREEN}${hr_data}%${NC} (Requests: ${d_dtotal}, Misses: ${d_dmisses})"
    echo -e "  └─ METADATA:            ${GREEN}${hr_meta}%${NC} (Requests: ${d_mtotal}, Misses: ${d_mmisses})"
    echo -e "  └─ Prefetch (Read-ahead):${GREEN}${hr_prefetch}%${NC} (Requests: ${d_pftotal}, Misses: ${d_pfmisses})"

    if [ "$d_othertotal" -gt 0 ] && [ "$d_other_hits" -ge 0 ]; then
        echo -e "  └─ System/Other:        ${GREEN}$(calc_percent "$d_other_hits" "$d_othertotal")%${NC} (Requests: ${d_othertotal}, Misses: ${d_other_misses})"
    fi
    echo -e "Evicted Blocks (Cache):   ${YELLOW}${d_deleted}${NC}"

    echo -e "\n${BLUE}=== ANALYSIS & RECOMMENDATION ===${NC}"
    recommend "$hr_total" "$hr_meta" "$d_mtotal" "$d_deleted" "$psi_mem_full" "$psi_io_some"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
