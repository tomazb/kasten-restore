# Kasten K10 VM Recovery - Quick Start Guide

## Prerequisites

Before using the VM recovery utility scripts, ensure you have:

- **OpenShift 4.18** with OpenShift Virtualization installed
- **Kasten K10 v8.x** installed and configured
- VMs backed up by K10 policies
- `kubectl`, `bash`, and `jq` installed on your workstation
- Appropriate RBAC permissions configured

## Installation

### 1. Clone the Repository

```bash
git clone <repository-url>
cd kasten-restore
```

### 2. Apply RBAC Permissions

```bash
kubectl apply -f manifests/rbac.yaml
```

### 3. Verify Prerequisites

```bash
./scripts/k10-vm-common.sh
```

The common functions library will validate that all required tools are installed.

## 5-Minute VM Restore

### Step 1: Discover VM Restore Points

Find available restore points for your VM:

```bash
./scripts/k10-vm-discover.sh --vm my-rhel-vm --namespace vms-prod
```

**Example Output:**

```
VM RESTORE POINTS FOUND: 2

Name: rpc-rhel9-vm-backup-20251117
├─ VM: rhel9-vm
├─ Namespace: vms-prod
├─ State: Running
├─ Resources: CPU: 2, Memory: 4Gi
├─ Disks:
│  ├─ rootdisk (30Gi) - CSI Snapshot ✓
│  └─ datadisk (50Gi) - CSI Snapshot ✓
├─ MAC Preserved: Yes
├─ Freeze Annotation: None
└─ Restore Methods: [Snapshot, Export]
```

### Step 2: Validate the Restore (Optional but Recommended)

Perform a dry-run to validate the restore:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-my-rhel-vm-20251117 \
  --namespace vms-prod \
  --dry-run --validate
```

### Step 3: Execute the Restore

Restore the VM:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-my-rhel-vm-20251117 \
  --namespace vms-prod
```

The script will:
1. Generate required transforms
2. Create a RestoreAction
3. Monitor the restore progress
4. Verify the restore completion

### Step 4: Verify the Restore

Check the VM status:

```bash
kubectl get vm my-rhel-vm -n vms-prod
kubectl get vmi my-rhel-vm -n vms-prod
```

**Done!** Your VM is now restored.

## Common Use Cases

### 1. Restore VM to Different Namespace (Clone)

Clone a production VM to a test environment:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-webserver-20251117 \
  --target-namespace vms-test \
  --vm-name rhel9-webserver-test \
  --new-mac \
  --create-namespace \
  --no-start
```

**What this does:**
- Creates the `vms-test` namespace if it doesn't exist
- Restores the VM as `rhel9-webserver-test`
- Generates new MAC addresses to avoid conflicts
- Keeps the VM stopped so you can configure it before starting

### 2. Restore Deleted VM

Find and restore a deleted VM:

```bash
# Find deleted VMs
./scripts/k10-vm-discover.sh --deleted-only

# Restore the deleted VM
./scripts/k10-vm-restore.sh \
  --restore-point rpc-windows-vm-legacy-20251115 \
  --target-namespace vms-archive \
  --create-namespace \
  --no-start
```

### 3. Restore with Different Storage Class

Restore a VM to a different storage class:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --namespace vms-prod \
  --new-storage-class ocs-storagecluster-ceph-rbd-ssd
```

### 4. Discover All VMs Across All Namespaces

List all VM restore points:

```bash
./scripts/k10-vm-discover.sh --all --show-disks
```

Get JSON output for scripting:

```bash
./scripts/k10-vm-discover.sh --all --output json
```

### 5. Generate Custom Transforms

Generate transforms for review before restore:

```bash
./scripts/k10-vm-transform.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --new-storage-class ocs-storagecluster-ceph-rbd \
  --new-namespace vms-test \
  --new-mac \
  --output my-transforms.yaml
```

Review the generated transforms:

```bash
cat my-transforms.yaml
```

Apply the transforms:

```bash
kubectl apply -f my-transforms.yaml
```

Use the transforms in restore:

