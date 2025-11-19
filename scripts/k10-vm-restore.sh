#!/bin/bash

# Kasten K10 VM Recovery Utility - VM Restore Script
# Version: 1.0.0
# Description: Execute VM restore operations with CDI awareness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k10-vm-common.sh
source "${SCRIPT_DIR}/k10-vm-common.sh"

# Default values
RESTORE_POINT=""
NAMESPACE=""
TARGET_NAMESPACE=""
VM_NAME=""
NEW_MAC=false
NO_START=false
DRY_RUN=false
VALIDATE=false
RESIZE_DISK=""
NEW_STORAGE_CLASS=""
CREATE_NAMESPACE=false
TRANSFORM_FILE=""
AUTO_CONFIRM=false
RESTORE_ACTION_NAME=""
CLONE_ON_CONFLICT=false
FORCE=false

# Usage function
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Execute VM restore from Kasten K10 restore points.

OPTIONS:
  --restore-point <rpc>      Restore point content name (required)
  --namespace <ns>           Source namespace (required if not in restore point)
  --target-namespace <ns>    Target namespace for restore (default: same as source)
  --vm-name <name>           Override VM name for restore
  --clone-on-conflict        If VM exists, restore to a cloned name (auto-suffix)
  --new-mac                  Generate new MAC addresses
  --no-start                 Don't auto-start VM after restore
  --dry-run                  Show what would be done without executing
  --validate                 Validate restore feasibility
  --resize-disk <name=size>  Resize disk during restore (e.g., rootdisk=50Gi)
  --new-storage-class <sc>   Target storage class
  --create-namespace         Create target namespace if it doesn't exist
  --transform-file <file>    Use custom transform file
  --force                    Delete previous K10 artifacts (TransformSet/RestoreAction) and re-run
  --yes                      Auto-confirm without prompting
  --help                     Show this help message

EXAMPLES:
  # Basic restore to same namespace
  $0 --restore-point rpc-rhel9-vm-backup-xyz --namespace vms-prod

  # Restore to different namespace with new MAC
  $0 --restore-point rpc-rhel9-vm-backup-xyz \\
     --target-namespace vms-test \\
     --vm-name rhel9-vm-test \\
     --new-mac \\
     --create-namespace

  # Restore stopped VM (don't auto-start)
  $0 --restore-point rpc-rhel9-vm-backup-xyz \\
     --namespace vms-prod \\
     --no-start

  # Dry run with validation
  $0 --restore-point rpc-rhel9-vm-backup-xyz \\
     --namespace vms-prod \\
     --dry-run --validate

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
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --target-namespace)
        TARGET_NAMESPACE="$2"
        shift 2
        ;;
      --vm-name)
        VM_NAME="$2"
        shift 2
        ;;
      --clone-on-conflict)
        CLONE_ON_CONFLICT=true
        shift
        ;;
      --new-mac)
        NEW_MAC=true
        shift
        ;;
      --no-start)
        NO_START=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --validate)
        VALIDATE=true
        shift
        ;;
      --resize-disk)
        RESIZE_DISK="$2"
        shift 2
        ;;
      --new-storage-class)
        NEW_STORAGE_CLASS="$2"
        shift 2
        ;;
      --create-namespace)
        CREATE_NAMESPACE=true
        shift
        ;;
      --transform-file)
        TRANSFORM_FILE="$2"
        shift 2
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --yes)
        AUTO_CONFIRM=true
        shift
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

# Resolve a unique VM name by appending a clone suffix when needed
resolve_clone_name() {
  local base_name=$1
  local namespace=$2
  local candidate

  candidate=$(sanitize_k8s_name "${base_name}-clone")
  if ! kubectl get vm "${candidate}" -n "${namespace}" &>/dev/null; then
    echo "${candidate}"
    return 0
  fi

  local i
  for i in $(seq 2 99); do
    candidate=$(sanitize_k8s_name "${base_name}-clone-${i}")
    if ! kubectl get vm "${candidate}" -n "${namespace}" &>/dev/null; then
      echo "${candidate}"
      return 0
    fi
  done

  # Fallback to time-suffixed (less deterministic)
  candidate=$(sanitize_k8s_name "${base_name}-clone-$(date +%s)")
  echo "${candidate}"
}

