#!/usr/bin/env bash
# Proxmox VE ZFS ARC Tuner (Fixed & Enhanced with Min/Max Logic)
set -e

# 0. Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR] This script must be run as root (via sudo).\033[0m"
    exit 1
fi

# 1. Check if ZFS module is loaded
if ! lsmod | grep -q zfs; then
    echo -e "\033[0;31m[ERROR] ZFS module is not loaded.\033[0m"
    exit 1
fi

# Helper function to convert bytes to GB/TB via awk
format_bytes() {
    awk -v b="$1" -v s="$2" 'BEGIN {printf "%.2f", b / (1024^s)}'
}

# Helper function to fetch current ARC size safely
get_current_arc_bytes() {
    if [ -f /proc/spl/kstat/zfs/arcstats ]; then
        awk '/^size/ {print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# 2. Gather system memory metrics
TOTAL_RAM_BYTES=$(free -b | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$(format_bytes "$TOTAL_RAM_BYTES" 3)
CURRENT_ARC_BYTES=$(get_current_arc_bytes)
CURRENT_ARC_GB=$(format_bytes "$CURRENT_ARC_BYTES" 3)

# Fetch active kernel limits (Runtime Limits)
RUNTIME_MAX_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo 0)
RUNTIME_MAX=$([ "$RUNTIME_MAX_BYTES" -eq 0 ] && echo "Unlimited" || echo "$(format_bytes "$RUNTIME_MAX_BYTES" 3) GB")
RUNTIME_MIN_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_min 2>/dev/null || echo 0)
RUNTIME_MIN="$(format_bytes "$RUNTIME_MIN_BYTES" 3) GB"

# Fetch persistent limits from config file (Fixed parsing logic)
CONFIG_FILE="/etc/modprobe.d/zfs.conf"
CURRENT_CONFIG_MAX="Not set"
CURRENT_CONFIG_MIN="Not set"
if [ -f "$CONFIG_FILE" ]; then
    L_MAX_BYTES=$(grep -E "options zfs" "$CONFIG_FILE" | grep -oE "zfs_arc_max=[0-9]+" | cut -d= -f2 || true)
    L_MIN_BYTES=$(grep -E "options zfs" "$CONFIG_FILE" | grep -oE "zfs_arc_min=[0-9]+" | cut -d= -f2 || true)
    [ -n "$L_MAX_BYTES" ] && CURRENT_CONFIG_MAX="$(format_bytes "$L_MAX_BYTES" 3) GB"
    [ -n "$L_MIN_BYTES" ] && CURRENT_CONFIG_MIN="$(format_bytes "$L_MIN_BYTES" 3) GB"
fi

