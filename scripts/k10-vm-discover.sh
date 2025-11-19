#!/bin/bash

# Kasten K10 VM Recovery Utility - VM Discovery Script
# Version: 1.0.0
# Description: Find and list VM restore points with disk details

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k10-vm-common.sh
source "${SCRIPT_DIR}/k10-vm-common.sh"

# Default values
VM_NAME=""
NAMESPACE=""
LABEL_SELECTOR=""
SHOW_DISKS=true
VM_ONLY=true
DELETED_ONLY=false
OUTPUT_FORMAT="text"  # text or json

# Usage function
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Discover Virtual Machine restore points in Kasten K10.

OPTIONS:
  --vm <name>              VM name to search for
  --namespace <ns>         Namespace to search in
  --label <selector>       Label selector (e.g., "os=rhel,tier=frontend")
  --all                    Show all VMs across all namespaces
  --show-disks             Show disk information (default: true)
  --vm-only                Filter out non-VM workloads (default: true)
  --deleted-only           Show only deleted VMs with restore points
  --output <format>        Output format: text or json (default: text)
  --help                   Show this help message

EXAMPLES:
  # Discover specific VM
  $0 --vm rhel9-vm --namespace vms-prod

  # Discover all VMs with labels
  $0 --label "os=rhel,tier=frontend"

  # Discover all VMs with disk details
  $0 --all --show-disks

  # Find deleted VMs
  $0 --deleted-only

EOF
  exit 1
}

# Parse arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --vm)
        VM_NAME="$2"
        shift 2
        ;;
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --label)
        LABEL_SELECTOR="$2"
        shift 2
        ;;
      --all)
        # All VMs flag - filters are empty so all will be shown
        shift
        ;;
      --show-disks)
        SHOW_DISKS=true
        shift
        ;;
      --vm-only)
        VM_ONLY=true
        shift
        ;;
      --deleted-only)
        DELETED_ONLY=true
        shift
        ;;
      --output)
        OUTPUT_FORMAT="$2"
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
}

# Get all restore point contents
get_restore_point_contents() {
  local filter_args=()

  if [[ -n "$VM_NAME" && -n "$NAMESPACE" ]]; then
    filter_args=(-l "k10.kasten.io/appName=${VM_NAME},k10.kasten.io/appNamespace=${NAMESPACE}")
  elif [[ -n "$NAMESPACE" ]]; then
    filter_args=(-n "${NAMESPACE}")
  elif [[ -n "$LABEL_SELECTOR" ]]; then
    filter_args=(-l "${LABEL_SELECTOR}")
  else
    filter_args=(-A)
  fi

  kubectl get restorepointcontents.apps.kio.kasten.io "${filter_args[@]}" -o json 2>/dev/null || echo '{"items":[]}'
}

# Check if restore point is for a VM
is_vm_restore_point() {
  local rpc_json=$1

  # Check if the application is a VirtualMachine
  local app_name
  local app_namespace
  app_name=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appName" // ""')
  app_namespace=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appNamespace" // ""')

  if [[ -z "$app_name" || -z "$app_namespace" ]]; then
    return 1
  fi

  # Check if VM exists (for active VMs) or if RPC contains VM resources
  if is_virtual_machine "$app_name" "$app_namespace" 2>/dev/null; then
    return 0
  fi

  # For deleted VMs, check if RPC contains VirtualMachine resource
  local has_vm_resource
  has_vm_resource=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .resource.name' | head -1)

  [[ -n "$has_vm_resource" ]]
}

