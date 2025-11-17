# **Product Requirements Document (PRD)**
## **Kasten K10 VM Recovery Utility Scripts (MVP)**

**Version:** 1.1  
**Date:** November 17, 2025  
**Target Environment:** Kasten K10 v8.x on OpenShift 4.18 with OpenShift Virtualization  
**MVP Focus:** Virtual Machine Recovery  
**Confidence Level:** 82%

---

## **1. Executive Summary - MVP Scope**

Build utility scripts specifically for recovering OpenShift Virtualization VMs from Kasten K10 snapshots and exported backups. The MVP prioritizes VM-specific recovery workflows including DataVolume handling, disk restoration, and VM lifecycle management.

---

## **2. Problem Statement - VM Recovery Context**

**Current Pain Points for VM Recovery:**
- Manual VM restore requires understanding DataVolume, PVC, and VM resource relationships
- Restoring backed up Virtual Machines requires K10 transforms to be applied to instruct the OpenShift Virtualization operator to not handle data import/population activities
- Complex dependency between VirtualMachine, DataVolume, and PVC resources
- No streamlined way to restore VMs with disk cloning or to different namespaces
- VM freeze/thaw annotations need proper handling during restore
- Difficulty managing VM-specific transforms for CDI (Containerized Data Importer)

**Target Users:**
- Platform teams managing OpenShift Virtualization
- VM administrators requiring self-service recovery
- Disaster recovery operators handling VM workloads

---

## **3. Goals & Non-Goals - MVP**

### **Goals**
1. Automate discovery of VM restore points with disk information
2. Handle VM-specific transforms automatically (DataVolume, PVC transforms)
3. Support VM restore to same/different namespace with proper CDI handling
4. Preserve VM configuration (MAC addresses, resource allocations)
5. Handle both running and stopped VM states during restore
6. Prefer CSI snapshots for VM disks when available

### **Non-Goals (Deferred to Phase 2)**
- Live migration during restore
- Multi-VM batch restore orchestration
- VM template management
- Snapshot scheduling or policy creation
- Performance metrics collection
- Container workload restoration (focus is VMs only)

---

## **4. OpenShift Virtualization Architecture Context**

### **4.1 VM Resource Hierarchy**

```
VirtualMachine (VM)
├── VirtualMachineInstance (VMI) [Runtime]
├── DataVolume(s) [Disk definitions]
│   └── PersistentVolumeClaim(s) [Storage backing]
└── ConfigMaps/Secrets [Cloud-init, SSH keys]
```

**Key K10 Discovery Points:**
- K10 automatically discovers Virtual Machines and treats them as workloads when OpenShift Virtualization is enabled
- K10 8.0+ added support for restoring individual volumes of existing virtual machines in OpenShift Virtualization 4.18

### **4.2 VM Backup Artifacts**

K10 captures:
1. **VM Manifest:** VirtualMachine resource definition
2. **DataVolume Definitions:** Disk specifications
3. **PVC Snapshots:** Actual disk data (via CSI snapshots)
4. **Related Resources:** ConfigMaps for cloud-init, Secrets for credentials

---

## **5. Functional Requirements - VM Focus**

### **5.1 VM Discovery Script (`k10-vm-discover.sh`)**

**Primary Function:** Find and list VM restore points with disk details

```bash
# Usage examples
./k10-vm-discover.sh --vm rhel9-vm --namespace vms-prod
./k10-vm-discover.sh --label "os=rhel,tier=frontend"
./k10-vm-discover.sh --all --show-disks
./k10-vm-discover.sh --vm-only  # Filter out non-VM workloads
```

**VM-Specific Output Fields:**
- VM name and namespace
- Running state at backup time (Running/Stopped)
- Disk count and sizes
- DataVolume names
- Snapshot type per disk (CSI snapshot vs export)
- MAC address preservation status
- Memory/CPU allocation
- Freeze annotation status (if VM was frozen during backup)

**Implementation Details:**

```bash
# Discover VMs specifically
kubectl get applications.apps.kio.kasten.io -A \
  -o json | jq '[.items[] | 
    select(.metadata.name | test("vm-|virtualmachine-")) |
    {
      name: .metadata.name,
      namespace: .metadata.namespace,
      type: "VirtualMachine"
    }]'

# Get VM-specific restore point details
kubectl get restorepointcontents \
  -l k10.kasten.io/appName=<vm-name> \
  -o jsonpath='{.items[*].status.restorePointContentDetails}'

# Parse DataVolume artifacts
jq '.artifacts[] | 
    select(.resource.group == "cdi.kubevirt.io" and 
           .resource.resource == "datavolumes")'
```

