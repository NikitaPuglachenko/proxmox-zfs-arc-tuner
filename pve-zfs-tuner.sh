#!/usr/bin/env bash
# Proxmox VE ZFS ARC Tuner (Fixed & Enhanced)
set -e

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
    elif command -v arcstat &>/dev/null; then
        # Fallback to arcstat parse in bytes (-p)
        arcstat -p 1 1 | awk 'NR==2 {print $2}' 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# 2. Gather system memory metrics
TOTAL_RAM_BYTES=$(free -b | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$(format_bytes "$TOTAL_RAM_BYTES" 3)
CURRENT_ARC_BYTES=$(get_current_arc_bytes)
CURRENT_ARC_GB=$(format_bytes "$CURRENT_ARC_BYTES" 3)

# Fetch active kernel limit (Runtime Limit)
RUNTIME_LIMIT_BYTES=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo 0)
RUNTIME_LIMIT=$([ "$RUNTIME_LIMIT_BYTES" -eq 0 ] && echo "Unlimited" || echo "$(format_bytes "$RUNTIME_LIMIT_BYTES" 3) GB")

# Fetch persistent limit from config file
CONFIG_FILE="/etc/modprobe.d/zfs.conf"
CURRENT_CONFIG_LIMIT="Not set"
if [ -f "$CONFIG_FILE" ]; then
    LIMIT_BYTES=$(awk -F'=' '/zfs_arc_max/ {gsub(/[[:space:]]/,"",$2); print $2}' "$CONFIG_FILE")
    [ -n "$LIMIT_BYTES" ] && CURRENT_CONFIG_LIMIT="$(format_bytes "$LIMIT_BYTES" 3) GB"
fi

# 3. Calculate total raw storage space from all ZFS pools
TOTAL_POOL_BYTES=$(zpool list -p -H -o size 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
TOTAL_POOL_TIB=$(format_bytes "$TOTAL_POOL_BYTES" 4)

# 4. Perform Recommendation Sizing Logic (2GB baseline + 1GB per 1TB rounded up)
RAM_10_BYTES=$(( TOTAL_RAM_BYTES / 10 ))
RAM_10_GB=$(format_bytes "$RAM_10_BYTES" 3)

# Bash math trick for Ceiling division
ONE_TIB_BYTES=1099511627776
RAW_STORAGE_TIB_ROUNDED=$(( (TOTAL_POOL_BYTES + ONE_TIB_BYTES - 1) / ONE_TIB_BYTES ))
[ "$TOTAL_POOL_BYTES" -eq 0 ] && RAW_STORAGE_TIB_ROUNDED=0

# Formula fix: 1 GiB for every 1 TiB (according to the article)
FORMULA_GB_VAL=$(( 2 + (1 * RAW_STORAGE_TIB_ROUNDED) ))
FORMULA_BYTES=$(( FORMULA_GB_VAL * 1024 * 1024 * 1024 ))

# Determine the optimal sizing target
if [ "$FORMULA_BYTES" -lt "$RAM_10_BYTES" ] && [ "$TOTAL_POOL_BYTES" -lt $(( 10 * ONE_TIB_BYTES )) ]; then
    REC_BYTES=$FORMULA_BYTES
    REC_REASON="Formula: 2GB base + 1GB per 1TB (rounded to ${RAW_STORAGE_TIB_ROUNDED} TiB)"
else
    REC_BYTES=$RAM_10_BYTES
    REC_REASON="10% of host RAM"
fi

# Soft-cap the recommendation to 32 GB unless the storage size dictates otherwise
MAX_32GB_BYTES=34359738368
if [ "$REC_BYTES" -gt "$MAX_32GB_BYTES" ] && [ "$TOTAL_POOL_BYTES" -lt $(( 32 * ONE_TIB_BYTES )) ]; then
    REC_BYTES=$MAX_32GB_BYTES
    REC_REASON="Capped to 32 GB"
fi
REC_GB=$(format_bytes "$REC_BYTES" 3)

# 5. Display current environment state
echo -e "\033[0;33mCurrent System State:\033[0m"
echo -e "  Host Total RAM:         \033[0;32m${TOTAL_RAM_GB} GB\033[0m"
echo -e "  Total Raw ZFS Storage:  \033[0;32m${TOTAL_POOL_TIB} TiB\033[0m"
echo -e "  Current ARC Footprint:  \033[0;32m${CURRENT_ARC_GB} GB\033[0m (actual RAM used)"
echo -e "  Active Kernel Limit:    \033[0;32m${RUNTIME_LIMIT}\033[0m"
echo -e "  Persistent Config Limit:\033[0;32m${CURRENT_CONFIG_LIMIT}\033[0m\n"

echo -e "\033[0;33mCalculated Target Options:\033[0m"
echo -e "  - 10% of Host RAM:      \033[0;34m${RAM_10_GB} GB\033[0m"
echo -e "  - Capacity Formula:     \033[0;34m${FORMULA_GB_VAL}.00 GB\033[0m"
echo -e "  * Smart Recommendation: \033[0;32m${REC_GB} GB\033[0m [Reason: ${REC_REASON}]\n"

echo -e "\033[0;33mChoose your configuration target:\033[0m"
echo -e "  1) Apply Smart Recommendation (${REC_GB} GB) + Start 15s Verification"
echo -e "  2) Define custom limit manually"
echo -e "  *) Cancel and exit\n"

read -p "Select option (1/2/*): " CONFIG_CHOICE

case $CONFIG_CHOICE in
    1) TARGET_BYTES=$REC_BYTES ;;
    2)
        read -p "Enter your custom limit in Gigabytes: " USER_GB
        [[ "$USER_GB" =~ ^[0-9]+$ ]] || { echo -e "\033[0;31m[ERROR] Invalid input.\033[0m"; exit 1; }
        TARGET_BYTES=$(( USER_GB * 1024 * 1024 * 1024 ))
        ;;
    *) echo -e "\033[0;33mOperation cancelled.\033[0m"; exit 0 ;;
