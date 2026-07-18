# Proxmox VE ZFS ARC Tuner

A smart, interactive Bash script designed to optimize and manage the ZFS Adaptive Replacement Cache (ARC) size on Proxmox VE hosts. It prevents ZFS from consuming excessive RAM, protecting your hypervisor from Out-Of-Memory (OOM) crashes while maintaining optimal storage performance.

## 🚀 Key Features

* **Auto-Discovery:** Automatically detects total host RAM, existing active ZFS pools, and current raw storage capacity.
* **Smart Recommendation Engine:** Calculates the optimal ARC size using a 2GB baseline + 1GB per 1TB storage formula, capped intelligently at 10% of host RAM or a soft ceiling of 32GB.
* **Interactive Control:** Allows you to apply the smart recommendation, set a manual custom limit, or cancel operations safely.
* **Workload Monitoring Loop:** Temporarily applies changes and monitors the cache eviction behavior for 15 seconds.
* **Adaptive Safety Net:** If active VM workloads or metadata locking prevent immediate cache eviction, the script offers an adaptive option to scale up to a safe rounded limit.
* **Persistent Configuration:** Automatically updates `/etc/modprobe.d/zfs.conf` with backups and prepares system configs for standard Proxmox boot tool layouts.

## 📊 Sizing Logic

The script evaluates three different options to determine the best fit for your node:
1. **10% Host RAM Baseline:** A safe minimal footprint for highly consolidated virtualization hosts.
2. **Capacity-Based Formula:** 2 GB base + 1 GB for every 1 TiB of raw ZFS pool capacity (rounded up).
3. **Smart Recommendation:** The optimized target balance based on active system scaling constraints.

## 📦 Quick Installation & Usage

Run the script directly on your Proxmox VE host as `root`:

```bash
curl -sSL https://raw.githubusercontent.com/NikitaPuglachenko/proxmox-zfs-arc-tuner/refs/heads/main/pve-zfs-tuner.sh -o pve-zfs-tuner.sh
chmod +x pve-zfs-tuner.sh
sudo ./pve-zfs-tuner.sh
```

## 🛠️ Requirements

* Proxmox VE (or any Debian-based system running ZFS on Linux).
* Root privileges (`sudo` access).
* Active ZFS pools loaded into the kernel.

## ⚠️ Disclaimer

Modifying kernel and filesystem parameters can impact performance depending on your specific workloads (e.g., heavy database tracking, high IOPS storage pools). Always verify your configuration adjustments in a staging environment if running highly critical production systems.

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).