**Sample Output:**
```
VM RESTORE POINTS FOUND: 2

Name: rpc-rhel9-vm-backup-20251117
├─ VM: rhel9-vm
├─ Namespace: vms-prod
├─ State: Running
├─ Disks:
│  ├─ rootdisk (30Gi) - CSI Snapshot ✓
│  └─ datadisk (50Gi) - CSI Snapshot ✓
├─ MAC Preserved: Yes
├─ Freeze Annotation: k10.kasten.io/freezeVM=true
└─ Restore Methods: [Snapshot, Export]
```

---

### **5.2 VM Restore Script (`k10-vm-restore.sh`)**

**Primary Function:** Execute VM restore with CDI awareness

```bash
# Basic VM restore to same namespace
./k10-vm-restore.sh --restore-point rpc-rhel9-vm-backup-xyz \
                    --namespace vms-prod

# Restore VM to different namespace (clone)
./k10-vm-restore.sh --restore-point rpc-rhel9-vm-backup-xyz \
                    --target-namespace vms-test \
                    --vm-name rhel9-vm-test \
                    --new-mac  # Generate new MAC addresses

# Restore stopped VM (don't auto-start)
./k10-vm-restore.sh --restore-point rpc-rhel9-vm-backup-xyz \
                    --namespace vms-prod \
                    --no-start

# Restore with disk resize
./k10-vm-restore.sh --restore-point rpc-rhel9-vm-backup-xyz \
                    --namespace vms-prod \
                    --resize-disk rootdisk=50Gi

# Dry run with validation
./k10-vm-restore.sh --restore-point rpc-rhel9-vm-backup-xyz \
                    --namespace vms-prod \
                    --dry-run --validate
```

**VM-Specific Restore Logic:**

#### **5.2.1 Pre-Restore Validation**

```bash
validate_vm_restore() {
  # Check OpenShift Virtualization is available
  check_kubevirt_installed
  
  # Verify VolumeSnapshotClass for VM disks
  check_vm_snapshot_classes
  
  # Validate storage class for DataVolumes
  check_storage_class_compatibility
  
  # Check namespace resource quotas
  validate_namespace_capacity
}
```

#### **5.2.2 Transform Application for VMs**

**Critical Transforms Required:**
Transforms are used to instruct the OpenShift Virtualization operator to not handle data import/population activities and let K10 restore the data.

**Transform 1: DataVolume Resource**
```yaml
# Disable CDI import/clone operations
transforms:
  - subject:
      resource: datavolumes
      group: cdi.kubevirt.io
      resourceNameRegex: ".*"
    json:
      - op: remove
        path: /spec/source
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.populatedFor
        value: "<pvc-name>"
```

**Transform 2: PersistentVolumeClaim Resource**
```yaml
# Add CDI annotations to PVC
transforms:
  - subject:
      resource: persistentvolumeclaims
      resourceNameRegex: ".*"
    json:
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound
        value: "true"
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound.reason
        value: "Bound"
```

**Transform 3: VirtualMachine Resource**
```yaml
# Update VM to reference restored DataVolumes
transforms:
  - subject:
      resource: virtualmachines
      group: kubevirt.io
      resourceNameRegex: ".*"
    json:
      - op: replace
        path: /spec/dataVolumeTemplates
        value: []  # Clear templates, use existing DVs
```

#### **5.2.3 MAC Address Handling**

K10 8.0+ added a feature to preserve MAC addresses for virtual machines during restoration, to enhance network stability and configuration consistency.

```bash
handle_mac_addresses() {
  local preserve_mac=$1  # true/false
  
  if [[ "$preserve_mac" == "false" ]]; then
    # Generate new MAC addresses
    transforms+=$(cat <<EOF
  - subject:
      resource: virtualmachines
      group: kubevirt.io
    json:
      - op: remove
        path: /spec/template/spec/domain/devices/interfaces/0/macAddress
EOF
)
  fi
  # Otherwise, K10 preserves original MACs by default in v8.0+
}
```

#### **5.2.4 VM State Management**

```bash
manage_vm_state() {
  local vm_name=$1
  local namespace=$2
  local auto_start=$3
  
  if [[ "$auto_start" == "false" ]]; then
    # Ensure VM doesn't auto-start after restore
    kubectl patch vm ${vm_name} -n ${namespace} \
      --type=json -p='[{"op":"replace","path":"/spec/running","value":false}]'
  fi
}
```

#### **5.2.5 DataVolume Resolution**

```bash
resolve_datavolumes() {
  local restore_point=$1
  
  # Get DataVolume artifacts from restore point
  datavolumes=$(kubectl get --raw \
    "/apis/apps.kio.kasten.io/v1alpha1/restorepointcontents/${restore_point}/details" | \
    jq -r '.status.restorePointContentDetails.artifacts[] | 
           select(.resource.group=="cdi.kubevirt.io" and 
                  .resource.resource=="datavolumes") | 
           .resource.name')
  
  # Build restore order: DataVolumes → PVCs → VM
  for dv in $datavolumes; do
    echo "  ├─ DataVolume: $dv"
    # Get associated PVC
    pvc=$(get_pvc_for_datavolume $dv)
    echo "  │  └─ PVC: $pvc"
  done
}
```