# 3. Calculate total raw storage space from all ZFS pools
TOTAL_POOL_BYTES=$(zpool list -p -H -o size 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
TOTAL_POOL_TIB=$(format_bytes "$TOTAL_POOL_BYTES" 4)

# 4. Perform Recommendation Sizing Logic
RAM_10_BYTES=$(( TOTAL_RAM_BYTES / 10 ))
RAM_10_GB=$(format_bytes "$RAM_10_BYTES" 3)

# Bash math trick for Ceiling division (rounded up TB)
ONE_TIB_BYTES=1099511627776
RAW_STORAGE_TIB_ROUNDED=$(( (TOTAL_POOL_BYTES + ONE_TIB_BYTES - 1) / ONE_TIB_BYTES ))
[ "$TOTAL_POOL_BYTES" -eq 0 ] && RAW_STORAGE_TIB_ROUNDED=0

# Baseline sizing formula: 2GB baseline + 1GB per 1TB of raw storage
BASE_MB=2048
PER_TB_MB=1024
FULL_RECOMMENDATION_MB=$(( BASE_MB + (PER_TB_MB * RAW_STORAGE_TIB_ROUNDED) ))

# Define proportions:
# - Min: 50% (0.5x) of the baseline recommendation
# - Max: 200% (2.0x) of the baseline recommendation, making Max exactly 4x of Min
REC_MIN_MB=$(( FULL_RECOMMENDATION_MB / 2 ))
FORMULA_MIN_BYTES=$(( REC_MIN_MB * 1024 * 1024 ))
FORMULA_MAX_BYTES=$(( FORMULA_MIN_BYTES * 4 ))

# SAFETY CAP: If Formula Max exceeds 10% of host RAM, throttle down to 10% RAM max capacity
if [ "$FORMULA_MAX_BYTES" -gt "$RAM_10_BYTES" ]; then
    REC_MAX_BYTES=$RAM_10_BYTES
    # Maintain strict 1:4 layout ratio (Min always equals Max / 4)
    REC_MIN_BYTES=$(( REC_MAX_BYTES / 4 ))
    REC_REASON="Capped to 10% of host RAM (Formula exceeded safe threshold)"
else
    REC_MIN_BYTES=$FORMULA_MIN_BYTES
    REC_MAX_BYTES=$FORMULA_MAX_BYTES
    REC_REASON="Min = 50% of formula (2GB+1GB/TB), Max = 2x formula (4x of Min)"
fi

REC_MIN_GB=$(format_bytes "$REC_MIN_BYTES" 3)
REC_MAX_GB=$(format_bytes "$REC_MAX_BYTES" 3)

# 5. Display current environment state
echo -e "\033[0;33mCurrent System State:\033[0m"
echo -e "  Host Total RAM:         \033[0;32m${TOTAL_RAM_GB} GB\033[0m"
echo -e "  Total Raw ZFS Storage:  \033[0;32m${TOTAL_POOL_TIB} TiB\033[0m (Rounded: ${RAW_STORAGE_TIB_ROUNDED} TB)"
echo -e "  Current ARC Footprint:  \033[0;32m${CURRENT_ARC_GB} GB\033[0m (actual RAM used)"
echo -e "  Active Kernel Limits:   \033[0;32mMin: ${RUNTIME_MIN} / Max: ${RUNTIME_MAX}\033[0m"
echo -e "  Persistent Config:      \033[0;32mMin: ${CURRENT_CONFIG_MIN} / Max: ${CURRENT_CONFIG_MAX}\033[0m\n"

echo -e "\033[0;33mCalculated Target Options:\033[0m"
echo -e "  - 10% of Host RAM (Max Limit): \033[0;34m${RAM_10_GB} GB\033[0m"
echo -e "  - Raw Formula (Max Limit):     \033[0;34m$(format_bytes "$FORMULA_MAX_BYTES" 3) GB\033[0m"
echo -e "  * Smart Recommendation:        \033[0;32mMin: ${REC_MIN_GB} GB / Max: ${REC_MAX_GB} GB\033[0m"
echo -e "                                 [Reason: ${REC_REASON}]\n"

echo -e "\033[0;33mChoose your configuration target:\033[0m"
echo -e "  1) Apply Smart Recommendation (Min: ${REC_MIN_GB}G / Max: ${REC_MAX_GB}G) + 10s Verification"
echo -e "  2) Define custom limits manually"
echo -e "  *) Cancel and exit\n"

read -p "Select option (1/2/*): " CONFIG_CHOICE

case $CONFIG_CHOICE in
    1)
        TARGET_MIN_BYTES=$REC_MIN_BYTES
        TARGET_MAX_BYTES=$REC_MAX_BYTES
        ;;
    2)
        read -p "Enter your custom MIN limit in Gigabytes: " USER_MIN_GB
        [[ "$USER_MIN_GB" =~ ^[0-9]+$ ]] || { echo -e "\033[0;31m[ERROR] Invalid input.\033[0m"; exit 1; }
        TARGET_MIN_BYTES=$(( USER_MIN_GB * 1024 * 1024 * 1024 ))

        read -p "Enter your custom MAX limit in Gigabytes (must be >= MIN): " USER_MAX_GB
        [[ "$USER_MAX_GB" =~ ^[0-9]+$ ]] || { echo -e "\033[0;31m[ERROR] Invalid input.\033[0m"; exit 1; }
        TARGET_MAX_BYTES=$(( USER_MAX_GB * 1024 * 1024 * 1024 ))

        if [ "$TARGET_MIN_BYTES" -gt "$TARGET_MAX_BYTES" ]; then
            echo -e "\033[0;31m[ERROR] MIN limit cannot be greater than MAX limit.\033[0m"
            exit 1
        fi
        ;;
    *) echo -e "\033[0;33mOperation cancelled.\033[0m"; exit 0 ;;
