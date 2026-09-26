#!/usr/bin/env bash
# Proxmox VE ZFS ARC Analyzer: measures ARC efficiency and PSI pressure (read-only).

VERSION="1.2.0"

# System paths, overridable for testing
ARCSTATS_FILE="${ARCSTATS_FILE:-/proc/spl/kstat/zfs/arcstats}"
PSI_DIR="${PSI_DIR:-/proc/pressure}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"

INTERVAL=30 # Sampling interval in seconds
JSON=0

# Share of misses that a larger ARC would have served (ghost hits), from which
# expanding the ARC is recommended
GHOST_EXPAND_PERCENT=20

GIB=1073741824

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
  --json                  Print the results as JSON (for monitoring)
  -h, --help              Show this help
  --version               Show the version
EOF
}

# Prints human-readable output, unless the output is JSON
say() {
    [ "$JSON" -eq 1 ] || echo -e "$*"
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

mem_available_bytes() {
    awk '/^MemAvailable:/ { printf "%.0f", $2 * 1024; found = 1 } END { if (!found) print 0 }' "$MEMINFO_FILE" 2>/dev/null || echo 0
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

# Suggests a new ARC maximum: the current one grown by the share of misses that were
# ghost hits, but by no more than half of the available memory, rounded up to a GiB
suggest_max() {
    local c_max="$1" ghost_percent="$2" available="$3" increase
    increase=$(awk -v m="$c_max" -v g="$ghost_percent" 'BEGIN { printf "%.0f", m * g / 100 }')
    [ "$increase" -le $((available / 2)) ] || increase=$((available / 2))
    echo $((((c_max + increase + GIB - 1) / GIB) * GIB))
}

# Prints the verdict for the given measurements: total and metadata hit rates (%),
# metadata requests, evicted blocks, full memory stall and I/O stall (% of the
# interval) and the share of misses that were ghost hits (%)
classify() {
    local hr_total="$1" hr_meta="$2" meta_requests="$3" evicted="$4" psi_mem_full="$5" psi_io="$6" ghost="$7"
    local hr_total_int=${hr_total%.*} hr_meta_int=${hr_meta%.*} ghost_int=${ghost%.*}
    local psi_mem_full_int=${psi_mem_full%.*} psi_io_int=${psi_io%.*}

    if [ "$psi_mem_full_int" -gt 5 ]; then
        echo "critical_ram"
    elif [ "$hr_total_int" -lt 80 ] && [ "$psi_io_int" -gt 15 ]; then
        if [ "$ghost_int" -ge "$GHOST_EXPAND_PERCENT" ]; then
            echo "storage_bottleneck_expand"
        else
            echo "storage_bottleneck"
        fi
    elif [ "$hr_total_int" -lt 85 ] && [ "$psi_io_int" -le 5 ]; then
        echo "stable"
    elif [ "$hr_meta_int" -lt 85 ] && [ "$meta_requests" -gt 500 ]; then
        echo "metadata"
    elif [ "$ghost_int" -ge "$GHOST_EXPAND_PERCENT" ]; then
        echo "arc_too_small"
    elif [ "$evicted" -gt 5000 ]; then
        echo "churn"
    else
        echo "excellent"
    fi
}

# Prints the explanation of a verdict
describe() {
    local verdict="$1" hr_total="$2" hr_meta="$3" evicted="$4" psi_mem_full="$5" psi_io="$6" ghost="$7" suggestion="$8"
    case "$verdict" in
        critical_ram)
            echo -e "${RED}[CRITICAL RAM DEFICIT] System is paralyzed due to lack of memory (${psi_mem_full}% stall time).${NC}"
            echo -e "-> ZFS ARC is heavily constrained, or VMs have overcommitted host RAM."
            echo -e "-> Recommendation: Add physical RAM, or reduce VM memory allocation."
            ;;
        storage_bottleneck_expand)
            echo -e "${RED}[WARNING: STORAGE BOTTLENECK] Low cache hit rate (${hr_total}%) causes stalls on I/O (${psi_io}%).${NC}"
            echo -e "-> ${ghost}% of the misses were recently evicted data, which a larger ARC would have served."
            echo -e "-> Recommendation: Expand ZFS ARC: ${suggestion}"
            ;;
        storage_bottleneck)
            echo -e "${RED}[WARNING: STORAGE BOTTLENECK] Low cache hit rate (${hr_total}%) causes stalls on I/O (${psi_io}%).${NC}"
            echo -e "-> Only ${ghost}% of the misses were recently evicted data, so a larger ARC would help little."
            echo -e "-> Recommendation: Faster storage, a special vdev for metadata or an NVMe L2ARC."
            ;;
        stable)
            echo -e "${YELLOW}[STABLE] Cache efficiency is low (${hr_total}%), but storage handles requests fast enough before processes lag.${NC}"
            echo -e "-> I/O pressure is minimal (${psi_io}%). Expanding ARC is optional, but not urgently required right now."
            ;;
        metadata)
            echo -e "${RED}[WARNING] Reduced METADATA cache efficiency (${hr_meta}%)${NC}"
            echo -e "-> Recommendation: Increase total ARC limit so filesystem index structures don't get evicted."
            ;;
        arc_too_small)
            echo -e "${YELLOW}[WARNING] ARC is too small for the working set: ${ghost}% of the misses were recently evicted data.${NC}"
            echo -e "-> Recommendation: Expand ZFS ARC: ${suggestion}"
            ;;
        churn)
            echo -e "${YELLOW}[WARNING] High data churn rate (evicted: ${evicted} blocks), but little of it is requested again.${NC}"
            echo -e "-> Expanding ARC would help little; the workload mostly reads data once."
            ;;
        excellent)
            echo -e "${GREEN}[EXCELLENT] High cache efficiency (${hr_total}%), no resource pressure detected.${NC}"
            echo -e "-> No limit adjustments required."
            ;;
    esac
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
            --json) JSON=1 ;;
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

    say "${BLUE}=== ZFS ARC Efficiency & PSI Pressure Analyzer for Proxmox ===${NC}\n"

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

    # Counters sampled at the start and the end of the interval
    local counters=(hits misses demand_data_hits demand_data_misses demand_metadata_hits demand_metadata_misses
        prefetch_data_hits prefetch_data_misses prefetch_metadata_hits prefetch_metadata_misses deleted
        mru_ghost_hits mfu_ghost_hits l2_hits l2_misses)
    local name start_var
    # Changes of the counters over the interval, set in the loop below
    local d_hits=0 d_misses=0 d_demand_data_hits=0 d_demand_data_misses=0 d_demand_metadata_hits=0
    local d_demand_metadata_misses=0 d_prefetch_data_hits=0 d_prefetch_data_misses=0
    local d_prefetch_metadata_hits=0 d_prefetch_metadata_misses=0 d_deleted=0 d_mru_ghost_hits=0
    local d_mfu_ghost_hits=0 d_l2_hits=0 d_l2_misses=0

    say "${BLUE}=== Gathering Initial ARC Metrics... ===${NC}"
    for name in "${counters[@]}"; do
        printf -v "start_${name}" '%s' "$(get_arc_stat "$name")"
    done
    local mem_some1=0 mem_full1=0 io_some1=0
    if [ "$psi_available" -eq 1 ]; then
        mem_some1=$(get_psi_total some memory)
        mem_full1=$(get_psi_total full memory)
        io_some1=$(get_psi_total some io)
    fi
    local started=$SECONDS

    say "${YELLOW}Starting real-time activity & PSI analysis...${NC}"

    local i elapsed filled unfilled bar spaces
    for ((i = INTERVAL; i > 0; i--)); do
        if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
            elapsed=$((INTERVAL - i))
            filled=$(((elapsed * 20) / INTERVAL))
            unfilled=$((20 - filled))
            bar=$(printf "%-${filled}s" "#" | tr ' ' '#')
            spaces=$(printf "%-${unfilled}s" " ")
            printf "\r[${GREEN}%s${NC}%s] Time remaining: ${YELLOW}%2d${NC} sec..." "$bar" "$spaces" "$i"
        fi
        sleep 1
    done
    if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
        printf "\r%-60s\r" " "
    fi

    say "${BLUE}=== Gathering Final ARC Metrics... ===${NC}"
    # Sets d_<counter> to the change of each counter over the interval
    for name in "${counters[@]}"; do
        start_var="start_${name}"
        printf -v "d_${name}" '%s' $(($(get_arc_stat "$name") - ${!start_var}))
    done

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
    local meta_bytes meta_limit="" meta_text
    if has_arc_stat arc_meta_limit; then
        meta_bytes=$(get_arc_stat arc_meta_used)
        meta_limit=$(get_arc_stat arc_meta_limit)
        meta_text="$(format_size "$meta_bytes") / $(format_size "$meta_limit") (limit)"
    else
        meta_bytes=$(get_arc_stat metadata_size)
        meta_text="$(format_size "$meta_bytes") (no fixed limit on OpenZFS 2.2+)"
    fi

    local d_total=$((d_hits + d_misses))
    local d_dhits=$d_demand_data_hits d_dmisses=$d_demand_data_misses
    local d_dtotal=$((d_dhits + d_dmisses))
    local d_mhits=$d_demand_metadata_hits d_mmisses=$d_demand_metadata_misses
    local d_mtotal=$((d_mhits + d_mmisses))
    local d_pfhits=$((d_prefetch_data_hits + d_prefetch_metadata_hits))
    local d_pfmisses=$((d_prefetch_data_misses + d_prefetch_metadata_misses))
    local d_pftotal=$((d_pfhits + d_pfmisses))
    local d_other_hits=$((d_hits - d_dhits - d_mhits - d_pfhits))
    local d_other_misses=$((d_misses - d_dmisses - d_mmisses - d_pfmisses))
    local d_othertotal=$((d_other_hits + d_other_misses))
    local d_ghost=$((d_mru_ghost_hits + d_mfu_ghost_hits))
    local l2_size l2_total=$((d_l2_hits + d_l2_misses))
    l2_size=$(get_arc_stat l2_size)

    say "\n${BLUE}=== CURRENT CACHE STATUS ===${NC}"
    say "Current ARC Size:      ${GREEN}$(format_size "$size")${NC}"
    say "ARC Limit Settings:    Min: ${YELLOW}$(format_size "$c_min")${NC}  /  Max: ${YELLOW}$(format_size "$c_max")${NC}"
    say "Metadata Cache:        ${GREEN}${meta_text}${NC}"
    if [ "$l2_size" -gt 0 ]; then
        say "L2ARC Size:            ${GREEN}$(format_size "$l2_size")${NC}"
    fi

    say "\n${BLUE}=== OS RESOURCE PRESSURE (PSI, last ${seconds} sec) ===${NC}"
    if [ "$psi_available" -eq 1 ]; then
        say "RAM Stall Pressure:    Processes waiting: ${YELLOW}${psi_mem_some}%${NC} | System paralyzed: ${RED}${psi_mem_full}%${NC}"
        say "I/O Stall Pressure:    Processes waiting: ${YELLOW}${psi_io_some}%${NC}"
    else
        say "${YELLOW}PSI is not available (${PSI_DIR}), pressure is not taken into account.${NC}"
    fi

    say "\n${BLUE}=== CACHE EFFICIENCY FOR THE LAST ${seconds} SEC ===${NC}"

    local verdict="idle" hr_total="0.00" hr_data="0.00" hr_meta="0.00" hr_prefetch="0.00" ghost="0.00" suggested=""
    if [ "$d_total" -gt 0 ]; then
        hr_total=$(calc_percent "$d_hits" "$d_total")
        hr_data=$(calc_percent "$d_dhits" "$d_dtotal")
        hr_meta=$(calc_percent "$d_mhits" "$d_mtotal")
        hr_prefetch=$(calc_percent "$d_pfhits" "$d_pftotal")
        ghost=$(calc_percent "$d_ghost" "$d_misses")
        verdict=$(classify "$hr_total" "$hr_meta" "$d_mtotal" "$d_deleted" "$psi_mem_full" "$psi_io_some" "$ghost")
        if [ "$verdict" = "arc_too_small" ] || [ "$verdict" = "storage_bottleneck_expand" ]; then
            suggested=$(suggest_max "$c_max" "$ghost" "$(mem_available_bytes)")
        fi
    fi

    if [ "$JSON" -eq 1 ]; then
        local l2_json="null"
        if [ "$l2_size" -gt 0 ]; then
            l2_json="{\"size_bytes\": ${l2_size}, \"hit_rate\": $(calc_percent "$d_l2_hits" "$l2_total")}"
        fi
        cat <<EOF
{
  "version": "${VERSION}",
  "interval_seconds": ${seconds},
  "arc": {"size_bytes": ${size}, "min_bytes": ${c_min}, "max_bytes": ${c_max}, "metadata_bytes": ${meta_bytes}},
  "requests": {"total": ${d_total}, "misses": ${d_misses}, "metadata": ${d_mtotal}},
  "hit_rate": {"total": ${hr_total}, "data": ${hr_data}, "metadata": ${hr_meta}, "prefetch": ${hr_prefetch}},
  "ghost_hit_percent": ${ghost},
  "evicted_blocks": ${d_deleted},
  "psi": $([ "$psi_available" -eq 1 ] && echo "{\"memory_some\": ${psi_mem_some}, \"memory_full\": ${psi_mem_full}, \"io_some\": ${psi_io_some}}" || echo null),
  "l2arc": ${l2_json},
  "verdict": "${verdict}",
  "suggested_max_bytes": ${suggested:-null}
}
EOF
        exit 0
    fi

    if [ "$verdict" = "idle" ]; then
        say "${YELLOW}No disk requests detected in the last ${seconds} seconds. System is idling.${NC}"
        exit 0
    fi

    say "Total Efficiency:         ${GREEN}${hr_total}%${NC} (Total Requests: ${d_total}, Misses: ${d_misses})"
    say "  └─ Core DATA:           ${GREEN}${hr_data}%${NC} (Requests: ${d_dtotal}, Misses: ${d_dmisses})"
    say "  └─ METADATA:            ${GREEN}${hr_meta}%${NC} (Requests: ${d_mtotal}, Misses: ${d_mmisses})"
    say "  └─ Prefetch (Read-ahead):${GREEN}${hr_prefetch}%${NC} (Requests: ${d_pftotal}, Misses: ${d_pfmisses})"
    if [ "$d_othertotal" -gt 0 ] && [ "$d_other_hits" -ge 0 ]; then
        say "  └─ System/Other:        ${GREEN}$(calc_percent "$d_other_hits" "$d_othertotal")%${NC} (Requests: ${d_othertotal}, Misses: ${d_other_misses})"
    fi
    say "Ghost Hits:               ${YELLOW}${ghost}%${NC} of misses (recently evicted data requested again)"
    say "Evicted Blocks (Cache):   ${YELLOW}${d_deleted}${NC}"
    if [ "$l2_total" -gt 0 ]; then
        say "L2ARC Efficiency:         ${GREEN}$(calc_percent "$d_l2_hits" "$l2_total")%${NC} (Requests: ${l2_total})"
    fi

    local suggestion=""
    if [ -n "$suggested" ]; then
        suggestion="Max $(format_size "$c_max") -> $(format_size "$suggested"), e.g. pve-zfs-tuner.sh --min $((c_min / 1048576))M --max $((suggested / GIB))G"
    fi

    say "\n${BLUE}=== ANALYSIS & RECOMMENDATION ===${NC}"
    describe "$verdict" "$hr_total" "$hr_meta" "$d_deleted" "$psi_mem_full" "$psi_io_some" "$ghost" "$suggestion"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