---

### **5.3 VM Transform Script (`k10-vm-transform.sh`)**

**Primary Function:** Generate VM-specific transforms

```bash
# Generate all required VM transforms
./k10-vm-transform.sh --restore-point rpc-rhel9-vm-backup-xyz \
                      --output transforms.yaml

# Generate with customizations
./k10-vm-transform.sh --restore-point rpc-rhel9-vm-backup-xyz \
                      --new-storage-class ocs-storagecluster-ceph-rbd \
                      --new-namespace vms-test \
                      --new-mac \
                      --output transforms.yaml
```

**Generated Transform Structure:**

```yaml
apiVersion: config.kio.kasten.io/v1alpha1
kind: TransformSet
metadata:
  name: vm-restore-transforms-rhel9
  namespace: kasten-io
spec:
  transforms:
    # DataVolume transforms (disable CDI import)
    - subject:
        resource: datavolumes
        group: cdi.kubevirt.io
      json:
        - op: remove
          path: /spec/source
        - op: add
          path: /metadata/annotations/cdi.kubevirt.io~1storage.populatedFor
          value: "{{.spec.pvc.name}}"
    
    # PVC transforms (add CDI bound annotations)
    - subject:
        resource: persistentvolumeclaims
      json:
        - op: add
          path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound
          value: "true"
        - op: replace
          path: /spec/storageClassName
          value: "ocs-storagecluster-ceph-rbd"
    
    # VM transforms (update references, optionally remove MAC)
    - subject:
        resource: virtualmachines
        group: kubevirt.io
      json:
        - op: replace
          path: /spec/dataVolumeTemplates
          value: []
```

---

### **5.4 VM Common Functions (`k10-vm-common.sh`)**

**VM-Specific Utilities:**

```bash
# Check if resource is a VM
is_virtual_machine() {
  local app_name=$1
  local namespace=$2
  kubectl get vm ${app_name} -n ${namespace} &>/dev/null
}

# Get VM disk information
get_vm_disks() {
  local vm_name=$1
  local namespace=$2
  kubectl get vm ${vm_name} -n ${namespace} \
    -o jsonpath='{.spec.template.spec.volumes[*].dataVolume.name}'
}

# Check if VM was frozen during backup
check_vm_freeze_annotation() {
  local vm_name=$1
  local namespace=$2
  kubectl get vm ${vm_name} -n ${namespace} \
    -o jsonpath='{.metadata.annotations.k10\.kasten\.io/freezeVM}'
}

# Validate OpenShift Virtualization is installed
check_kubevirt_installed() {
  kubectl get crd virtualmachines.kubevirt.io &>/dev/null || {
    log_error "OpenShift Virtualization not installed"
    exit 1
  }
}

# Get DataVolume → PVC mapping
get_pvc_for_datavolume() {
  local dv_name=$1
  local namespace=$2
  kubectl get dv ${dv_name} -n ${namespace} \
    -o jsonpath='{.status.claimName}'
}

# Wait for VM to be ready after restore
wait_for_vm_ready() {
  local vm_name=$1
  local namespace=$2
  local timeout=${3:-300}  # 5 minutes default
  
  echo "Waiting for VM ${vm_name} to be ready..."
  kubectl wait --for=condition=Ready \
    vm/${vm_name} -n ${namespace} \
    --timeout=${timeout}s
}

# Check VM guest agent availability
check_vm_guest_agent() {
  local vm_name=$1
  local namespace=$2
  kubectl get vmi ${vm_name} -n ${namespace} \
    -o jsonpath='{.status.guestOSInfo.id}' 2>/dev/null
}
```

---

## **6. VM-Specific Non-Functional Requirements**

### **6.1 Performance**
- VM discovery: < 10 seconds for 50 VMs
- Restore initialization: < 60 seconds
- Disk restore: Dependent on data size (baseline: match K10 UI)
- VM boot time: Not controlled by script (depends on VM resources)

### **6.2 VM State Preservation**
- MAC addresses preserved by default (K10 8.0+ feature)
- CPU/Memory allocation maintained
- Network configuration retained
- Cloud-init data restored correctly

### **6.3 Compatibility**
- OpenShift Virtualization 4.14+ (included in OCP 4.18)
- KubeVirt VMs (VirtualMachine, VirtualMachineInstance)
- CDI (Containerized Data Importer) v1.55+
- CSI snapshots for VM disks

---

