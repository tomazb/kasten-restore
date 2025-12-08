# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [1.1.0] - 2025-12-08

### Added

- **Centralized version number**: All scripts now share a single version (`K10_VM_UTILS_VERSION`) defined in `k10-vm-common.sh`.
- **Configurable defaults**: All timeouts and retry settings configurable via environment variables (`TIMEOUT_RESTORE`, `TIMEOUT_READY`, `KUBECTL_RETRY_ATTEMPTS`, `KUBECTL_RETRY_SLEEP`).
- **Logging levels**: Added `DEBUG`, `VERBOSE`, and `QUIET` modes controllable via environment variables or command-line flags.
- **New CLI flags**: All scripts now support `--verbose`, `--quiet`, and `--version` flags for consistency.
- **Progress spinner**: Added `show_spinner()` function for long-running operations.
- **Safe JSON parsing**: Added `safe_jq()` function with error handling and default value support.

### Security

- **Secure temp files**: Transform files now created with `create_secure_temp()` using `mktemp` with `chmod 600` permissions instead of world-readable `/tmp` files.
- **Masked kubectl logging**: The `kubectl_retry()` function no longer logs full command arguments to avoid exposing sensitive data in logs.

### Improved

- **Performance**: `resolve_clone_name()` now fetches all VM names in a single kubectl call instead of up to 999 individual calls.
- **Code consolidation**: Moved `get_datavolumes_from_rpc()` to `k10-vm-common.sh` to eliminate code duplication between restore and transform scripts.
- **Expanded smoke tests**: `dev-smoke.sh` now includes comprehensive tests for syntax validation, ShellCheck (if available), jq filters, awk parsing, name sanitization, and secure temp file creation.

## [1.0.2] - 2025-11-19

### Added

- `k10-vm-restore.sh`: `--clone-on-conflict` flag to automatically restore to a unique clone name when the target VM already exists (e.g., `<vm>-clone`, `<vm>-clone-2`, …). Deterministic K10 resource names remain based on the final VM name and restore point.
- `k10-vm-restore.sh`: `--force` flag to delete previous K10 artifacts (TransformSet/RestoreAction) for the selected VM/restore point before re-running. Respects `--yes` to skip confirmation prompts. Does not delete existing VMs/PVCs/DVs.

### Documentation

- README: Added examples and a dedicated "Restore Flags" section for `--clone-on-conflict`, `--force`, and `--yes`.
- QUICKSTART: Added "Step 3b: Handle Conflicts or Reruns" with practical examples for `--clone-on-conflict` and `--force`; updated Script Reference with new flags; fixed markdown linting.
- PRD: Fixed markdown lint issues (headings, lists, fenced code languages) and clarified section formatting.

## [1.0.1] - 2025-11-18

### Improved

- Transform generation now removes MAC addresses for all VM interfaces to avoid conflicts when VMs have multiple NICs.
- Switched to `jq` for robust annotation parsing in common helpers.
- Optimized discovery script to reduce process spawning and improve performance on large clusters.
- Clarified timeout values and function side effects in docs; added security guidance around RBAC breadth.

## [1.0.0] - 2025-11-17

### Initial

- MVP release of K10 VM recovery utility scripts: discovery, transform generation, and restore (with CDI-aware transforms).
