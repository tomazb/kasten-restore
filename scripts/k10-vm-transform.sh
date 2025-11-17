#!/bin/bash

# Kasten K10 VM Recovery Utility - Transform Generation Script
# Version: 1.0.0
# Description: Generate VM-specific transforms for DataVolumes and PVCs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k10-vm-common.sh
source "${SCRIPT_DIR}/k10-vm-common.sh"

# Default values
RESTORE_POINT=""
OUTPUT_FILE=""
NEW_STORAGE_CLASS=""
NEW_NAMESPACE=""
NEW_MAC=false
VM_NAME=""
TRANSFORM_NAME=""

# Usage function
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Generate VM-specific transforms for Kasten K10 restore operations.

OPTIONS:
  --restore-point <rpc>    Restore point content name (required)
  --output <file>          Output file for transforms (default: stdout)
  --new-storage-class <sc> Target storage class
  --new-namespace <ns>     Target namespace for restore
  --new-mac                Generate new MAC addresses
  --vm-name <name>         Override VM name
  --transform-name <name>  Transform set name (default: auto-generated)
  --help                   Show this help message

EXAMPLES:
  # Generate transforms for basic restore
  $0 --restore-point rpc-rhel9-vm-backup-xyz --output transforms.yaml

  # Generate transforms with storage class change
  $0 --restore-point rpc-rhel9-vm-backup-xyz \\
     --new-storage-class ocs-storagecluster-ceph-rbd \\
     --output transforms.yaml

  # Generate transforms for cross-namespace restore with new MAC
  $0 --restore-point rpc-rhel9-vm-backup-xyz \\
     --new-namespace vms-test \\
     --new-mac \\
     --output transforms.yaml

EOF
  exit 1
}

# Parse arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --restore-point)
        RESTORE_POINT="$2"
        shift 2
        ;;
      --output)
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --new-storage-class)
        NEW_STORAGE_CLASS="$2"
        shift 2
        ;;
      --new-namespace)
        NEW_NAMESPACE="$2"
        shift 2
        ;;
      --new-mac)
        NEW_MAC=true
        shift
        ;;
      --vm-name)
        VM_NAME="$2"
        shift 2
        ;;
      --transform-name)
        TRANSFORM_NAME="$2"
        shift 2
        ;;
      --help)
        usage
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done

  # Validate required arguments
  if [[ -z "$RESTORE_POINT" ]]; then
    log_error "Missing required option: --restore-point"
    usage
  fi
}

# Get DataVolume names from restore point
get_datavolumes_from_rpc() {
  local rpc_name=$1

  kubectl get restorepointcontent "$rpc_name" -A -o json 2>/dev/null | \
    jq -r '.status.restorePointContentDetails.artifacts[]? |
           select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
           .resource.name' || echo ""
}

# Get VM details from restore point
get_vm_details_from_rpc() {
  local rpc_name=$1

  kubectl get restorepointcontent "$rpc_name" -A -o json 2>/dev/null || echo '{}'
}

# Generate DataVolume transforms
generate_datavolume_transforms() {
  cat <<'EOF'
  # DataVolume: Disable CDI import/clone operations
  - subject:
      resource: datavolumes
      group: cdi.kubevirt.io
      resourceNameRegex: ".*"
    json:
      # Remove source to prevent CDI from attempting import
      - op: remove
        path: /spec/source
      # Add annotation to indicate PVC is already populated
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.populatedFor
        value: "{{.spec.pvc.name}}"
EOF

  if [[ -n "$NEW_STORAGE_CLASS" ]]; then
    cat <<EOF
      # Update storage class
      - op: replace
        path: /spec/pvc/storageClassName
        value: "${NEW_STORAGE_CLASS}"
EOF
  fi
}

# Generate PVC transforms
generate_pvc_transforms() {
  cat <<'EOF'
  # PersistentVolumeClaim: Add CDI bound annotations
  - subject:
      resource: persistentvolumeclaims
      resourceNameRegex: ".*"
    json:
      # Add CDI bound annotation
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound
        value: "true"
      # Add bound reason annotation
      - op: add
        path: /metadata/annotations/cdi.kubevirt.io~1storage.condition.bound.reason
        value: "Bound"
EOF

  if [[ -n "$NEW_STORAGE_CLASS" ]]; then
    cat <<EOF
      # Update storage class
      - op: replace
        path: /spec/storageClassName
        value: "${NEW_STORAGE_CLASS}"
EOF
  fi
}

# Generate VirtualMachine transforms
generate_vm_transforms() {
  local vm_name_override=$1

  cat <<EOF
  # VirtualMachine: Clear dataVolumeTemplates
  - subject:
      resource: virtualmachines
      group: kubevirt.io
      resourceNameRegex: ".*"
    json:
      # Clear dataVolumeTemplates to use existing DataVolumes
      - op: replace
        path: /spec/dataVolumeTemplates
        value: []
EOF

  if [[ "$NEW_MAC" == true ]]; then
    cat <<'EOF'
      # Remove MAC addresses to generate new ones
      - op: remove
        path: /spec/template/spec/domain/devices/interfaces/0/macAddress
EOF
  fi

  if [[ -n "$vm_name_override" ]]; then
    cat <<EOF
      # Override VM name
      - op: replace
        path: /metadata/name
        value: "${vm_name_override}"
EOF
  fi
}

