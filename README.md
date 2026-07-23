# Proxmox VE ZFS ARC Tuner & Analyzer

A set of Bash tools for managing and diagnosing the ZFS Adaptive Replacement Cache (ARC) on Proxmox VE hosts.

The project provides two complementary tools:

- **`pve-zfs-tuner.sh`** — calculates and applies a recommended ZFS ARC limit to prevent ZFS from consuming excessive host RAM.
- **`pve-zfs-analyzer.sh`** — analyzes ARC efficiency and system memory/I/O pressure to help determine whether the current ARC configuration is appropriate.

Recommended workflow:

**Analyze → Tune → Analyze again**

## 🚀 ZFS ARC Tuner

`pve-zfs-tuner.sh` is an interactive tool for configuring the maximum ZFS ARC size.

### Key Features

- **Auto-Discovery** — detects host RAM, active ZFS pools, and storage capacity.
- **Smart Recommendations** — calculates an ARC target using storage capacity and host RAM constraints.
- **Interactive Control** — apply the recommendation, set a custom limit, or cancel safely.
- **Workload Monitoring** — monitors ARC eviction behavior after configuration changes.
- **Persistent Configuration** — updates `/etc/modprobe.d/zfs.conf` with backups.

### Sizing Logic

The Smart Recommendation is calculated from the total raw capacity of all active ZFS pools:

- **Baseline formula:** 2 GB + 1 GB per 1 TiB of raw ZFS storage, rounded up to the next TiB.
- **Recommended Min:** 50% of the baseline formula.
- **Recommended Max:** 2× the baseline formula (4× the recommended Min).
- **RAM Safety Cap:** If the calculated Max exceeds 10% of total host RAM, Max is capped at 10% of host RAM and Min is set to 25% of the capped Max.

The 10% host RAM value is therefore a **safety cap for the recommended ARC maximum**, not the primary sizing formula.

## 🔍 ZFS ARC Analyzer

`pve-zfs-analyzer.sh` is a read-only diagnostic tool that measures ARC performance over a 30-second interval.

It reports:

- Current ARC size and limits
- Metadata cache usage
- Total ARC hit rate
- Data, metadata, and prefetch hit rates
- Cache eviction rate
- Memory PSI pressure
- I/O PSI pressure

The analyzer provides basic recommendations based on the observed combination of ARC efficiency and system resource pressure, helping identify potential:

- RAM shortages
- Storage I/O bottlenecks
- Low metadata cache efficiency
- High ARC cache churn
- Situations where increasing ARC is unlikely to help

The analyzer does **not** modify any system configuration.

## 📦 Quick Usage

### ARC Tuner

```bash
curl -sSL https://raw.githubusercontent.com/NikitaPuglachenko/proxmox-zfs-arc-tuner/refs/heads/main/pve-zfs-tuner.sh -o pve-zfs-tuner.sh
chmod +x pve-zfs-tuner.sh
sudo ./pve-zfs-tuner.sh
```

### ARC Analyzer

```bash
curl -sSL https://raw.githubusercontent.com/NikitaPuglachenko/proxmox-zfs-arc-tuner/refs/heads/main/pve-zfs-analyzer.sh -o pve-zfs-analyzer.sh
chmod +x pve-zfs-analyzer.sh
sudo ./pve-zfs-analyzer.sh
```

## 🛠️ Requirements

* Proxmox VE (or any Debian-based system running ZFS on Linux).
* Root privileges (`sudo` access).
* Active ZFS pools loaded into the kernel.
* Linux PSI support for the analyzer

## ⚠️ Disclaimer

Modifying kernel and filesystem parameters can impact performance depending on your specific workloads (e.g., heavy database tracking, high IOPS storage pools). Always verify your configuration adjustments in a staging environment if running highly critical production systems.

ARC sizing is workload-dependent. A low cache hit rate does not necessarily mean that increasing ARC will improve performance, while a high hit rate does not guarantee that the host has sufficient RAM.

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).