# Compute deterministic names for TransformSet and RestoreAction
compute_restore_names() {
  local rpc_safe
  rpc_safe=$(sanitize_k8s_name "$RESTORE_POINT" | cut -c1-20)
  TRANSFORM_NAME=$(sanitize_k8s_name "vm-restore-transforms-${VM_NAME}-${rpc_safe}")
  RESTORE_ACTION_NAME=$(sanitize_k8s_name "restore-${VM_NAME}-${rpc_safe}")
}

# Prompt helper
confirm_action() {
  local prompt_msg=$1
  if [[ "$AUTO_CONFIRM" == true ]]; then
    return 0
  fi
  echo ""
  read -r -p "$prompt_msg [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Force cleanup of K10 artifacts for this restore attempt
force_cleanup() {
  local k10_ns
  k10_ns=$(get_k10_namespace)

  local msg="Force cleanup will delete K10 resources if present:\n  - TransformSet ${TRANSFORM_NAME} (namespace: ${k10_ns})\n  - RestoreAction ${RESTORE_ACTION_NAME} (namespace: ${TARGET_NAMESPACE})\nContinue?"
  if ! confirm_action "$msg"; then
    log_info "Force cleanup cancelled by user"
    return 0
  fi

  # Delete TransformSet only when we're managing transforms (no custom file provided)
  if [[ -z "$TRANSFORM_FILE" ]]; then
    kubectl delete transformset "${TRANSFORM_NAME}" -n "${k10_ns}" --ignore-not-found || true
  fi
  kubectl delete restoreaction "${RESTORE_ACTION_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found || true

  return 0
}

# Get restore point details
get_rpc_details() {
  local rpc_name=$1
  kubectl get restorepointcontent "$rpc_name" -A -o json 2>/dev/null || echo '{}'
}

# Initialize restore context from restore point
# Note: This function sets global variables NAMESPACE, TARGET_NAMESPACE, and VM_NAME
# if they are not already set by command line arguments.
initialize_restore_context_from_rpc() {
  local rpc_json=$1

  local vm_name namespace
  vm_name=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appName" // ""')
  namespace=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appNamespace" // ""')

  if [[ -z "$vm_name" ]]; then
    log_error "Could not extract VM name from restore point"
    return 1
  fi

  # Set namespace if not provided
  if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE="$namespace"
  fi

  # Set target namespace if not provided
  if [[ -z "$TARGET_NAMESPACE" ]]; then
    TARGET_NAMESPACE="$NAMESPACE"
  fi

  # Set VM name if not provided
  if [[ -z "$VM_NAME" ]]; then
    VM_NAME="$vm_name"
  fi

  log_info "VM: ${VM_NAME}"
  log_info "Source Namespace: ${NAMESPACE}"
  log_info "Target Namespace: ${TARGET_NAMESPACE}"

  return 0
}

# Get DataVolumes from restore point
get_datavolumes_from_rpc() {
  local rpc_json=$1
  echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
    {
      name: .resource.name,
      size: (.artifact.spec.pvc.resources.requests.storage // "Unknown"),
      hasSnapshot: (.volumeSnapshot != null)
    }
  ' 2>/dev/null
}

# Validate restore prerequisites
validate_restore() {
  local rpc_json=$1
  local errors=0

  print_header "VALIDATION"

  # Check VM exists in restore point
  local datavolumes
  datavolumes=$(get_datavolumes_from_rpc "$rpc_json")
  local dv_count
  dv_count=$(echo "$datavolumes" | jq -s 'length')

  if [[ $dv_count -eq 0 ]]; then
    log_error "No DataVolumes found in restore point"
    ((errors++))
  else
    log_success "Found ${dv_count} DataVolume(s) in restore point"
    echo "$datavolumes" | jq -r '. | "  - \(.name) (\(.size)) - Snapshot: \(.hasSnapshot)"'
  fi

  # Check storage class
  if [[ -n "$NEW_STORAGE_CLASS" ]]; then
    if check_storage_class "$NEW_STORAGE_CLASS"; then
      ((errors+=0))
    else
      ((errors++))
    fi
  fi

  # Check target namespace
  if [[ "$TARGET_NAMESPACE" != "$NAMESPACE" ]] || [[ "$CREATE_NAMESPACE" == true ]]; then
    if namespace_exists "$TARGET_NAMESPACE"; then
      log_success "Target namespace ${TARGET_NAMESPACE} exists"
    elif [[ "$CREATE_NAMESPACE" == true ]]; then
      log_info "Target namespace ${TARGET_NAMESPACE} will be created"
    else
      log_error "Target namespace ${TARGET_NAMESPACE} does not exist (use --create-namespace)"
      ((errors++))
    fi
  fi

  # Check for snapshot support
  check_snapshot_class || log_warning "VolumeSnapshotClass may not be configured"

  # Validate quota
  validate_namespace_capacity "$TARGET_NAMESPACE"

  if [[ $errors -gt 0 ]]; then
    log_error "Validation failed with ${errors} error(s)"
    return 1
  fi

  log_success "All validations passed"
  return 0
}

# Generate restore plan
generate_restore_plan() {
  local rpc_json=$1

  print_header "RESTORE PLAN"

  echo "1. Prepare target environment:"
  if [[ "$CREATE_NAMESPACE" == true ]] && ! namespace_exists "$TARGET_NAMESPACE"; then
    echo "   - Create namespace: ${TARGET_NAMESPACE}"
  fi

  if [[ -n "$TRANSFORM_FILE" ]]; then
    echo "   - Apply custom transforms from: ${TRANSFORM_FILE}"
  else
    echo "   - Generate and apply VM-specific transforms"
  fi

  echo ""
  echo "2. Restore resources:"

  local datavolumes
  datavolumes=$(get_datavolumes_from_rpc "$rpc_json")
  echo "$datavolumes" | jq -r '. | "   - DataVolume: \(.name)"'

  echo "   - VirtualMachine: ${VM_NAME}"

  echo ""
  echo "3. Post-restore actions:"
  if [[ "$NO_START" == true ]]; then
    echo "   - VM will remain stopped (--no-start)"
  else
    echo "   - VM will start automatically"
  fi

  echo ""
  echo "Transform settings:"
  echo "   - New MAC addresses: ${NEW_MAC}"
  [[ -n "$NEW_STORAGE_CLASS" ]] && echo "   - Storage class: ${NEW_STORAGE_CLASS}"
  [[ -n "$RESIZE_DISK" ]] && echo "   - Resize disk: ${RESIZE_DISK}"

  echo ""
}

# Create transforms for restore
create_restore_transforms() {
  local transform_name transform_output
  # Use precomputed transform name for consistency
  if [[ -z "${TRANSFORM_NAME:-}" ]]; then
    compute_restore_names
  fi
  transform_name="$TRANSFORM_NAME"
  transform_output="/tmp/${transform_name}.yaml"

  log_info "Generating transforms (name: ${transform_name})..."

  local transform_args=(
    "--restore-point" "$RESTORE_POINT"
    "--output" "$transform_output"
    "--transform-name" "$transform_name"
  )

  [[ -n "$NEW_STORAGE_CLASS" ]] && transform_args+=("--new-storage-class" "$NEW_STORAGE_CLASS")
  [[ -n "$TARGET_NAMESPACE" ]] && [[ "$TARGET_NAMESPACE" != "$NAMESPACE" ]] && transform_args+=("--new-namespace" "$TARGET_NAMESPACE")
  [[ "$NEW_MAC" == true ]] && transform_args+=("--new-mac")
  [[ -n "$VM_NAME" ]] && transform_args+=("--vm-name" "$VM_NAME")

  if "${SCRIPT_DIR}/k10-vm-transform.sh" "${transform_args[@]}" > /dev/null 2>&1; then
    log_success "Transforms generated: ${transform_output}"
    echo "$transform_output"
  else
    log_error "Failed to generate transforms"
    return 1
  fi
}

# Apply transforms
apply_transforms() {
  local transform_file=$1

  log_info "Applying transforms..."

  if kubectl apply -f "$transform_file"; then
    log_success "Transforms applied"
    return 0
  else
    log_error "Failed to apply transforms"
    return 1
  fi
}

# Create RestoreAction
create_restore_action() {
  local rpc_name=$1
  local transform_name=$2

  # Use precomputed restore action name for consistency
  if [[ -z "${RESTORE_ACTION_NAME:-}" ]]; then
    compute_restore_names
  fi

  local k10_namespace
  k10_namespace=$(get_k10_namespace)

  # If RestoreAction already exists, skip creation (idempotent behavior)
  if kubectl get restoreaction "${RESTORE_ACTION_NAME}" -n "${TARGET_NAMESPACE}" &>/dev/null; then
    if [[ "$FORCE" == true ]]; then
      log_info "RestoreAction exists and --force set; deleting before re-create"
      kubectl delete restoreaction "${RESTORE_ACTION_NAME}" -n "${TARGET_NAMESPACE}" --ignore-not-found || true
    else
      log_info "RestoreAction already exists: ${RESTORE_ACTION_NAME}. Skipping creation."
      return 0
    fi
  fi

  log_info "Creating RestoreAction: ${RESTORE_ACTION_NAME}"

  if cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  name: ${RESTORE_ACTION_NAME}
  namespace: ${TARGET_NAMESPACE}
  labels:
    k10.kasten.io/appName: "${VM_NAME}"
    k10.kasten.io/appNamespace: "${TARGET_NAMESPACE}"
    k10-vm-utils.io/created-by: "k10-vm-restore"
  annotations:
    k10-vm-utils.io/source-restore-point: "${rpc_name}"
    k10-vm-utils.io/created-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
  subject:
    namespace: ${TARGET_NAMESPACE}
    restorePointContentName: ${rpc_name}
  transforms:
    - name: ${transform_name}
      namespace: ${k10_namespace}
EOF
  then
    log_success "RestoreAction created: ${RESTORE_ACTION_NAME}"
    return 0
  else
    log_error "Failed to create RestoreAction"
    return 1
  fi
}

# Monitor restore progress
monitor_restore() {
  local restore_action=$1
  local namespace=$2
  local timeout=600  # 10 minutes

  log_info "Monitoring restore progress (timeout: ${timeout}s)..."

  local elapsed=0
  local state=""

  while [[ $elapsed -lt $timeout ]]; do
    state=$(kubectl get restoreaction "$restore_action" -n "$namespace" \
      -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")

    case "$state" in
      "Complete")
        log_success "Restore completed successfully"
        return 0
        ;;
      "Failed")
        log_error "Restore failed"
        kubectl get restoreaction "$restore_action" -n "$namespace" -o yaml
        return 1
        ;;
      "Running"|"Pending")
        log_info "Restore state: ${state} (${elapsed}s elapsed)"
        ;;
      *)
        log_info "Waiting for restore to start... (${elapsed}s elapsed)"
        ;;
    esac

    sleep 10
    ((elapsed+=10))
  done

  log_error "Timeout waiting for restore to complete"
  return 1
}

