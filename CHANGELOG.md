# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

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