## **7. VM Restore Workflows**

### **7.1 Workflow: Restore Single VM to Same Namespace**

```bash
# 1. Discover VM restore points
./k10-vm-discover.sh --vm rhel9-webserver --namespace vms-prod

# Output shows:
# - 3 restore points found
# - Latest has 2 disks (rootdisk 30Gi, datadisk 50Gi)
# - Both disks have CSI snapshots available

# 2. Validate restore (dry-run)
./k10-vm-restore.sh \
  --restore-point rpc-rhel9-webserver-20251117 \
  --namespace vms-prod \
  --dry-run

# Output shows:
# ✓ VM rhel9-webserver found in restore point
# ✓ 2 DataVolumes identified
# ✓ CSI snapshots available for all disks
# ✓ Storage class compatible: ocs-storagecluster-ceph-rbd
# ✓ Namespace has sufficient quota
# ✓ Transforms will be applied: 6 transforms generated
# 
# RESTORE PLAN:
# 1. Create DataVolume: rhel9-webserver-rootdisk
# 2. Create DataVolume: rhel9-webserver-datadisk
# 3. Create PVCs from snapshots
# 4. Create VirtualMachine: rhel9-webserver
# 5. VM will start automatically

# 3. Execute restore
./k10-vm-restore.sh \
  --restore-point rpc-rhel9-webserver-20251117 \
  --namespace vms-prod

# Script monitors:
# - RestoreAction creation
# - DataVolume creation
# - PVC binding
# - VM creation
# - VM startup (if running state)

# 4. Verify VM
kubectl get vm rhel9-webserver -n vms-prod
kubectl get vmi rhel9-webserver -n vms-prod
```

### **7.2 Workflow: Clone VM to Different Namespace**

```bash
# Clone production VM to test environment
./k10-vm-restore.sh \
  --restore-point rpc-rhel9-webserver-20251117 \
  --target-namespace vms-test \
  --vm-name rhel9-webserver-test \
  --new-mac \
  --no-start \
  --transform-storage "ocs-storagecluster-ceph-rbd:ocs-storagecluster-ceph-rbd"

# Process:
# 1. Create vms-test namespace if needed
# 2. Generate new MAC addresses (avoid conflicts)
# 3. Restore VM in stopped state
# 4. Admin can modify VM config before starting
```

### **7.3 Workflow: Restore Deleted VM**

```bash
# 1. List deleted VMs (those with restore points but no active VM)
./k10-vm-discover.sh --deleted-only

# Output:
# DELETED VMs WITH RESTORE POINTS:
# - rhel8-old-app (last backup: 2025-11-10)
# - windows-vm-legacy (last backup: 2025-11-15)

# 2. Recreate namespace if it was also deleted
kubectl create namespace vms-archive

# 3. Restore deleted VM
./k10-vm-restore.sh \
  --restore-point rpc-windows-vm-legacy-20251115 \
  --target-namespace vms-archive \
  --no-start
```

---

## **8. Implementation Priority - MVP**

### **Phase 1 (Week 1-2): Core VM Discovery**
- `k10-vm-discover.sh` basic functionality
- VM-specific filtering
- DataVolume and disk identification
- Snapshot vs export detection

### **Phase 2 (Week 3-4): Basic VM Restore**
- `k10-vm-restore.sh` core logic
- RestoreAction creation with VM transforms
- DataVolume → PVC → VM restore order
- Same-namespace restore only

### **Phase 3 (Week 5-6): Transform Handling**
- `k10-vm-transform.sh` implementation
- CDI transform generation
- MAC address handling
- Storage class mapping

### **Phase 4 (Week 7-8): Cross-Namespace & Polish**
- Different namespace restore
- VM naming options
- Error handling and recovery
- Documentation and examples

---

## **9. Testing Strategy - VM Focus**

### **9.1 Test Environment**
- OpenShift 4.18 cluster
- OpenShift Virtualization operator installed
- K10 8.x with CSI snapshot support
- Test VMs: RHEL 9, Windows Server (if license available), Ubuntu

### **9.2 VM Test Scenarios**

| Scenario | VM State | Disks | Expected Result |
|----------|----------|-------|----------------|
| Restore running VM (same NS) | Running | 1 (rootdisk) | VM restored and running |
| Restore stopped VM (same NS) | Stopped | 2 (root+data) | VM restored, stays stopped |
| Clone VM to different NS | Running | 1 | New VM with new MAC |
| Restore deleted VM | N/A | 1 | VM recreated successfully |
| Restore with disk resize | Stopped | 1 | PVC resized correctly |
| Restore from export (no snapshot) | Stopped | 1 | Import from object storage works |
| Restore with frozen VM annotation | Running | 1 | Freeze annotation handled |

### **9.3 Validation Checks**