# Post-restore actions
post_restore_actions() {
  log_info "Performing post-restore actions..."

  # Wait for VM to be created
  # Note: Extended timeout (300s) to account for DataVolume provisioning and CDI import operations
  # which can take longer than standard resource creation
  if wait_for_resource "vm" "$VM_NAME" "$TARGET_NAMESPACE" "" 300; then
    log_success "VirtualMachine created: ${VM_NAME}"
  else
    log_warning "VirtualMachine not created within timeout"
    return 1
  fi

  # Handle VM start/stop
  if [[ "$NO_START" == true ]]; then
    log_info "Ensuring VM is stopped..."
    kubectl patch vm "$VM_NAME" -n "$TARGET_NAMESPACE" \
      --type=json -p='[{"op":"replace","path":"/spec/running","value":false}]' 2>/dev/null || true
    log_success "VM configured to remain stopped"
  else
    log_info "VM will start automatically"
    # Wait for VMI if VM should be running
    # Note: Extended timeout (300s) to accommodate VM boot time, which includes:
    # - PVC binding, - Volume attachment, - Guest OS initialization
    sleep 10
    if wait_for_resource "vmi" "$VM_NAME" "$TARGET_NAMESPACE" "" 300; then
      log_success "VirtualMachineInstance is running"
    else
      log_warning "VirtualMachineInstance not running yet (may take time to boot)"
    fi
  fi

  return 0
}