esac

# 6. Apply runtime modifications (CRITICAL ORDER: MIN FIRST, THEN MAX)
CURRENT_LIVE_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo 0)

if [ "$TARGET_MIN_BYTES" -gt "$CURRENT_LIVE_MAX" ] && [ "$CURRENT_LIVE_MAX" -ne 0 ]; then
    echo "$TARGET_MAX_BYTES" > /sys/module/zfs/parameters/zfs_arc_max
fi

if echo "$TARGET_MIN_BYTES" > /sys/module/zfs/parameters/zfs_arc_min; then
    echo -e "\033[0;32m[Step 1a] Target MIN limit temporarily applied to kernel.\033[0m"
else
    echo -e "\033[0;31m[ERROR] Failed to update zfs_arc_min parameter.\033[0m"; exit 1
fi

if echo "$TARGET_MAX_BYTES" > /sys/module/zfs/parameters/zfs_arc_max; then
    echo -e "\033[0;32m[Step 1b] Target MAX limit temporarily applied to kernel.\033[0m"
else
    echo -e "\033[0;31m[ERROR] Failed to update zfs_arc_max parameter.\033[0m"; exit 1
fi

# Verification loop
echo -ne "\033[0;33m[Step 2] Waiting 10 seconds to monitor cache eviction... \033[0m"
for i in {10..1}; do echo -ne "$i.."; sleep 1; done
echo -e " Done."

POST_ARC_BYTES=$(get_current_arc_bytes)
if [ "$POST_ARC_BYTES" -gt "$TARGET_MAX_BYTES" ]; then
    echo -e "\n\033[0;31m[ATTENTION] ZFS cache footprint remains higher than Max: $(format_bytes "$POST_ARC_BYTES" 3) GB\033[0m"
    echo -e "ZFS will evict data gradually as the system demands memory or active operations decrease."
else
    echo -e "\033[0;32m[SUCCESS] ZFS successfully stabilizing cache within target limits.\033[0m"
fi

FINAL_MIN_GB=$(format_bytes "$TARGET_MIN_BYTES" 3)
FINAL_MAX_GB=$(format_bytes "$TARGET_MAX_BYTES" 3)
echo -e "\n\033[0;33mFinal Selected Target Limits:\033[0m"
echo -e "  zfs_arc_min: ${FINAL_MIN_GB} GB (${TARGET_MIN_BYTES} bytes)"
echo -e "  zfs_arc_max: ${FINAL_MAX_GB} GB (${TARGET_MAX_BYTES} bytes)"

# 7. Make modifications permanent (Fixed creation and single-line options cleanup)
read -p "Save this finalized configuration permanently to $CONFIG_FILE? (y/n): " SAVE_PERM
if [[ "$SAVE_PERM" =~ ^[Yy]$ ]]; then
    touch "$CONFIG_FILE"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # Completely wipe out older zfs configuration lines
    sed -i '/options zfs/d' "$CONFIG_FILE"

    # Append clean single-line configuration formatted with spaces
    echo "options zfs zfs_arc_min=$TARGET_MIN_BYTES zfs_arc_max=$TARGET_MAX_BYTES" >> "$CONFIG_FILE"
    echo -e "\033[0;32m[SUCCESS] Configuration saved to $CONFIG_FILE\033[0m"
fi