```bash
# Post-restore validation script
validate_vm_restore() {
  local vm_name=$1
  local namespace=$2
  
  echo "Validating VM restore..."
  
  # Check VM exists
  kubectl get vm ${vm_name} -n ${namespace} || return 1
  
  # Check DataVolumes bound
  datavolumes=$(kubectl get vm ${vm_name} -n ${namespace} \
    -o jsonpath='{.spec.template.spec.volumes[*].dataVolume.name}')
  
  for dv in $datavolumes; do
    status=$(kubectl get dv ${dv} -n ${namespace} \
      -o jsonpath='{.status.phase}')
    [[ "$status" == "Succeeded" ]] || {
      echo "ERROR: DataVolume ${dv} not ready (status: ${status})"
      return 1
    }
  done
  
  # Check PVCs bound
  for dv in $datavolumes; do
    pvc=$(kubectl get dv ${dv} -n ${namespace} \
      -o jsonpath='{.status.claimName}')
    status=$(kubectl get pvc ${pvc} -n ${namespace} \
      -o jsonpath='{.status.phase}')
    [[ "$status" == "Bound" ]] || {
      echo "ERROR: PVC ${pvc} not bound"
      return 1
    }
  done
  
  # If VM should be running, check VMI
  vm_running=$(kubectl get vm ${vm_name} -n ${namespace} \
    -o jsonpath='{.spec.running}')
  
  if [[ "$vm_running" == "true" ]]; then
    kubectl get vmi ${vm_name} -n ${namespace} || {
      echo "ERROR: VMI not found for running VM"
      return 1
    }
  fi
  
  echo "✓ VM restore validated successfully"
  return 0
}
```

---

## **10. VM-Specific Error Scenarios**

### **10.1 Common VM Restore Failures**

| Error | Cause | Resolution |
|-------|-------|-----------|
| DataVolume stuck in "WaitForFirstConsumer" | Storage class not available | Check StorageClass, create if needed |
| CDI import pod fails | Missing source snapshot | Use export restore instead |
| VM doesn't start after restore | Insufficient resources | Check namespace quota, resize if needed |
| PVC remains "Pending" | No VolumeSnapshotClass | Annotate VolumeSnapshotClass with K10 label |
| MAC address conflict | VM clone without `--new-mac` | Delete VM, retry with `--new-mac` flag |
| Transform validation fails | Invalid JSON patch | Check transform syntax, use `--dry-run` |

### **10.2 Error Handling Code**

```bash
handle_restore_error() {
  local error_type=$1
  local restore_action=$2
  
  case "$error_type" in
    "DataVolumeStuck")
      echo "ERROR: DataVolume creation stuck"
      echo "Checking storage class availability..."
      check_storage_class
      echo "Checking VolumeSnapshotClass..."
      check_snapshot_class
      ;;
    
    "VMStartFailure")
      echo "ERROR: VM failed to start after restore"
      echo "Checking resource quotas..."
      kubectl describe resourcequota -n ${namespace}
      echo "Checking VM events..."
      kubectl get events -n ${namespace} --sort-by='.lastTimestamp' | \
        grep ${vm_name}
      ;;
    
    "PVCBindFailure")
      echo "ERROR: PVC failed to bind"
      echo "Checking PV availability..."
      kubectl get pv | grep ${namespace}
      echo "PVC status:"
      kubectl describe pvc -n ${namespace}
      ;;
  esac
  
  # Log to K10 action
  kubectl annotate restoreaction ${restore_action} -n ${namespace} \
    error-details="Script detected: ${error_type}" \
    --overwrite
}
```

---

## **11. Configuration File Schema**

### **11.1 VM Restore Profile (`vm-restore-profile.yaml`)**

```yaml
apiVersion: k10-utils.io/v1alpha1
kind: VMRestoreProfile
metadata:
  name: vm-restore-defaults
spec:
  # Default behavior
  autoStart: true
  preserveMAC: true
  preferSnapshot: true
  
  # Storage mappings
  storageClassMap:
    source: ocs-storagecluster-ceph-rbd-prod
    target: ocs-storagecluster-ceph-rbd-test
  
  # Transform templates
  transforms:
    dataVolume:
      - op: remove
        path: /spec/source
    pvc:
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound
        value: "true"
  
  # Validation settings
  validation:
    waitForVMReady: true
    timeout: 600  # 10 minutes
    checkGuestAgent: false
  
  # Namespace settings
  targetNamespace:
    create: true
    copyLabels: true
    quotas:
      requests.cpu: "4"
      requests.memory: "8Gi"
```

---

## **12. Documentation Outline - VM Focus**

### **12.1 Quick Start Guide**

