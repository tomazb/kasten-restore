# Kasten K10 VM Recovery Utility Scripts (MVP)

**Version:** 1.0.2
**Target Environment:** Kasten K10 v8.x on OpenShift 4.18 with OpenShift Virtualization

## Overview

Utility scripts for recovering OpenShift Virtualization VMs from Kasten K10 snapshots and exported backups. The MVP prioritizes VM-specific recovery workflows including DataVolume handling, disk restoration, and VM lifecycle management.

## Features

- **VM Discovery:** Find and list VM restore points with disk details
- **VM Restore:** Execute VM restore with CDI awareness and proper transforms
- **Transform Generation:** Automatically generate VM-specific transforms for DataVolumes and PVCs
- **Cross-Namespace Support:** Restore VMs to different namespaces with proper CDI handling
- **MAC Address Management:** Preserve or regenerate MAC addresses during restore
- **Dry-Run Mode:** Validate restore operations before execution

## Prerequisites

- OpenShift 4.18 with OpenShift Virtualization
- Kasten K10 v8.x installed
- VMs backed up by K10 policies
- `kubectl`, `bash`, and `jq` available in execution environment
- Appropriate RBAC permissions (see `manifests/rbac.yaml`)

## Quick Start

### 1. Find your VM's restore point

```bash
./scripts/k10-vm-discover.sh --vm my-rhel-vm --namespace vms-prod
```

### 2. Restore the VM

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-my-rhel-vm-<timestamp> \
  --namespace vms-prod
```

### 3. Verify

```bash
kubectl get vm my-rhel-vm -n vms-prod
```

## Scripts

- **k10-vm-common.sh** - Common utility functions and validation helpers
- **k10-vm-discover.sh** - Discover VM restore points with disk information
- **k10-vm-transform.sh** - Generate VM-specific transforms for DataVolumes and PVCs
- **k10-vm-restore.sh** - Execute VM restore operations with CDI awareness

## Examples

### Restore VM to Different Namespace

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --target-namespace vms-test \
  --vm-name rhel9-vm-test \
  --new-mac
```

### Restore Stopped VM (Don't Auto-Start)

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --namespace vms-prod \
  --no-start
```

### Dry Run with Validation

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --namespace vms-prod \
  --dry-run --validate
```

### Handle Conflicts and Reruns

Clone when the target VM already exists:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-myvm-20251117 \
  --namespace vms-prod \
  --clone-on-conflict \
  --yes
```

Force cleanup of prior K10 artifacts (TransformSet/RestoreAction) and re-run:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-myvm-20251117 \
  --namespace vms-prod \
  --force \
  --yes
```

Combine force + clone (when original VM exists):

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-myvm-20251117 \
  --namespace vms-prod \
  --clone-on-conflict \
  --force \
  --yes
```

## Restore Flags

- `--clone-on-conflict`: If a VM with the intended name already exists in the target namespace, restore to a unique clone name (`<vm>-clone`, `<vm>-clone-2`, …). Deterministic K10 resource names are derived from the final VM name and restore point.
- `--force`: Before starting, remove previous K10 artifacts for this VM/restore point (TransformSet in the K10 namespace and RestoreAction in the target namespace). Prompts for confirmation unless `--yes` is provided. Does not delete existing VMs, PVCs, or DVs.
- `--yes`: Auto-confirm prompts (use with `--force` for non-interactive reruns).

## Configuration

See `examples/vm-restore-profile.yaml` for VMRestoreProfile configuration options.

## RBAC

Apply the required RBAC permissions:

```bash
kubectl apply -f manifests/rbac.yaml
```

## Documentation

For detailed documentation, see:

- [docs/Kasten_K10_VM_Recovery_Utility_PRD_v1.1_1.md](docs/Kasten_K10_VM_Recovery_Utility_PRD_v1.1_1.md) - Full PRD with implementation details

## Recent Improvements

### Code Quality Enhancements (v1.0.1)

- **Enhanced MAC Address Handling**: Transform generation now correctly handles all network interfaces, not just the first one, preventing MAC conflicts when VMs have multiple NICs
- **Robust Annotation Parsing**: Switched from `kubectl jsonpath` to `jq` for annotation parsing to handle special characters reliably
- **Improved Error Detection**: Enhanced K10 namespace detection to warn when multiple candidates exist
- **Performance Optimization**: Discovery script now uses optimized jq filtering to reduce process spawning by ~90% on large clusters
- **Better Documentation**: Function side effects clearly documented; timeout values increased for slower storage environments
- **Security Documentation**: Added explicit warnings about broad RBAC permissions with recommendations for namespace-scoped alternatives

## License

Copyright 2025

## Support

For issues, questions, or contributions, please contact the platform engineering team.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for detailed release notes.