esac

# 6. Apply runtime modifications and perform feedback loop
if echo "$TARGET_BYTES" > /sys/module/zfs/parameters/zfs_arc_max; then
    echo -e "\033[0;32m[Step 1] Target limit temporarily applied to kernel.\033[0m"
else
    echo -e "\033[0;31m[ERROR] Failed to update /sys parameter.\033[0m"; exit 1
fi

# Verification loop (now triggers for both Option 1 and Option 2)
echo -ne "\033[0;33m[Step 2] Waiting 15 seconds to monitor cache eviction... \033[0m"
for i in {15..1}; do echo -ne "$i.."; sleep 1; done
echo -e " Done."

POST_ARC_BYTES=$(get_current_arc_bytes)

# Check if the cache footprint failed to drop to the target limit
if [ "$POST_ARC_BYTES" -gt "$TARGET_BYTES" ]; then
    echo -e "\n\033[0;31m[ATTENTION] ZFS cache footprint remains high: $(format_bytes "$POST_ARC_BYTES" 3) GB\033[0m"
    echo -e "It seems the cache is actively holding metadata or handling live VM workloads right now."

    ONE_GB_BYTES=1073741824
    ROUNDED_CURRENT_GB=$(( (POST_ARC_BYTES + ONE_GB_BYTES - 1) / ONE_GB_BYTES ))
    ADAPTIVE_BYTES=$(( ROUNDED_CURRENT_GB * ONE_GB_BYTES ))

    echo -e "\nHow would you like to proceed?"
    echo -e "  1) Enforce original target ($(format_bytes "$TARGET_BYTES" 3) GB) and wait for kernel to clean it up later"
    echo -e "  2) Adapt to current workload and raise limit to safe \033[0;32m${ROUNDED_CURRENT_GB}.00 GB\033[0m (rounded up)"
    echo -e "  *) Keep things as they are / Cancel save"

    read -p "Select adaptive action (1/2/*): " WORKLOAD_CHOICE

    case $WORKLOAD_CHOICE in
        1)
            echo -e "\033[0;33mOriginal target kept. ZFS will evict data on demand.\033[0m"
            ;;
        2)
            TARGET_BYTES=$ADAPTIVE_BYTES
            echo "$TARGET_BYTES" > /sys/module/zfs/parameters/zfs_arc_max
            echo -e "\033[0;32mKernel limit updated to safe workload value: ${ROUNDED_CURRENT_GB}.00 GB\033[0m"
            ;;
        *)
            echo -e "\033[0;33mOperation cancelled. No changes will be saved to configuration file.\033[0m"
            exit 0
            ;;
    esac
else
    echo -e "\033[0;32m[SUCCESS] ZFS successfully evicted cache down toward target limit.\033[0m"
fi

TARGET_GB=$(format_bytes "$TARGET_BYTES" 3)
echo -e "\n\033[0;33mFinal Selected Target Limit:\033[0m ${TARGET_GB} GB (${TARGET_BYTES} bytes)"

# 7. Make modifications permanent (with Proxmox boot tool handling)
read -p "Save this finalized configuration permanently to $CONFIG_FILE? (y/n): " SAVE_PERM
if [[ "$SAVE_PERM" =~ ^[Yy]$ ]]; then
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak" && sed -i '/zfs_arc_max/d' "$CONFIG_FILE"
    echo "options zfs zfs_arc_max=$TARGET_BYTES" >> "$CONFIG_FILE"
    echo -e "\033[0;32m[SUCCESS] Configuration saved to $CONFIG_FILE\033[0m"
fi