```markdown
# Kasten K10 VM Recovery - Quick Start

## Prerequisites
- OpenShift 4.18 with Virtualization
- Kasten K10 v8.x installed
- VMs backed up by K10 policies

## 5-Minute VM Restore

1. Find your VM's restore point:
   ```bash
   ./k10-vm-discover.sh --vm my-rhel-vm --namespace vms-prod
   ```

2. Restore the VM:
   ```bash
   ./k10-vm-restore.sh \
     --restore-point rpc-my-rhel-vm-<timestamp> \
     --namespace vms-prod
   ```

3. Verify:
   ```bash
   kubectl get vm my-rhel-vm -n vms-prod
   ```

Done! Your VM is restored.
```

### **12.2 Advanced Usage**

- Clone VM to test environment
- Restore deleted VMs
- Resize disks during restore
- Handle MAC address conflicts
- Troubleshooting common issues

---

## **13. Dependencies & Assumptions - VM Context**

### **Dependencies:**
- OpenShift Virtualization 4.14+ (OCP 4.18 includes 4.18)
- Kasten K10 v8.0+ (for MAC preservation feature)
- CDI (Containerized Data Importer) installed
- CSI-compliant storage with VolumeSnapshotClass support
- VolumeSnapshotClass annotated with k10.kasten.io/is-snapshot-class=true

### **Assumptions:**
- [Inference] VMs use standard KubeVirt VirtualMachine CRDs
- [Inference] VM disks are primarily on DataVolumes (not hostPath)
- VM annotation k10.kasten.io/freezeVM=true is used if filesystem freeze is needed during backup
- [Unverified] Windows VMs may have different guest agent behavior

### **VM-Specific RBAC:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k10-vm-restore-utils
rules:
  # K10 APIs
  - apiGroups: ["apps.kio.kasten.io"]
    resources: ["restorepoints", "restorepointcontents", "applications"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["actions.kio.kasten.io"]
    resources: ["restoreactions"]
    verbs: ["create", "get", "list", "watch"]
  
  # VM resources
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "create", "patch"]
  
  # CDI resources
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes"]
    verbs: ["get", "list", "create", "patch"]
  
  # Storage
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "create", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots"]
    verbs: ["get", "list"]
  
  # Namespaces
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create"]
```

---

## **14. Success Metrics - MVP**

- **VM Discovery:** < 5 seconds for 20 VMs
- **Restore Success Rate:** 90%+ for standard VMs (RHEL/Ubuntu)
- **Time to Restore:** Initialize restore in < 60 seconds
- **Usability:** Reduce manual steps by 70% vs UI workflow
- **Adoption:** Used for 50% of VM recovery operations within 3 months

---

## **15. Known Limitations - MVP**

### **Out of Scope:**
- Windows VM-specific optimizations (basic restore only)
- Live migration or hot-plug disk restore
- VM template/golden image restoration
- Multi-disk resize operations
- Cross-cluster VM migration
- VM network reconfiguration
- Custom VM scheduling constraints

### **Technical Constraints:**
- Freeze/thaw timeout configurable via helm with default 5 minutes
- [Inference] Large VM disks (>500Gi) may require extended timeouts
- [Unverified] Some VM configurations may require manual validation

---

## **16. References & Sources - VM Focus**

**Primary Sources:**
1. Kasten K10 OpenShift Virtualization Documentation: https://docs.kasten.io/5.5.0/usage/openshift_virtualization.html
2. Kasten K10 v8.0 Release Notes: https://docs.kasten.io/latest/releasenotes/
3. Kasten K10 API - RestorePoints: https://docs.kasten.io/latest/api/restorepoints/
4. Kasten K10 API - Actions: https://docs.kasten.io/latest/api/actions/
5. OpenShift Virtualization on OCP 4.18: Integration context from search results

**Confidence Assessment:**
- **82% confidence** based on:
  - Official K10 VM documentation (70% of requirements)
  - K10 v8.0+ release notes (15% - MAC preservation, individual volume restore)
  - General K10 API documentation (10%)
  - [Inference] CDI transform patterns (5% - based on CDI behavior, not explicitly documented)

**Gaps:**
- [Unverified] Specific OpenShift 4.18 VM features integration with K10 8.x
- [Unverified] Windows VM guest agent behavior during restore
- [Inference] Optimal transform patterns for complex multi-disk VMs

---

## **17. Next Steps - MVP Implementation**

### **Sprint 1 (2 weeks):** Core Discovery
- Implement `k10-vm-discover.sh`
- VM filtering and metadata extraction
- DataVolume relationship mapping

### **Sprint 2 (2 weeks):** Basic Restore
- Implement `k10-vm-restore.sh` (same-namespace only)
- RestoreAction creation with VM transforms
- Integration testing with RHEL VMs

### **Sprint 3 (2 weeks):** Transform Engine
- Implement `k10-vm-transform.sh`
- CDI transform generation
- MAC address handling

### **Sprint 4 (2 weeks):** Polish & Cross-Namespace
- Cross-namespace restore support
- Error handling improvements
- User documentation
- Demo and handoff

**Total MVP Timeline:** 8 weeks

---

## **Appendix A: Key Kasten K10 API Resources**

### **RestorePointContent API**
```bash
# List all restore point contents
kubectl get restorepointcontents.apps.kio.kasten.io -A

