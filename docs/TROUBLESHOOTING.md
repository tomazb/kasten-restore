# Troubleshooting Guide - K10 VM Restore Utility

## Common Error Scenarios

### 1. DataVolume Issues

#### DataVolume Stuck in "WaitForFirstConsumer"

**Symptom:**
```
DataVolume: my-vm-rootdisk - Status: WaitForFirstConsumer
```

**Cause:** Storage class uses WaitForFirstConsumer binding mode, or no storage available.

**Resolution:**
```bash
# Check storage class binding mode
kubectl get storageclass <storage-class-name> -o yaml | grep volumeBindingMode

# Check available PVs
kubectl get pv

# If using local storage, ensure nodes have available capacity
kubectl get nodes -o wide

# Check for pending PVCs
kubectl get pvc -n <namespace>
```

#### DataVolume Import Failed

**Symptom:**
```
DataVolume: my-vm-rootdisk - Status: ImportFailed
```

**Cause:** CDI import/clone operations were not disabled properly.

**Resolution:**
```bash
# Check DataVolume annotations
kubectl get dv <datavolume-name> -n <namespace> -o yaml

# Verify transforms were applied correctly
kubectl get transformset -n kasten-io

# Manually add required annotation if missing
kubectl annotate dv <datavolume-name> -n <namespace> \
  cdi.kubevirt.io/storage.populatedFor=<pvc-name>

# Remove source spec if present
kubectl patch dv <datavolume-name> -n <namespace> \
  --type=json -p='[{"op":"remove","path":"/spec/source"}]'
```

### 2. PVC Issues

#### PVC Remains "Pending"

**Symptom:**
```
PVC: my-vm-rootdisk - Status: Pending
```

**Cause:** No VolumeSnapshotClass configured or snapshot not found.

**Resolution:**
```bash
# Check VolumeSnapshotClass
kubectl get volumesnapshotclass

# Ensure K10 annotation exists
kubectl get volumesnapshotclass -o yaml | grep "k10.kasten.io/is-snapshot-class"

# If missing, add annotation
kubectl annotate volumesnapshotclass <class-name> \
  k10.kasten.io/is-snapshot-class=true

# Check if VolumeSnapshot exists
kubectl get volumesnapshot -n <namespace>

# Describe PVC for more details
kubectl describe pvc <pvc-name> -n <namespace>
```

#### PVC Bound to Wrong PV

**Symptom:** PVC is bound but to unexpected PV.

**Cause:** Storage class selector or PV labels mismatch.

**Resolution:**
```bash
# Check PVC details
kubectl get pvc <pvc-name> -n <namespace> -o yaml

# Check bound PV
kubectl describe pv <pv-name>

# If incorrect, delete and recreate
kubectl delete pvc <pvc-name> -n <namespace>
# Re-run restore
```

### 3. VirtualMachine Issues

#### VM Doesn't Start After Restore

**Symptom:** VM exists but doesn't start.

**Cause:** Multiple possible causes - check events and VMI status.

**Resolution:**
```bash
# Check VM spec
kubectl get vm <vm-name> -n <namespace> -o yaml | grep running

# Check for VMI
kubectl get vmi <vm-name> -n <namespace>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep <vm-name>

# Check for resource constraints
kubectl describe vm <vm-name> -n <namespace> | grep -A 10 Conditions

# Manually start VM if needed
kubectl patch vm <vm-name> -n <namespace> \
  --type=json -p='[{"op":"replace","path":"/spec/running","value":true}]'
```

#### VM Starts But Network Not Working

**Symptom:** VM boots but has no network connectivity.

**Cause:** Network configuration or MAC address conflict.

**Resolution:**
```bash
# Check VM network interfaces
kubectl get vm <vm-name> -n <namespace> -o yaml | grep -A 10 interfaces

# Check for MAC conflicts
kubectl get vmi -A -o yaml | grep macAddress | sort

# If MAC conflict, delete and restore with --new-mac
kubectl delete vm <vm-name> -n <namespace>
./scripts/k10-vm-restore.sh \
  --restore-point <rpc> \
  --namespace <namespace> \
  --new-mac

# Check NetworkAttachmentDefinition if using multus
kubectl get network-attachment-definitions -n <namespace>
```

#### VM Resource Not Found in Restore Point

**Symptom:** Script reports "No VirtualMachine resource found in restore point"

**Cause:** Restore point doesn't contain VM resources or not a VM backup.

**Resolution:**
```bash
# Verify restore point contents
kubectl get restorepointcontent <rpc-name> -o yaml

# Check for VM artifacts
kubectl get restorepointcontent <rpc-name> -o json | \
  jq '.status.restorePointContentDetails.artifacts[] | select(.resource.group == "kubevirt.io")'

# List all restore points for the VM
./scripts/k10-vm-discover.sh --vm <vm-name> --namespace <namespace>
```