# Get disk information from restore point
get_disk_info() {
  local rpc_json=$1

  echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
    {
      name: .resource.name,
      size: (.artifact.metadata.spec.pvc.resources.requests.storage // "Unknown"),
      type: (if .artifact.volumeSnapshot then "CSI Snapshot" else "Export" end)
    }
  ' 2>/dev/null || echo '[]'
}

# Get VM state from restore point
get_vm_state_from_rpc() {
  local rpc_json=$1

  local running
  running=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .artifact.spec.running // false
  ' | head -1)

  if [[ "$running" == "true" ]]; then
    echo "Running"
  else
    echo "Stopped"
  fi
}

# Get VM resources from restore point
get_vm_resources_from_rpc() {
  local rpc_json=$1

  local cpu memory
  cpu=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .artifact.spec.template.spec.domain.cpu.cores // "N/A"
  ' | head -1)

  memory=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .artifact.spec.template.spec.domain.resources.requests.memory // "N/A"
  ' | head -1)

  echo "CPU: ${cpu}, Memory: ${memory}"
}

# Check MAC address preservation
check_mac_preservation() {
  local rpc_json=$1

  local mac_address
  mac_address=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .artifact.spec.template.spec.domain.devices.interfaces[]?.macAddress // ""
  ' | head -1)

  if [[ -n "$mac_address" ]]; then
    echo "Yes (${mac_address})"
  else
    echo "No"
  fi
}

# Check freeze annotation
check_freeze_annotation_rpc() {
  local rpc_json=$1

  local freeze
  freeze=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines") |
    .artifact.metadata.annotations."k10.kasten.io/freezeVM" // ""
  ' | head -1)

  if [[ "$freeze" == "true" ]]; then
    echo "k10.kasten.io/freezeVM=true"
  else
    echo "None"
  fi
}

# Get available restore methods
get_restore_methods() {
  local rpc_json=$1

  local has_snapshot has_export
  has_snapshot=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.artifacts[]? |
    select(.volumeSnapshot != null) | .resource.name
  ' | head -1)

  has_export=$(echo "$rpc_json" | jq -r '
    .status.restorePointContentDetails.exportData.enabled // false
  ')

  local methods=()
  [[ -n "$has_snapshot" ]] && methods+=("Snapshot")
  [[ "$has_export" == "true" ]] && methods+=("Export")

  echo "[$(IFS=,; echo "${methods[*]}")]"
}

# Format VM restore point for text output
format_vm_restore_point_text() {
  local rpc_json=$1
  local rpc_name vm_name vm_namespace vm_state vm_resources mac_preserved freeze_annotation restore_methods

  rpc_name=$(echo "$rpc_json" | jq -r '.metadata.name')
  vm_name=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appName"')
  vm_namespace=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appNamespace"')
  vm_state=$(get_vm_state_from_rpc "$rpc_json")
  vm_resources=$(get_vm_resources_from_rpc "$rpc_json")
  mac_preserved=$(check_mac_preservation "$rpc_json")
  freeze_annotation=$(check_freeze_annotation_rpc "$rpc_json")
  restore_methods=$(get_restore_methods "$rpc_json")

  echo "Name: ${rpc_name}"
  echo "├─ VM: ${vm_name}"
  echo "├─ Namespace: ${vm_namespace}"
  echo "├─ State: ${vm_state}"
  echo "├─ Resources: ${vm_resources}"

  if [[ "$SHOW_DISKS" == true ]]; then
    echo "├─ Disks:"
    local disks_json
    disks_json=$(get_disk_info "$rpc_json")

    if [[ $(echo "$disks_json" | jq -s 'length') -gt 0 ]]; then
      echo "$disks_json" | jq -r '. | "│  ├─ \(.name) (\(.size)) - \(.type)"'
    else
      echo "│  └─ No disks found"
    fi
  fi

  echo "├─ MAC Preserved: ${mac_preserved}"
  echo "├─ Freeze Annotation: ${freeze_annotation}"
  echo "└─ Restore Methods: ${restore_methods}"
  echo ""
}

# Format VM restore point for JSON output
format_vm_restore_point_json() {
  local rpc_json=$1

  local rpc_name vm_name vm_namespace vm_state vm_resources mac_preserved freeze_annotation restore_methods disks_json

  rpc_name=$(echo "$rpc_json" | jq -r '.metadata.name')
  vm_name=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appName"')
  vm_namespace=$(echo "$rpc_json" | jq -r '.metadata.labels."k10.kasten.io/appNamespace"')
  vm_state=$(get_vm_state_from_rpc "$rpc_json")
  vm_resources=$(get_vm_resources_from_rpc "$rpc_json")
  mac_preserved=$(check_mac_preservation "$rpc_json")
  freeze_annotation=$(check_freeze_annotation_rpc "$rpc_json")
  restore_methods=$(get_restore_methods "$rpc_json")
  disks_json=$(get_disk_info "$rpc_json")

  jq -n \
    --arg name "$rpc_name" \
    --arg vm_name "$vm_name" \
    --arg vm_namespace "$vm_namespace" \
    --arg vm_state "$vm_state" \
    --arg vm_resources "$vm_resources" \
    --arg mac_preserved "$mac_preserved" \
    --arg freeze_annotation "$freeze_annotation" \
    --arg restore_methods "$restore_methods" \
    --argjson disks "$disks_json" \
    '{
      name: $name,
      vm: $vm_name,
      namespace: $vm_namespace,
      state: $vm_state,
      resources: $vm_resources,
      disks: $disks,
      macPreserved: $mac_preserved,
      freezeAnnotation: $freeze_annotation,
      restoreMethods: $restore_methods
    }'
}

# Check if VM is deleted
is_vm_deleted() {
  local vm_name=$1
  local namespace=$2

  ! kubectl get vm "$vm_name" -n "$namespace" &>/dev/null
}

# Main discovery function
discover_vms() {
  log_info "Discovering VM restore points..."

  local rpcs_json
  rpcs_json=$(get_restore_point_contents)

  local total_rpcs
  total_rpcs=$(echo "$rpcs_json" | jq '.items | length')

  if [[ $total_rpcs -eq 0 ]]; then
    log_warning "No restore points found"
    return 0
  fi

  log_info "Found ${total_rpcs} restore point(s), filtering for VMs..."

  local vm_rpcs_json
  if [[ "$VM_ONLY" == true ]]; then
    # Fetch all active VMs once to avoid N+1 kubectl calls
    local active_vms_json
    active_vms_json=$(kubectl get vm -A -o json 2>/dev/null || echo '{"items":[]}')
    # Build a set of "namespace/name" for quick lookup
    declare -A ACTIVE_VMS_SET
    while IFS= read -r vm; do
      local ns name
      ns=$(echo "$vm" | jq -r '.metadata.namespace')
      name=$(echo "$vm" | jq -r '.metadata.name')
      ACTIVE_VMS_SET["$ns/$name"]=1
    done < <(echo "$active_vms_json" | jq -c '.items[]')

    # Now filter restore points: include if they have a VM artifact OR reference an active VM
    vm_rpcs_json=""
    while IFS= read -r rpc; do
      # Check for VM artifact
      local has_vm_artifact
      has_vm_artifact=$(echo "$rpc" | jq '
        .status.restorePointContentDetails.artifacts[]? |
        select(.resource.group == "kubevirt.io" and .resource.resource == "virtualmachines")
      ' | wc -l)

      # Get VM name and namespace from labels
      local vm_name vm_namespace
      vm_name=$(echo "$rpc" | jq -r '.metadata.labels."k10.kasten.io/appName"')
      vm_namespace=$(echo "$rpc" | jq -r '.metadata.labels."k10.kasten.io/appNamespace"')

      # Check if VM is active
      local is_active_vm=0
      if [[ -n "$vm_name" && -n "$vm_namespace" && "${ACTIVE_VMS_SET["$vm_namespace/$vm_name"]+isset}" ]]; then
        is_active_vm=1
      fi

      if [[ "$has_vm_artifact" -gt 0 || "$is_active_vm" -eq 1 ]]; then
        vm_rpcs_json+="$rpc"$'\n'
      fi
    done < <(echo "$rpcs_json" | jq -c '.items[]')
  else
    vm_rpcs_json=$(echo "$rpcs_json" | jq -c '.items[]')
  fi

  local vm_count=0
  local vm_restore_points=()

  # Process filtered restore points
  while IFS= read -r rpc; do
    [[ -z "$rpc" ]] && continue

    local vm_name vm_namespace
    vm_name=$(echo "$rpc" | jq -r '.metadata.labels."k10.kasten.io/appName"')
    vm_namespace=$(echo "$rpc" | jq -r '.metadata.labels."k10.kasten.io/appNamespace"')

    # Check if filtering for deleted VMs
    if [[ "$DELETED_ONLY" == true ]]; then
      if ! is_vm_deleted "$vm_name" "$vm_namespace"; then
        continue
      fi
    fi

    vm_restore_points+=("$rpc")
    ((vm_count++))
  done <<< "$vm_rpcs_json"

  if [[ $vm_count -eq 0 ]]; then
    if [[ "$DELETED_ONLY" == true ]]; then
      log_warning "No deleted VMs with restore points found"
    else
      log_warning "No VM restore points found"
    fi
    return 0
  fi

  # Output results
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "{"
    echo "  \"total\": ${vm_count},"
    echo "  \"restorePoints\": ["
    local first=true
    for rpc in "${vm_restore_points[@]}"; do
      if [[ "$first" == true ]]; then
        first=false
      else
        echo ","
      fi
      format_vm_restore_point_json "$rpc" | sed 's/^/    /'
    done
    echo ""
    echo "  ]"
    echo "}"
  else
    print_header "VM RESTORE POINTS FOUND: ${vm_count}"

    for rpc in "${vm_restore_points[@]}"; do
      format_vm_restore_point_text "$rpc"
    done

    print_separator
  fi
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

  # Discover VMs
  discover_vms
}

# Run main function
main "$@"