# Get details for specific restore point
kubectl get restorepointcontents.apps.kio.kasten.io <name> -o yaml

# Query details endpoint
kubectl get --raw /apis/apps.kio.kasten.io/v1alpha1/restorepointcontents/<name>/details
```

### **RestoreAction API**
```bash
# Create restore action
kubectl create -f restore-action.yaml

# Monitor restore progress
kubectl get restoreactions.actions.kio.kasten.io -n <namespace> -w

# Check restore status
kubectl get restoreaction <name> -n <namespace> -o jsonpath='{.status.state}'
```

### **Key Labels for Filtering**
```
k10.kasten.io/appName=<application-name>
k10.kasten.io/appNamespace=<namespace>
k10.kasten.io/policyName=<policy-name>
```

---

## **Appendix B: VM Resource Relationships**

```
┌─────────────────────────────────────────────────────────────┐
│                     VirtualMachine (VM)                      │
│  - spec.running: true/false                                  │
│  - spec.template.spec.domain (CPU, Memory)                   │
│  - spec.dataVolumeTemplates[] (Disk definitions)             │
│  - metadata.annotations (k10.kasten.io/freezeVM)             │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ├─── Creates ───►  VirtualMachineInstance (VMI)
                 │                  [Runtime representation]
                 │
                 └─── References ───►  DataVolume(s)
                                       │
                                       ├─ spec.source (Import source)
                                       ├─ spec.pvc (PVC template)
                                       │
                                       └─── Creates ───►  PersistentVolumeClaim(s)
                                                          │
                                                          └─── Binds to ───►  PersistentVolume
                                                                              │
                                                                              └─── VolumeSnapshot (CSI)
```

**Restore Flow:**
1. K10 RestoreAction created
2. DataVolumes created (with CDI transforms)
3. PVCs created from snapshots
4. VM created referencing DataVolumes
5. VMI created if VM.spec.running=true

---

## **Appendix C: Example RestoreAction YAML**

```yaml
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: restore-rhel9-vm-
  namespace: vms-prod
  labels:
    k10.kasten.io/appName: "rhel9-webserver"
    k10.kasten.io/appNamespace: "vms-prod"
spec:
  subject:
    namespace: vms-prod
    restorePointContentName: rpc-rhel9-webserver-20251117
  
  # VM-specific transforms
  transforms:
    # DataVolume: Disable CDI import
    - subject:
        resource: datavolumes
        group: cdi.kubevirt.io
        resourceNameRegex: ".*"
      json:
        - op: remove
          path: /spec/source
        - op: add
          path: /metadata/annotations/cdi.kubevirt.io~1storage.populatedFor
          value: "rhel9-webserver-rootdisk"
    
    # PVC: Add CDI bound annotations
    - subject:
        resource: persistentvolumeclaims
        resourceNameRegex: "rhel9-webserver-.*"
      json:
        - op: add
          path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound
          value: "true"
        - op: add
          path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound.reason
          value: "Bound"
    
    # VM: Clear dataVolumeTemplates
    - subject:
        resource: virtualmachines
        group: kubevirt.io
        name: rhel9-webserver
      json:
        - op: replace
          path: /spec/dataVolumeTemplates
          value: []