# Generate namespace transform
generate_namespace_transform() {
  if [[ -n "$NEW_NAMESPACE" ]]; then
    cat <<EOF
  # Namespace: Update target namespace
  - subject:
      resourceNameRegex: ".*"
    json:
      - op: replace
        path: /metadata/namespace
        value: "${NEW_NAMESPACE}"
EOF
  fi
}

# Generate complete transform set
generate_transform_set() {
  local rpc_name=$1
  local vm_details
  vm_details=$(get_vm_details_from_rpc "$rpc_name")

  local source_vm_name source_namespace
  source_vm_name=$(echo "$vm_details" | jq -r '.metadata.labels."k10.kasten.io/appName" // "unknown"')
  source_namespace=$(echo "$vm_details" | jq -r '.metadata.labels."k10.kasten.io/appNamespace" // "unknown"')

  # Generate transform name if not provided
  if [[ -z "$TRANSFORM_NAME" ]]; then
    TRANSFORM_NAME="vm-restore-transforms-${source_vm_name}-$(generate_timestamp)"
  fi

  # Sanitize transform name
  TRANSFORM_NAME=$(sanitize_k8s_name "$TRANSFORM_NAME")

  local k10_namespace
  k10_namespace=$(get_k10_namespace)

  cat <<EOF
---
# Generated VM Restore TransformSet
# Source VM: ${source_vm_name}
# Source Namespace: ${source_namespace}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

apiVersion: config.kio.kasten.io/v1alpha1
kind: TransformSet
metadata:
  name: ${TRANSFORM_NAME}
  namespace: ${k10_namespace}
  labels:
    k10-vm-utils.io/source-vm: "${source_vm_name}"
    k10-vm-utils.io/source-namespace: "${source_namespace}"
    k10-vm-utils.io/generated-by: "k10-vm-transform"
  annotations:
    k10-vm-utils.io/restore-point: "${rpc_name}"
    k10-vm-utils.io/generated-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
  transforms:
EOF

  # Generate transforms
  generate_datavolume_transforms
  echo ""
  generate_pvc_transforms
  echo ""
  generate_vm_transforms "$VM_NAME"

  # Add namespace transform if needed
  if [[ -n "$NEW_NAMESPACE" ]]; then
    echo ""
    generate_namespace_transform
  fi
}

# Generate transform summary
generate_transform_summary() {
  cat <<EOF

---
# Transform Summary
#
# This TransformSet will:
# 1. Disable CDI import/clone operations on DataVolumes
# 2. Add CDI bound annotations to PVCs
# 3. Clear dataVolumeTemplates on VirtualMachine
EOF

  if [[ -n "$NEW_STORAGE_CLASS" ]]; then
    echo "# 4. Update storage class to: ${NEW_STORAGE_CLASS}"
  fi

  if [[ -n "$NEW_NAMESPACE" ]]; then
    echo "# 5. Change target namespace to: ${NEW_NAMESPACE}"
  fi

  if [[ "$NEW_MAC" == true ]]; then
    echo "# 6. Remove MAC addresses (new ones will be generated)"
  fi

  if [[ -n "$VM_NAME" ]]; then
    echo "# 7. Override VM name to: ${VM_NAME}"
  fi

  cat <<EOF
#
# Usage:
# 1. Review the transforms above
# 2. Apply: kubectl apply -f <this-file>
# 3. Reference in RestoreAction:
#    spec:
#      transforms:
#        - name: ${TRANSFORM_NAME}
#          namespace: $(get_k10_namespace)
EOF
}

# Validate transform generation
validate_transform_inputs() {
  log_info "Validating transform generation inputs..."

  # Check if restore point exists
  if ! kubectl get restorepointcontent "$RESTORE_POINT" -A &>/dev/null; then
    log_error "Restore point not found: ${RESTORE_POINT}"
    return 1
  fi

  # Check if new storage class exists (if specified)
  if [[ -n "$NEW_STORAGE_CLASS" ]]; then
    if ! check_storage_class "$NEW_STORAGE_CLASS"; then
      log_warning "Storage class ${NEW_STORAGE_CLASS} not found, but continuing..."
    fi
  fi

  # Check if new namespace exists (if specified)
  if [[ -n "$NEW_NAMESPACE" ]]; then
    if ! namespace_exists "$NEW_NAMESPACE"; then
      log_warning "Namespace ${NEW_NAMESPACE} does not exist, it will need to be created before restore"
    fi
  fi

  log_success "Validation completed"
  return 0
}

# Main function
main() {
  parse_args "$@"

  # Validate prerequisites
  if ! validate_prerequisites; then
    exit 1
  fi

  # Check K10 installation
  if ! check_k10_installed; then
    exit 1
  fi

  # Validate inputs
  if ! validate_transform_inputs; then
    exit 1
  fi

  log_info "Generating transforms for restore point: ${RESTORE_POINT}"

  # Generate transforms
  local transforms
  transforms=$(generate_transform_set "$RESTORE_POINT")
  transforms+=$'\n'
  transforms+=$(generate_transform_summary)

  # Output transforms
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$transforms" > "$OUTPUT_FILE"
    log_success "Transforms written to: ${OUTPUT_FILE}"
    log_info "Review the file and apply with: kubectl apply -f ${OUTPUT_FILE}"
  else
    echo "$transforms"
  fi

  log_success "Transform generation completed"
}

# Run main function
main "$@"