### 4. Transform Issues

#### Transform Validation Failed

**Symptom:**
```
ERROR: Transform validation failed
```

**Cause:** Invalid JSON patch syntax or incorrect resource paths.

**Resolution:**
```bash
# Generate transforms to a file for inspection
./scripts/k10-vm-transform.sh \
  --restore-point <rpc> \
  --output transforms.yaml

# Review the transforms
cat transforms.yaml

# Validate YAML syntax
kubectl apply -f transforms.yaml --dry-run=client

# Check for invalid paths
# Common mistakes:
# - Missing ~1 for slashes in annotation keys
# - Incorrect array indices
# - Missing required fields
```

#### Transform Not Applied

**Symptom:** Restore proceeds but transforms don't take effect.

**Cause:** Transform name mismatch or namespace incorrect.

**Resolution:**
```bash
# Check if transform was created
kubectl get transformset -n kasten-io

# Verify transform name matches RestoreAction
kubectl get restoreaction <restore-action-name> -n <namespace> -o yaml | \
  grep -A 5 transforms

# Check transform namespace (should be kasten-io)
kubectl get transformset <name> -n kasten-io -o yaml
```

### 5. RestoreAction Issues

#### RestoreAction Stuck in "Pending"

**Symptom:**
```
RestoreAction: restore-my-vm-xyz - State: Pending
```

**Cause:** K10 not processing the action or validation failures.

**Resolution:**
```bash
# Check RestoreAction status
kubectl describe restoreaction <name> -n <namespace>

# Check K10 controller logs
kubectl logs -n kasten-io -l component=kanister --tail=100

# Verify restore point still exists
kubectl get restorepointcontent <rpc-name>

# Check K10 service health
kubectl get pods -n kasten-io
```

#### RestoreAction Failed

**Symptom:**
```
RestoreAction: restore-my-vm-xyz - State: Failed
```

**Cause:** Various - check detailed status and logs.

**Resolution:**
```bash
# Get detailed failure reason
kubectl get restoreaction <name> -n <namespace> -o yaml | grep -A 20 status

# Check action events
kubectl get events -n <namespace> | grep RestoreAction

# Review K10 logs
kubectl logs -n kasten-io -l app=k10 --tail=200 | grep -i error

# If retriable, delete and recreate
kubectl delete restoreaction <name> -n <namespace>
# Re-run restore script
```

### 6. Script Errors

#### "kubectl: command not found"

**Cause:** kubectl not installed or not in PATH.

**Resolution:**
```bash
# Install kubectl
# For Linux:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# For macOS:
brew install kubectl

# Verify installation
kubectl version --client
```

#### "jq: command not found"

**Cause:** jq not installed.

**Resolution:**
```bash
# For Linux:
sudo yum install jq
# or
sudo apt-get install jq

# For macOS:
brew install jq

# Verify installation
jq --version
```

#### "Permission denied" When Running Scripts

**Cause:** Scripts not executable.

**Resolution:**
```bash
chmod +x scripts/*.sh

# Verify permissions
ls -la scripts/
```

#### "Kasten K10 not found"

**Cause:** K10 not installed or installed in different namespace.

**Resolution:**
```bash
# Find K10 namespace
kubectl get namespaces | grep -i kasten

# Check K10 installation
kubectl get pods -n <k10-namespace>

# Update K10_NAMESPACE variable if needed
export K10_NAMESPACE=<your-k10-namespace>
```

### 7. RBAC Permission Errors

#### "forbidden: User cannot create resource"

**Cause:** Insufficient RBAC permissions.

**Resolution:**
```bash
# Apply RBAC manifests
kubectl apply -f manifests/rbac.yaml

# Verify ServiceAccount exists
kubectl get serviceaccount k10-vm-restore-sa -n kasten-io

# Verify ClusterRoleBinding
kubectl get clusterrolebinding k10-vm-restore-utils-binding

# Check your current permissions
kubectl auth can-i create virtualmachines -n <namespace>
kubectl auth can-i create restoreactions -n <namespace>

# If using ServiceAccount, ensure proper context
kubectl --as=system:serviceaccount:kasten-io:k10-vm-restore-sa \
  auth can-i create virtualmachines -n <namespace>
```

### 8. Namespace Issues

#### "namespace does not exist"

**Cause:** Target namespace not created.

**Resolution:**
```bash
# Use --create-namespace flag
./scripts/k10-vm-restore.sh \
  --restore-point <rpc> \
  --target-namespace <new-ns> \
  --create-namespace

# Or create manually
kubectl create namespace <namespace>
kubectl label namespace <namespace> \
  environment=test \
  managed-by=k10-vm-restore-utils
```

#### "quota exceeded in namespace"