```

---

**Document End**

**Approval Checklist:**
- [ ] Technical approach validated
- [ ] VM-specific transforms verified with K10 team
- [ ] Test environment provisioned (OCP 4.18 + K10 8.x + VMs)
- [ ] RBAC permissions approved
- [ ] Sprint timeline confirmed

**Questions/Feedback:** Please contact the platform engineering team.

---

## **18. Operational Considerations & Guardrails**

### **18.1 Execution Model & RBAC**

- Scripts are intended to run under a dedicated ServiceAccount bound to the `k10-vm-restore-utils` `ClusterRole` (or equivalent), not with cluster-admin by default.
- Least-privilege principle: any additional verbs or resources required beyond those in this PRD MUST be reviewed and approved before rollout.
- Operators SHOULD run scripts from a controlled automation context (e.g., CI/CD runner, operations bastion) rather than arbitrary user workstations when possible.

### **18.2 Namespace & Multi-Tenancy Guardrails**

- Cross-namespace restores (e.g., `--target-namespace`) MUST be explicitly allowed either via:
  - a `VMRestoreProfile` mapping (`spec.targetNamespace`) or
  - a configuration file/flag indicating permitted `sourceNamespace → targetNamespace` pairs.
- Scripts MUST validate that the acting identity has access to both source and target namespaces before attempting restore.
- Namespace creation:
  - Only performed when explicitly requested (`--create-namespace` flag or `spec.targetNamespace.create: true` in `VMRestoreProfile`).
  - Created namespaces SHOULD be labeled/annotated to indicate that they were created by the VM recovery utility (for audit/cleanup).

### **18.3 Safety Defaults & Dry-Run Behavior**

- For any restore operation, `--dry-run` SHOULD be the default behavior when no explicit confirmation flag (e.g., `--yes` or `--no-dry-run`) is provided.
- Dry-run mode MUST:
  - Perform all validation checks (KubeVirt/CDI installed, storage class compatibility, namespace quota checks).
  - Generate and display the effective restore plan (resources to be created/modified) without making changes.
- Non-dry-run operations MUST clearly echo a summary of actions (restore point, target namespace, VM name, disk mapping) before execution.

### **18.4 Error Handling, Idempotency & Cleanup**

- All scripts MUST use predictable exit codes (for automation integration), for example:
  - `0` = success.
  - `1` = validation failure (pre-checks, configuration/profile errors).
  - `2` = K10 API failure (RestoreAction/RestorePoint access issues).
  - `3` = storage-related failure (DataVolume/PVC/VolumeSnapshot issues).
  - `4` = VM creation/startup failure.
- On partial failure (e.g., DataVolumes created but VM not created), the script MUST:
  - Clearly report which resources were successfully created.
  - Avoid automatic destructive cleanup by default (to allow manual inspection).
  - Optionally support a `--cleanup-on-failure` flag for environments that prefer automatic rollback.
- RestoreAction objects SHOULD be annotated with error details (as shown earlier) to allow correlation with K10 UI and logs.

### **18.5 Concurrency & Locking Assumptions**

- Scripts do NOT implement strict distributed locking; operators MUST avoid running concurrent restores for the same VM/restore point.
- Recommended best practice:
  - Use a lightweight lock at the VM level (e.g., an annotation `k10.kasten.io/vm-restore-in-progress=true`) to signal active operations.
  - Scripts SHOULD check for this annotation and fail fast (or wait, if a `--wait-for-lock` option is implemented) when another restore is in progress.

### **18.6 Configuration Profiles & Precedence**

- `VMRestoreProfile` is the primary mechanism for expressing defaults (storage mappings, autoStart, MAC handling, namespace behavior).
- Configuration precedence MUST be:
  1. CLI flags (highest precedence).
  2. Profile values (`VMRestoreProfile`).
  3. Built-in script defaults (lowest precedence).
- Scripts SHOULD support a `--profile <name>` flag to select the profile and MUST clearly indicate which profile was applied in their output.

### **18.7 Output Format & Logging**

- `k10-vm-discover.sh` and `k10-vm-restore.sh` SHOULD support both human-readable and machine-readable output:
  - Human-readable: default, concise table/list format.
  - Machine-readable: `--output json` (or similar) to facilitate integration with portals/automation.
- Logs SHOULD:
  - Include timestamps and the RestoreAction name (if applicable).
  - Avoid printing sensitive data from Secrets (only reference by name/namespace).
  - Be suitable for shipping to centralized logging systems.

### **18.8 Packaging, Distribution & Prerequisites**

- Scripts MAY be distributed as:
  - A container image (preferred for controlled environments), or
  - A versioned Git repository/tarball with checksums.
- Minimum prerequisites:
  - `bash`, `kubectl`, and `jq` available in the execution environment.
  - Kubeconfig context with permissions matching the `k10-vm-restore-utils` role.
- Documentation MUST specify supported K10 and OpenShift versions (K10 8.x, OCP 4.18/OpenShift Virtualization 4.14+) and the policy for re-validation on upgrades.

### **18.9 Data & Secret Handling**

- When cloning to another namespace, ConfigMaps and Secrets SHOULD be:
  - Filtered by label/annotation (e.g., only `k10.kasten.io/restore=true` or similar) to avoid unintentionally copying unrelated or highly sensitive data.
  - Restored with the same names by default, unless a collision is detected.
- Scripts MUST NOT log the contents of Secrets; only names and relationships (e.g., VM → Secret).

### **18.10 Limitations & Operator Responsibilities**

- Scripts do not enforce tenant boundaries beyond Kubernetes RBAC and the configured namespace mappings; cluster operators are responsible for designing appropriate multi-tenant policies.
- Windows VM behavior remains “best-effort”: the same guardrails apply, but guest agent/application-level consistency is not guaranteed and MUST be validated manually by operators.
