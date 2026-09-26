# Proxmox VE ZFS ARC Tuner & Analyzer

A set of Bash tools for managing and diagnosing the ZFS Adaptive Replacement Cache (ARC) on Proxmox VE hosts.

The project provides two complementary tools:

- **`pve-zfs-tuner.sh`** — calculates and applies a recommended ZFS ARC limit to prevent ZFS from consuming excessive host RAM.
- **`pve-zfs-analyzer.sh`** — analyzes ARC efficiency and system memory/I/O pressure to help determine whether the current ARC configuration is appropriate.

Recommended workflow:

**Analyze → Tune → Analyze again**

## 🚀 ZFS ARC Tuner

`pve-zfs-tuner.sh` configures the minimum and maximum ZFS ARC size, interactively or with command line options.

### Key Features

- **Auto-Discovery** — detects host RAM, active ZFS pools, storage capacity and the current limits.
- **Smart Recommendations** — calculates an ARC target using storage capacity and host RAM constraints.
- **Interactive or Automated** — use the menu, or options for scripts and configuration management (`--recommended --yes`).
- **Safe Limits** — rejects values ZFS would silently ignore and verifies that the kernel accepted the new limits.
- **Dry Run** — shows the recommendation and the planned changes without touching the system.
- **Persistent Configuration** — updates `/etc/modprobe.d/zfs.conf`, keeps your other ZFS options, makes a timestamped backup and updates the initramfs when the root filesystem is on ZFS.
- **Reset** — returns to the ZFS defaults.

### Sizing Logic

The Smart Recommendation is calculated from the total raw capacity of all active ZFS pools:

- **Baseline formula:** 2 GiB + 1 GiB per 1 TiB of raw ZFS storage, rounded up to the next TiB (the Proxmox guideline).
- **Recommended Min:** 50% of the baseline formula.
- **Recommended Max:** 2× the baseline formula (4× the recommended Min).
- **RAM Safety Cap:** If the calculated Max exceeds 10% of total host RAM, Max is capped at 10% of host RAM and Min is set to 25% of the capped Max.

The 10% host RAM value is therefore a **safety cap for the recommended ARC maximum**, not the primary sizing formula. When the cap brings Max below the Proxmox guideline, the tuner points it out, so you can decide whether the host can spare more memory.

### Options

| Option | Description |
|--------|-------------|
| `--recommended` | Apply the smart recommendation |
| `--min SIZE --max SIZE` | Apply custom limits, e.g. `4G`, `512M`; a plain number means GiB |
| `--reset` | Remove the limits and return to the ZFS defaults |
| `--persist` / `--no-persist` | Save to `/etc/modprobe.d/zfs.conf` without asking / apply to the running kernel only |
| `-y`, `--yes` | Answer yes to all questions |
| `--dry-run` | Show what would be done without changing anything (does not require root) |
| `--wait SECONDS` | Seconds to monitor cache eviction after applying (default: 10, `0` to skip) |
| `-h`, `--help` / `--version` | Show help / version |

Without a target option, the tuner shows an interactive menu.

```bash
# Only see the recommendation
./pve-zfs-tuner.sh --dry-run

# Apply and save the recommendation without questions
sudo ./pve-zfs-tuner.sh --recommended --yes

# Custom limits for the running kernel only
sudo ./pve-zfs-tuner.sh --min 2G --max 8G --no-persist --yes
```

### Limits

ZFS accepts any value written to its parameters but silently ignores invalid ones, so the tuner rejects them upfront:

- Min must be at least 32 MiB, Max at least 64 MiB
- Max must be greater than Min
- Max must be less than the host RAM (a warning is shown above 50%)

After applying, the tuner compares the active limits reported by ZFS with the requested ones.

### Persistent Configuration

When saving, the tuner:

1. Backs up `/etc/modprobe.d/zfs.conf` to `zfs.conf.bak.<timestamp>`.
2. Replaces only `zfs_arc_min` and `zfs_arc_max`, keeping all other `options zfs` settings.
3. Runs `update-initramfs -u -k all` when the root filesystem is on ZFS. The ZFS module is then loaded from the initramfs, so without this step the saved limits would not apply after a reboot.

## 🔍 ZFS ARC Analyzer

`pve-zfs-analyzer.sh` is a read-only diagnostic tool that measures ARC performance over a 30-second interval (`--interval SECONDS` to change it).

It reports:

- Current ARC size and limits
- Metadata cache usage (`metadata_size` on OpenZFS 2.2+, which no longer has a fixed metadata limit)
- Total ARC hit rate
- Data, metadata, and prefetch hit rates
- Cache eviction rate
- Memory PSI pressure
- I/O PSI pressure

Hit rates and PSI pressure are measured over the same interval.

The analyzer provides basic recommendations based on the observed combination of ARC efficiency and system resource pressure, helping identify potential:

- RAM shortages
- Storage I/O bottlenecks
- Low metadata cache efficiency
- High ARC cache churn
- Situations where increasing ARC is unlikely to help

The analyzer does **not** modify any system configuration.

## 📦 Quick Usage

Download a released version and verify its checksum:

```bash
VERSION=v1.0.0
BASE=https://github.com/NikitaPuglachenko/proxmox-zfs-arc-tuner/releases/download/${VERSION}
curl -fsSL -O "${BASE}/pve-zfs-tuner.sh" -O "${BASE}/pve-zfs-analyzer.sh" -O "${BASE}/SHA256SUMS"
sha256sum --check SHA256SUMS
chmod +x pve-zfs-tuner.sh pve-zfs-analyzer.sh
```

### ARC Tuner

```bash
sudo ./pve-zfs-tuner.sh
```

### ARC Analyzer

```bash
sudo ./pve-zfs-analyzer.sh
```

## 🛠️ Requirements

* Proxmox VE (or any Debian-based system running ZFS on Linux).
* Root privileges (`sudo` access).
* Active ZFS pools loaded into the kernel.
* Linux PSI support for the pressure metrics of the analyzer (without it, pressure is not taken into account).

## 🧪 Testing

The scripts are tested with [bats](https://github.com/bats-core/bats-core) against a fake ZFS host (arcstats, module parameters, `zfs.conf` and stubs for `zpool`, `findmnt` and `update-initramfs` in a temporary directory), so the tests never touch the real system:

```bash
bats tests/
```

CI runs the tests, [ShellCheck](https://www.shellcheck.net) and [Gitleaks](https://github.com/gitleaks/gitleaks) on every pull request. Tagged releases publish the scripts with `SHA256SUMS`.

## ⚠️ Disclaimer

Modifying kernel and filesystem parameters can impact performance depending on your specific workloads (e.g., heavy database tracking, high IOPS storage pools). Always verify your configuration adjustments in a staging environment if running highly critical production systems.

ARC sizing is workload-dependent. A low cache hit rate does not necessarily mean that increasing ARC will improve performance, while a high hit rate does not guarantee that the host has sufficient RAM.

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).