# Verify restore
verify_restore() {
  print_header "RESTORE VERIFICATION"

  # Check VM exists
  if kubectl get vm "$VM_NAME" -n "$TARGET_NAMESPACE" &>/dev/null; then
    log_success "VM exists: ${VM_NAME}"
  else
    log_error "VM not found: ${VM_NAME}"
    return 1
  fi

  # Check DataVolumes
  local datavolumes
  datavolumes=$(kubectl get vm "$VM_NAME" -n "$TARGET_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.volumes[*].dataVolume.name}' 2>/dev/null || echo "")

  if [[ -n "$datavolumes" ]]; then
    log_info "Checking DataVolumes..."
    for dv in $datavolumes; do
      local status
      status=$(get_resource_status "datavolume" "$dv" "$TARGET_NAMESPACE")
      if [[ "$status" == "Succeeded" ]]; then
        log_success "  DataVolume ${dv}: ${status}"
      else
        log_warning "  DataVolume ${dv}: ${status}"
      fi
    done
  fi

  # Check PVCs
  log_info "Checking PVCs..."
  for dv in $datavolumes; do
    local pvc
    pvc=$(get_pvc_for_datavolume "$dv" "$TARGET_NAMESPACE")
    if [[ -n "$pvc" ]]; then
      local status
      status=$(get_resource_status "pvc" "$pvc" "$TARGET_NAMESPACE")
      if [[ "$status" == "Bound" ]]; then
        log_success "  PVC ${pvc}: ${status}"
      else
        log_warning "  PVC ${pvc}: ${status}"
      fi
    fi
  done

  # Check VM state
  local vm_state
  vm_state=$(get_vm_state "$VM_NAME" "$TARGET_NAMESPACE")
  log_info "VM State: ${vm_state}"

  log_success "Restore verification completed"
  return 0
}

# Confirm restore
confirm_restore() {
  if [[ "$AUTO_CONFIRM" == true ]]; then
    return 0
  fi

  echo ""
  read -r -p "Proceed with restore? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      log_info "Restore cancelled by user"
      return 1
      ;;
  esac
}

# Execute restore
execute_restore() {
  local rpc_json=$1

  # Ensure target namespace exists
  if [[ "$CREATE_NAMESPACE" == true ]]; then
    ensure_namespace "$TARGET_NAMESPACE" true
  else
    if ! namespace_exists "$TARGET_NAMESPACE"; then
      log_error "Target namespace ${TARGET_NAMESPACE} does not exist"
      return 1
    fi
  fi

  # If VM already exists
  if kubectl get vm "$VM_NAME" -n "$TARGET_NAMESPACE" &>/dev/null; then
    if [[ "$CLONE_ON_CONFLICT" == true ]]; then
      local new_name
      new_name=$(resolve_clone_name "$VM_NAME" "$TARGET_NAMESPACE")
      log_info "Target VM exists; cloning restore to VM name: ${new_name}"
      VM_NAME="$new_name"
      compute_restore_names
    else
      log_info "VM ${VM_NAME} already exists in ${TARGET_NAMESPACE}. Skipping restore and verifying..."
      verify_restore
      return 0
    fi
  fi

  # Create or use custom transforms
  local transform_file
  if [[ -n "$TRANSFORM_FILE" ]]; then
    transform_file="$TRANSFORM_FILE"
    log_info "Using custom transform file: ${transform_file}"
  else
    if ! transform_file=$(create_restore_transforms); then
      return 1
    fi
  fi

  # Apply transforms
  if ! apply_transforms "$transform_file"; then
    return 1
  fi

  # Extract transform name
  local transform_name
  transform_name=$(grep "^  name:" "$transform_file" | head -1 | awk '{print $2}')

  # Create RestoreAction
  if ! create_restore_action "$RESTORE_POINT" "$transform_name"; then
    return 1
  fi

  # Monitor restore
  if ! monitor_restore "$RESTORE_ACTION_NAME" "$TARGET_NAMESPACE"; then
    return 1
  fi

  # Post-restore actions
  if ! post_restore_actions; then
    log_warning "Some post-restore actions failed"
  fi

  # Verify restore
  verify_restore

  return 0
}

# Main function
main() {
  parse_args "$@"

  print_header "Kasten K10 VM Restore Utility v1.0.0"

  # Validate prerequisites
  if [[ "$DRY_RUN" == false ]] && [[ "$VALIDATE" == false ]]; then
    if ! validate_vm_restore_prerequisites; then
      exit 1
    fi
  fi

  # Get restore point details
  log_info "Fetching restore point details..."
  local rpc_json
  rpc_json=$(get_rpc_details "$RESTORE_POINT")

  if [[ $(echo "$rpc_json" | jq -r '.metadata.name // ""') == "" ]]; then
    log_error "Restore point not found: ${RESTORE_POINT}"
    exit 1
  fi

  log_success "Restore point found: ${RESTORE_POINT}"

  # Extract RPC information
  if ! initialize_restore_context_from_rpc "$rpc_json"; then
    exit 1
  fi

  # If VM already exists and clone requested, resolve a clone name early (affects plan and transforms)
  if kubectl get vm "$VM_NAME" -n "$TARGET_NAMESPACE" &>/dev/null && [[ "$CLONE_ON_CONFLICT" == true ]]; then
    VM_NAME=$(resolve_clone_name "$VM_NAME" "$TARGET_NAMESPACE")
    log_info "Using clone VM name: ${VM_NAME}"
  fi

  # Compute names and optionally perform force cleanup of previous artifacts
  compute_restore_names
  if [[ "$FORCE" == true ]]; then
    force_cleanup || true
  fi

  # Validate restore
  if [[ "$VALIDATE" == true ]] || [[ "$DRY_RUN" == true ]]; then
    if ! validate_restore "$rpc_json"; then
      exit 1
    fi
  fi

  # Generate restore plan
  generate_restore_plan "$rpc_json"

  # Dry run mode - exit here
  if [[ "$DRY_RUN" == true ]]; then
    log_info "Dry-run mode: No changes will be made"
    exit 0
  fi

  # Validate only mode - exit here
  if [[ "$VALIDATE" == true ]]; then
    log_success "Validation completed successfully"
    exit 0
  fi

  # Confirm restore
  if ! confirm_restore; then
    exit 0
  fi

  # Execute restore
  print_header "EXECUTING RESTORE"

  if execute_restore "$rpc_json"; then
    print_header "RESTORE COMPLETED SUCCESSFULLY"
    log_success "VM ${VM_NAME} has been restored to namespace ${TARGET_NAMESPACE}"
    echo ""
    log_info "Next steps:"
    echo "  - Verify VM: kubectl get vm ${VM_NAME} -n ${TARGET_NAMESPACE}"
    echo "  - Check VMI: kubectl get vmi ${VM_NAME} -n ${TARGET_NAMESPACE}"
    echo "  - View events: kubectl get events -n ${TARGET_NAMESPACE} --sort-by='.lastTimestamp'"
    exit 0
  else
    print_header "RESTORE FAILED"
    log_error "VM restore failed. Check the logs above for details."
    exit 1
  fi
}

# Run main function
main "$@"
