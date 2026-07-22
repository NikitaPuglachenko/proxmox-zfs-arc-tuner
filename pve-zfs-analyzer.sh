#!/bin/bash

# Output colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

INTERVAL=30 # Sampling interval in seconds

echo -e "${BLUE}=== ZFS ARC Efficiency & PSI Pressure Analyzer for Proxmox ===${NC}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

get_arc_stat() {
    local val
    val=$(grep -w "$1" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
    echo "${val:-0}"
}

get_psi_stat() {
    local type=$1
    local file="/proc/pressure/$2"
    if [ -f "$file" ]; then
        grep "^$type " "$file" | awk -F'avg10=' '{print $2}' | awk '{print $1}'
    else
        echo "0.00"
    fi
}

calc_percent() {
    local hit=$1
    local total=$2
    if [ "$total" -eq 0 ]; then echo "0.00"; return; fi
    local raw=$(( (hit * 10000) / total ))
    local int=$(( raw / 100 ))
    local dec=$(( raw % 100 ))
    if [ $dec -lt 10 ]; then dec="0$dec"; fi
    echo "${int}.${dec}"
}

format_size() {
    local bytes=$1
    local mb=$(( bytes / 1024 / 1024 ))
    if [ "$mb" -ge 1024 ]; then
        local int=$(( mb / 1024 ))
        local dec=$(( (mb * 10 / 1024) % 10 ))
        echo "${int}.${dec} GB"
    else
        echo "${mb} MB"
    fi
}

echo -e "${BLUE}=== Gathering Initial ARC Metrics... ===${NC}"
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

echo -e "${YELLOW}Starting real-time activity & PSI analysis...${NC}"

for ((i=INTERVAL; i>0; i--)); do
    elapsed=$((INTERVAL - i))
    filled=$(( (elapsed * 20) / INTERVAL ))
    unfilled=$(( 20 - filled ))
   
    bar=$(printf "%-${filled}s" "#" | tr ' ' '#')
    spaces=$(printf "%-${unfilled}s" " ")
   
    printf "\r[${GREEN}%s${NC}%s] Time remaining: ${YELLOW}%2d${NC} sec..." "$bar" "$spaces" "$i"
    sleep 1
done
printf "\r%-60s\r" " "

echo -e "${BLUE}=== Gathering Final ARC Metrics... ===${NC}"
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

psi_mem_some=$(get_psi_stat some memory)
psi_mem_full=$(get_psi_stat full memory)
psi_io_some=$(get_psi_stat some io)

size=$(get_arc_stat size)
c_min=$(get_arc_stat c_min)
c_max=$(get_arc_stat c_max)
meta_limit=$(get_arc_stat arc_meta_limit)

meta_used=$(get_arc_stat arc_meta_used)
if [ "$meta_used" -eq 0 ]; then
    meta_used=$(get_arc_stat meta_used)
fi

if [ "$meta_limit" -eq 0 ]; then
    meta_limit=$(( (c_max * 75) / 100 ))
    meta_mode="Dynamic"
else
    meta_mode="Fixed"
fi

d_hits=$((h2 - h1))
d_misses=$((m2 - m1))
d_total=$((d_hits + d_misses))
d_dhits=$((dh2 - dh1))
d_dmisses=$((dm2 - dm1))
d_dtotal=$((d_dhits + d_dmisses))
d_mhits=$((mh2 - mh1))
d_mmisses=$((mm2 - mm1))
d_mtotal=$((d_mhits + d_mmisses))

d_pfhits=$(( (pf_dh2 - pf_dh1) + (pf_mh2 - pf_mh1) ))
d_pfmisses=$(( (pf_dm2 - pf_dm1) + (pf_mm2 - pf_mm1) ))
d_pftotal=$(( d_pfhits + d_pfmisses ))

d_other_hits=$(( d_hits - d_dhits - d_mhits - d_pfhits ))
d_other_misses=$(( d_misses - d_dmisses - d_mmisses - d_pfmisses ))
d_othertotal=$(( d_other_hits + d_other_misses ))

d_deleted=$((del2 - del1))

echo -e "\n${BLUE}=== CURRENT CACHE STATUS ===${NC}"
echo -e "Current ARC Size:      ${GREEN}$(format_size $size)${NC}"
echo -e "ARC Limit Settings:    Min: ${YELLOW}$(format_size $c_min)${NC}  /  Max: ${YELLOW}$(format_size $c_max)${NC}"
echo -e "Metadata Cache:        ${GREEN}$(format_size $meta_used)${NC} / ${GREEN}$(format_size $meta_limit)${NC} (${meta_mode})"

echo -e "\n${BLUE}=== OS RESOURCE PRESSURE (PSI) ===${NC}"
echo -e "RAM Stall Pressure:    Processes waiting: ${YELLOW}${psi_mem_some}%${NC} | System paralyzed: ${RED}${psi_mem_full}%${NC}"
echo -e "I/O Stall Pressure:    Processes waiting: ${YELLOW}${psi_io_some}%${NC}"

echo -e "\n${BLUE}=== CACHE EFFICIENCY FOR THE LAST ${INTERVAL} SEC ===${NC}"

if [ "$d_total" -eq 0 ]; then
    echo -e "${YELLOW}No disk requests detected in the last ${INTERVAL} seconds. System is idling.${NC}"
    exit 0
fi

hr_total=$(calc_percent $d_hits $d_total)
hr_data=$(calc_percent $d_dhits $d_dtotal)
hr_meta=$(calc_percent $d_mhits $d_mtotal)
hr_prefetch=$(calc_percent $d_pfhits $d_pftotal)

echo -e "Total Efficiency:         ${GREEN}${hr_total}%${NC} (Total Requests: ${d_total}, Misses: ${d_misses})"
echo -e "  └─ Core DATA:           ${GREEN}${hr_data}%${NC} (Requests: ${d_dtotal}, Misses: ${d_dmisses})"
echo -e "  └─ METADATA:            ${GREEN}${hr_meta}%${NC} (Requests: ${d_mtotal}, Misses: ${d_mmisses})"
echo -e "  └─ Prefetch (Read-ahead):${GREEN}${hr_prefetch}%${NC} (Requests: ${d_pftotal}, Misses: ${d_pfmisses})"

if [ "$d_othertotal" -gt 0 ]; then
    hr_other=$(calc_percent $d_other_hits $d_othertotal)
    echo -e "  └─ System/Other:        ${GREEN}${hr_other}%${NC} (Requests: ${d_othertotal}, Misses: ${d_other_misses})"
fi
echo -e "Evicted Blocks (Cache):   ${YELLOW}${d_deleted}${NC}"

echo -e "\n${BLUE}=== ANALYSIS & RECOMMENDATION ===${NC}"

hr_total_int=${hr_total%.*}
hr_meta_int=${hr_meta%.*}
psi_mem_full_int=${psi_mem_full%.*}
psi_io_int=${psi_io_some%.*}

if [ "$psi_mem_full_int" -gt 5 ]; then
    echo -e "${RED}[CRITICAL RAM DEFICIT] System is paralyzed due to lack of memory (${psi_mem_full}% stall time).${NC}"
    echo -e "-> ZFS ARC is heavily constrained, or VMs have overcommitted host RAM."
    echo -e "-> Recommendation: Add physical RAM immediately, or reduce VM memory allocation."
elif [ "$hr_total_int" -lt 80 ] && [ "$psi_io_int" -gt 15 ]; then
    echo -e "${RED}[WARNING: STORAGE BOTTLENECK] Low cache hit rate (${hr_total}%) causes CPU stall on I/O (${psi_io_some}%).${NC}"
    echo -e "-> VM processes are noticeably lagging while waiting for physical disks."
    echo -e "-> Recommendation: **EXPAND ZFS ARC** (by at least 8-16 GB). If RAM is low, consider adding NVMe for **L2ARC**."
elif [ "$hr_total_int" -lt 85 ] && [ "$psi_io_int" -le 5 ]; then
    echo -e "${YELLOW}[STABLE] Cache efficiency is low (${hr_total}%), but storage handles requests fast enough before processes lag.${NC}"
    echo -e "-> I/O pressure is minimal (${psi_io_some}%). Expanding ARC is optional, but not urgently required right now."
elif [ "$hr_meta_int" -lt 85 ] && [ "$d_mtotal" -gt 500 ]; then
    echo -e "${RED}[WARNING] Reduced METADATA cache efficiency (${hr_meta}%)${NC}"
    echo -e "-> Recommendation: Increase total ARC limit so filesystem index structures don't get evicted."
elif [ "$d_deleted" -gt 5000 ]; then
    echo -e "${YELLOW}[WARNING] High data churn rate (evicted: ${d_deleted} blocks).${NC}"
    echo -e "-> Recommendation: Consider expanding ARC by 4-8 GB to preserve the active working set."
else
    echo -e "${GREEN}[EXCELLENT] High cache efficiency (${hr_total}%), no resource pressure detected.${NC}"
    echo -e "-> No limit adjustments required. Your system is perfectly optimized."
fi