```bash
./scripts/k10-vm-restore.sh \
  --restore-point rpc-rhel9-vm-backup-xyz \
  --namespace vms-prod \
  --transform-file my-transforms.yaml
```

## Script Reference

### k10-vm-discover.sh

Discover VM restore points with disk details.

**Common Options:**
- `--vm <name>` - VM name to search for
- `--namespace <ns>` - Namespace to search in
- `--all` - Show all VMs across all namespaces
- `--deleted-only` - Show only deleted VMs with restore points
- `--output json` - Output in JSON format

### k10-vm-transform.sh

Generate VM-specific transforms for restore operations.

**Common Options:**
- `--restore-point <rpc>` - Restore point content name (required)
- `--output <file>` - Output file for transforms
- `--new-storage-class <sc>` - Target storage class
- `--new-namespace <ns>` - Target namespace
- `--new-mac` - Generate new MAC addresses

### k10-vm-restore.sh

Execute VM restore operations.

**Common Options:**
- `--restore-point <rpc>` - Restore point content name (required)
- `--namespace <ns>` - Source namespace
- `--target-namespace <ns>` - Target namespace for restore
- `--vm-name <name>` - Override VM name
- `--new-mac` - Generate new MAC addresses
- `--no-start` - Don't auto-start VM after restore
- `--dry-run` - Show what would be done without executing
- `--validate` - Validate restore feasibility
- `--create-namespace` - Create target namespace if it doesn't exist
- `--yes` - Auto-confirm without prompting

## Troubleshooting

### Common Issues

#### 1. "Restore point not found"

**Problem:** The specified restore point doesn't exist.

**Solution:**
```bash
# List all restore points
./scripts/k10-vm-discover.sh --all

# Verify the exact name
kubectl get restorepointcontents -A | grep <vm-name>
```

#### 2. "DataVolume stuck in WaitForFirstConsumer"

**Problem:** Storage class not available or misconfigured.

**Solution:**
```bash
# Check storage classes
kubectl get storageclass

# Check VolumeSnapshotClass
kubectl get volumesnapshotclass

# Ensure VolumeSnapshotClass has K10 annotation
kubectl annotate volumesnapshotclass <name> \
  k10.kasten.io/is-snapshot-class=true
```

#### 3. "VM doesn't start after restore"

**Problem:** Insufficient resources or configuration issues.

**Solution:**
```bash
# Check namespace quotas
kubectl get resourcequota -n <namespace>

# Check VM events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep <vm-name>

# Check VM status
kubectl describe vm <vm-name> -n <namespace>
```

#### 4. "MAC address conflict"

**Problem:** Restored VM has the same MAC address as an existing VM.

**Solution:**
```bash
# Delete the restored VM
kubectl delete vm <vm-name> -n <namespace>

# Restore again with --new-mac flag
./scripts/k10-vm-restore.sh \
  --restore-point <rpc> \
  --namespace <ns> \
  --new-mac
```

### Getting Help

For detailed logs and debugging:

```bash
# View RestoreAction status
kubectl get restoreactions -n <namespace>

# Describe RestoreAction
kubectl describe restoreaction <name> -n <namespace>

# View K10 logs
kubectl logs -n kasten-io -l app=k10 --tail=100
```

## Best Practices

1. **Always validate before restoring:**
   ```bash
   --dry-run --validate
   ```

2. **Use new MAC addresses for clones:**
   ```bash
   --new-mac
   ```

3. **Keep VMs stopped initially when cloning:**
   ```bash
   --no-start
   ```

4. **Review generated transforms before applying:**
   ```bash
   ./scripts/k10-vm-transform.sh ... --output transforms.yaml
   cat transforms.yaml
   ```

5. **Monitor restore progress:**
   ```bash
   kubectl get restoreactions -n <namespace> -w
   ```

## Next Steps

- Review the [full PRD](Kasten_K10_VM_Recovery_Utility_PRD_v1.1_1.md) for detailed documentation
- Customize [VMRestoreProfile](../examples/vm-restore-profile.yaml) for your environment
- Set up automation using CI/CD pipelines
- Integrate with your disaster recovery procedures

## Support

For issues, questions, or contributions, please contact the platform engineering team.
