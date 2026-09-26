# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-09-26

### Added

- Tuner options for non-interactive use: `--recommended`, `--min`/`--max`, `--reset`, `--persist`/`--no-persist`, `--yes`, `--dry-run`, `--wait`, `--help`, `--version`
- Reset to the ZFS defaults, also in the interactive menu
- Validation of custom limits against the values ZFS would silently ignore, and a check that the kernel accepted the new limits
- Warning when the recommended Max is below the Proxmox guideline because of the 10% RAM cap
- Analyzer `--interval` option
- Tests with bats against a fake ZFS host, CI with ShellCheck and Gitleaks, releases with `SHA256SUMS`

### Fixed

- Saving the configuration deleted all other `options zfs` settings from `/etc/modprobe.d/zfs.conf`
- Saved limits did not apply after a reboot on hosts with the root filesystem on ZFS: the initramfs is now updated
- The configuration backup was overwritten on every run; backups now have a timestamp
- Custom limits with a leading zero (e.g. `08`) failed with a bash octal error
- A zero kernel limit was shown as "Unlimited" instead of the ZFS default
- Analyzer showed an empty metadata cache on OpenZFS 2.2+ (Proxmox VE 8.1 and later), which removed `arc_meta_used`
- Analyzer measured PSI pressure over the last 10 seconds instead of the sampling interval
- Analyzer failed with errors when ZFS was not loaded or PSI was not available
- Colors are disabled when the output is not a terminal or `NO_COLOR` is set
- Scripts are executable in the repository
