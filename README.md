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

- **Auto-Discovery** — detects host RAM, active ZFS pools, storage capacity, the memory of running VMs and containers, and the current limits.
- **Smart Recommendations** — calculates an ARC target from storage capacity, host RAM and the memory left after the guests.
- **Interactive or Automated** — use the menu, or options for scripts and configuration management (`--recommended --yes`).
- **Idempotent** — changes only what differs; when the limits are already in place, nothing is written and the initramfs is not rebuilt.
- **Safe Limits** — rejects values ZFS would silently ignore and verifies that the kernel accepted the new limits.
- **Dry Run** — shows the recommendation and the planned changes without touching the system.
- **Persistent Configuration** — updates `/etc/modprobe.d/zfs.conf`, keeps your other ZFS options, makes a timestamped backup and updates the initramfs when the root filesystem is on ZFS.
- **Reset and Restore** — return to the ZFS defaults, or restore the configuration from the latest backup.
- **Audit Trail** — changes are recorded in the system journal (`journalctl -t pve-zfs-tuner`).

### Sizing Logic

The Smart Recommendation is calculated from the total raw capacity of all active ZFS pools:

- **Baseline formula:** 2 GiB + 1 GiB per 1 TiB of raw ZFS storage, rounded up to the next TiB (the Proxmox guideline).
- **Recommended Min:** 50% of the baseline formula.
- **Recommended Max:** 2× the baseline formula (4× the recommended Min).
- **RAM Safety Cap:** If the calculated Max exceeds 10% of total host RAM, Max is capped at 10% of host RAM and Min is set to 25% of the capped Max.
- **Guest Memory:** On Proxmox VE, the memory configured for the running VMs and containers of the node (from `pvesh`) and a reserve for the host (5% of RAM, at least 2 GiB) are subtracted from the RAM. If Max exceeds what is left, Max is limited to it and Min is set to the lowest value (32 MiB), so the ARC can shrink when the guests need memory. Use `--ignore-guests` to skip this.

The 10% host RAM value is therefore a **safety cap for the recommended ARC maximum**, not the primary sizing formula. When the cap brings Max below the Proxmox guideline, the tuner points it out, and when the guests leave more memory, it suggests limits that fit in it.

Example (`--dry-run` on a host with 64 GiB RAM, 8 TiB of pools and 48 GiB for running guests, where the kernel already has the recommended limits):

```
Current System State:
  Host Total RAM:         64.00 GiB
  Running VMs/CTs Memory: 48.00 GiB (headroom for ARC: 12.80 GiB)
  Total Raw ZFS Storage:  8.00 TiB
  Current ARC Footprint:  6.40 GiB (actual RAM used)
  Active Kernel Limits:   Min: ZFS default (1.60 GiB) / Max: 6.40 GiB
  Persistent Config:      Min: Not set / Max: 6.40 GiB

Calculated Target Options:
  - 10% of Host RAM (Max Limit): 6.40 GiB
  - Raw Formula (Max Limit):     20.00 GiB
  * Smart Recommendation:        Min: 1.60 GiB / Max: 6.40 GiB
                                 [Reason: Capped to 10% of host RAM (formula exceeded the safe threshold)]
[WARNING] The recommended Max is below the Proxmox guideline of 10.00 GiB (2 GiB + 1 GiB per TiB of storage).
  The running VMs and containers leave 12.80 GiB, so larger limits fit:
  --min 3072M --max 12G

Target Limits:
  zfs_arc_min: 1.60 GiB (1717986918 bytes)
  zfs_arc_max: 6.40 GiB (6871947673 bytes)

[DRY RUN] Nothing was changed. The tuner would:
  - save /etc/modprobe.d/zfs.conf (after a backup) with the ZFS options:
      options zfs zfs_arc_min=1717986918 zfs_arc_max=6871947673
  - run update-initramfs -u -k all (root filesystem is on ZFS)
```

### Options

| Option | Description |
|--------|-------------|
| `--recommended` | Apply the smart recommendation |
| `--min SIZE --max SIZE` | Apply custom limits, e.g. `4G`, `512M`; a plain number means GiB |
| `--reset` | Remove the limits; the ZFS defaults apply after a reboot |
| `--restore` | Restore `/etc/modprobe.d/zfs.conf` from the most recent backup |
| `--persist` / `--no-persist` | Save to `/etc/modprobe.d/zfs.conf` without asking / apply to the running kernel only |
| `-y`, `--yes` | Answer yes to all questions |
| `--dry-run` | Show what would be done without changing anything (does not require root) |
| `--ignore-guests` | Do not take the memory of running VMs and containers into account |
| `--wait SECONDS` | Seconds to monitor cache eviction after applying (default: 10, `0` to skip) |
| `--detailed-exitcode` | Exit with `0` when nothing changed (or would change), `2` when something changed (or would change), `1` on errors |
| `-h`, `--help` / `--version` | Show help / version |

Without a target option, the tuner shows an interactive menu.

```bash
# Only see the recommendation
./pve-zfs-tuner.sh --dry-run

# Apply and save the recommendation without questions
sudo ./pve-zfs-tuner.sh --recommended --yes

# Custom limits for the running kernel only
sudo ./pve-zfs-tuner.sh --min 2G --max 8G --no-persist --yes

# Undo the last saved change
sudo ./pve-zfs-tuner.sh --restore --yes
```

### Automation