**Cause:** Namespace resource quota exceeded.

**Resolution:**
```bash
# Check current quota
kubectl get resourcequota -n <namespace>

# Describe quota details
kubectl describe resourcequota -n <namespace>

# Request quota increase or clean up resources
kubectl delete vm <old-vm> -n <namespace>

# Or restore to different namespace with sufficient quota
./scripts/k10-vm-restore.sh \
  --restore-point <rpc> \
  --target-namespace <different-ns>
```

### 9. Storage Issues

#### "StorageClass not found"

**Cause:** Specified storage class doesn't exist.

**Resolution:**
```bash
# List available storage classes
kubectl get storageclass

# Use correct storage class name
./scripts/k10-vm-restore.sh \
  --restore-point <rpc> \
  --namespace <ns> \
  --new-storage-class <correct-name>

# Or omit --new-storage-class to use original
```

#### "Insufficient storage capacity"

**Cause:** Not enough storage available.

**Resolution:**
```bash
# Check PV availability
kubectl get pv

# Check storage provisioner status
kubectl get pods -n <storage-namespace>

# Free up space or add more storage capacity
# Contact storage administrator if needed
```

### 10. CDI Issues

#### "CDI not installed"

**Cause:** Containerized Data Importer not installed.

**Resolution:**
```bash
# Check for CDI CRDs
kubectl get crd | grep cdi

# Install CDI (typically part of OpenShift Virtualization)
# Follow OpenShift Virtualization installation guide

# Verify CDI installation
kubectl get pods -n cdi
```

#### "CDI import-controller not running"

**Cause:** CDI controller pods not healthy.

**Resolution:**
```bash
# Check CDI pods
kubectl get pods -n cdi

# Restart CDI controller if needed
kubectl delete pod -n cdi -l app=containerized-data-importer

# Check logs
kubectl logs -n cdi -l app=containerized-data-importer
```

## Diagnostic Commands

### Comprehensive Health Check

```bash
# Run all checks
cat <<'EOF' | bash
echo "=== K10 Installation ==="
kubectl get pods -n kasten-io

echo -e "\n=== KubeVirt Installation ==="
kubectl get pods -n kubevirt

echo -e "\n=== CDI Installation ==="
kubectl get pods -n cdi

echo -e "\n=== Storage Classes ==="
kubectl get storageclass

echo -e "\n=== VolumeSnapshotClasses ==="
kubectl get volumesnapshotclass

echo -e "\n=== Recent VM Events ==="
kubectl get events -A --sort-by='.lastTimestamp' | grep -i virtual | tail -20

echo -e "\n=== RestoreActions Status ==="
kubectl get restoreactions -A

echo -e "\n=== TransformSets ==="
kubectl get transformsets -n kasten-io
EOF
```

### VM-Specific Diagnostics

```bash
VM_NAME="<your-vm-name>"
NAMESPACE="<namespace>"

echo "=== VM Status ==="
kubectl get vm $VM_NAME -n $NAMESPACE

echo -e "\n=== VMI Status ==="
kubectl get vmi $VM_NAME -n $NAMESPACE

echo -e "\n=== DataVolumes ==="
kubectl get dv -n $NAMESPACE

echo -e "\n=== PVCs ==="
kubectl get pvc -n $NAMESPACE

echo -e "\n=== VM Events ==="
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep $VM_NAME

echo -e "\n=== VM Details ==="
kubectl describe vm $VM_NAME -n $NAMESPACE
```

## Getting Additional Help

If issues persist after following this guide:

1. **Collect diagnostic information:**
   ```bash
   ./scripts/k10-vm-discover.sh --all --output json > diagnostics.json
   kubectl get restoreactions -A -o yaml > restore-actions.yaml
   kubectl get events -A --sort-by='.lastTimestamp' > events.log
   ```

2. **Check K10 documentation:**
   - https://docs.kasten.io/latest/usage/openshift_virtualization.html

3. **Contact support:**
   - Include diagnostic files
   - Provide exact error messages
   - Describe steps to reproduce

## Prevention and Best Practices

To avoid common issues:

1. **Always run dry-run first:**
   ```bash
   --dry-run --validate
   ```

2. **Verify prerequisites before restore:**
   ```bash
   ./scripts/k10-vm-common.sh  # Check tools
   kubectl get crd virtualmachines.kubevirt.io  # Check KubeVirt
   kubectl get volumesnapshotclass  # Check snapshots
   ```

3. **Monitor K10 health regularly:**
   ```bash
   kubectl get pods -n kasten-io -w
   ```

4. **Keep backups of transforms:**
   ```bash
   ./scripts/k10-vm-transform.sh ... --output transforms-$(date +%Y%m%d).yaml
   ```

5. **Test restores in non-production first:**
   ```bash
   --target-namespace test-restore --no-start
   ```