With `--yes`, the tuner runs without questions and only changes what differs, so it can run on every configuration management pass. `--detailed-exitcode` tells whether something changed, for example in Ansible:

```yaml
- name: Tune the ZFS ARC
  ansible.builtin.command: /usr/local/sbin/pve-zfs-tuner.sh --recommended --yes --wait 0 --detailed-exitcode
  register: zfs_arc
  changed_when: zfs_arc.rc == 2
  failed_when: zfs_arc.rc not in [0, 2]
```

### Limits

ZFS accepts any value written to its parameters but silently ignores invalid ones, so the tuner rejects them upfront:

- Min must be at least 32 MiB, Max at least 64 MiB
- Max must be greater than Min
- Max must be less than the host RAM (a warning is shown above 50%)

After applying, the tuner compares the active limits reported by ZFS with the requested ones.

A loaded ZFS module does not recalculate its defaults, so `--reset` sets the parameters to `0` and removes them from the configuration, but the running kernel keeps the current limits until a reboot.

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
- Ghost hits: the share of misses for recently evicted data, which a larger ARC would have served
- Cache eviction rate
- L2ARC size and hit rate, when present
- Memory PSI pressure
- I/O PSI pressure

Hit rates and PSI pressure are measured over the same interval.

The analyzer provides recommendations based on the observed combination of ARC efficiency and system resource pressure, helping identify potential:

- RAM shortages
- Storage I/O bottlenecks, and whether a larger ARC or faster storage would help
- Low metadata cache efficiency
- An ARC that is too small for the working set, with a suggested new maximum and the tuner command to apply it
- High cache churn that a larger ARC would not fix

Ghost hits are the key signal: ZFS keeps track of recently evicted data, and when a miss is for such data, a larger ARC would have served it from memory. With a high share of ghost hits, the analyzer suggests growing the maximum by that share (by no more than half of the available memory). With few ghost hits, a larger ARC is unlikely to help, however low the hit rate is.

Example:

```
=== CURRENT CACHE STATUS ===
Current ARC Size:      6.4 GB
ARC Limit Settings:    Min: 1.6 GB  /  Max: 6.4 GB
Metadata Cache:        1.2 GB (no fixed limit on OpenZFS 2.2+)

=== OS RESOURCE PRESSURE (PSI, last 30 sec) ===
RAM Stall Pressure:    Processes waiting: 0.80% | System paralyzed: 0.00%
I/O Stall Pressure:    Processes waiting: 21.00%

=== CACHE EFFICIENCY FOR THE LAST 30 SEC ===
Total Efficiency:         92.11% (Total Requests: 200000, Misses: 15790)
  └─ Core DATA:           90.87% (Requests: 132500, Misses: 12100)
  └─ METADATA:            97.25% (Requests: 59950, Misses: 1650)
  └─ Prefetch (Read-ahead):72.98% (Requests: 7550, Misses: 2040)
Ghost Hits:               34.52% of misses (recently evicted data requested again)
Evicted Blocks (Cache):   21340

=== ANALYSIS & RECOMMENDATION ===
[WARNING] ARC is too small for the working set: 34.52% of the misses were recently evicted data.
-> Recommendation: Expand ZFS ARC: Max 6.4 GB -> 9.0 GB, e.g. pve-zfs-tuner.sh --min 1638M --max 9G
```

With `--json`, the analyzer prints the results as JSON for monitoring systems:

```bash
sudo ./pve-zfs-analyzer.sh --interval 60 --json | jq '{verdict, hit_rate: .hit_rate.total, suggested_max_bytes}'
```

The `verdict` is one of `idle`, `critical_ram`, `storage_bottleneck`, `storage_bottleneck_expand`, `stable`, `metadata`, `arc_too_small`, `churn` and `excellent`.

The analyzer does **not** modify any system configuration.

## 📦 Quick Usage

Download a released version and verify its checksum:

```bash
VERSION=v1.1.0
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
* On Proxmox VE, `pvesh` for the guest memory (other systems are sized without it).

## 🧪 Testing

- **Unit tests** with [bats](https://github.com/bats-core/bats-core) run against a fake ZFS host (arcstats, module parameters, `zfs.conf` and stubs for `zpool`, `findmnt`, `pvesh`, `update-initramfs` and `logger` in a temporary directory), so they never touch the real system:

  ```bash
  bats tests/
  ```

- **Integration tests** (`tests/integration.sh`) run in CI against the real ZFS kernel module on a file-backed pool: they check that the kernel accepts the limits in the order the tuner writes them, that it ignores the values the tuner rejects, idempotency, reset, restore and the analyzer on live statistics.

CI runs both, [ShellCheck](https://www.shellcheck.net), [shfmt](https://github.com/mvdan/sh) (settings in `.editorconfig`) and [Gitleaks](https://github.com/gitleaks/gitleaks) on every pull request. Tagged releases publish the scripts with `SHA256SUMS`.

## ⚠️ Disclaimer

Modifying kernel and filesystem parameters can impact performance depending on your specific workloads (e.g., heavy database tracking, high IOPS storage pools). Always verify your configuration adjustments in a staging environment if running highly critical production systems.

ARC sizing is workload-dependent. A low cache hit rate does not necessarily mean that increasing ARC will improve performance, while a high hit rate does not guarantee that the host has sufficient RAM.

## 📄 License

This project is open-source and available under the [MIT License](LICENSE).
