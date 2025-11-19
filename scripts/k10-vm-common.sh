#!/bin/bash

# Kasten K10 VM Recovery Utility - Common Functions
# Version: 1.0.0
# Description: Shared utility functions for VM discovery, restore, and transform scripts

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if resource is a VM
is_virtual_machine() {
  local app_name=$1
  local namespace=$2
  kubectl get vm "${app_name}" -n "${namespace}" &>/dev/null || return $?
}

# Get VM disk information
get_vm_disks() {
  local vm_name=$1
  local namespace=$2
  kubectl get vm "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.volumes[*].dataVolume.name}' 2>/dev/null || echo ""
}

# Check if VM was frozen during backup
check_vm_freeze_annotation() {
  local vm_name=$1
  local namespace=$2
  kubectl get vm "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.metadata.annotations.k10\.kasten\.io/freezeVM}' 2>/dev/null || echo ""
}

# Validate OpenShift Virtualization is installed
check_kubevirt_installed() {
  if ! kubectl get crd virtualmachines.kubevirt.io &>/dev/null; then
    log_error "OpenShift Virtualization not installed (VirtualMachine CRD not found)"
    return 1
  fi
  log_success "OpenShift Virtualization is installed"
  return 0
}

# Check CDI is installed
check_cdi_installed() {
  if ! kubectl get crd datavolumes.cdi.kubevirt.io &>/dev/null; then
    log_error "CDI (Containerized Data Importer) not installed (DataVolume CRD not found)"
    return 1
  fi
  log_success "CDI is installed"
  return 0
}

# Get DataVolume → PVC mapping
get_pvc_for_datavolume() {
  local dv_name=$1
  local namespace=$2
  kubectl get dv "${dv_name}" -n "${namespace}" \
    -o jsonpath='{.status.claimName}' 2>/dev/null || echo ""
}

# Wait for VM to be ready after restore
wait_for_vm_ready() {
  local vm_name=$1
  local namespace=$2
  local timeout=${3:-300}  # 5 minutes default

  log_info "Waiting for VM ${vm_name} to be ready (timeout: ${timeout}s)..."
  if kubectl wait --for=condition=Ready \
    vm/"${vm_name}" -n "${namespace}" \
    --timeout="${timeout}s" 2>/dev/null; then
    log_success "VM ${vm_name} is ready"
    return 0
  else
    log_warning "VM ${vm_name} did not become ready within ${timeout}s"
    return 1
  fi
}

# Check VM guest agent availability
check_vm_guest_agent() {
  local vm_name=$1
  local namespace=$2
  local guest_os
  guest_os=$(kubectl get vmi "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.status.guestOSInfo.id}' 2>/dev/null || echo "")

  if [[ -n "$guest_os" ]]; then
    log_success "Guest agent is available (OS: ${guest_os})"
    return 0
  else
    log_info "Guest agent not available or VMI not running"
    return 1
  fi
}

# Get VM state (running/stopped)
get_vm_state() {
  local vm_name=$1
  local namespace=$2
  local running
  running=$(kubectl get vm "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.spec.running}' 2>/dev/null || echo "false")

  if [[ "$running" == "true" ]]; then
    echo "Running"
  else
    echo "Stopped"
  fi
}

# Get VM CPU and memory allocation
get_vm_resources() {
  local vm_name=$1
  local namespace=$2
  local cpu memory

  cpu=$(kubectl get vm "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.domain.cpu.cores}' 2>/dev/null || echo "N/A")
  memory=$(kubectl get vm "${vm_name}" -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.domain.resources.requests.memory}' 2>/dev/null || echo "N/A")

  echo "CPU: ${cpu}, Memory: ${memory}"
}

# Check if namespace exists
namespace_exists() {
  local namespace=$1
  kubectl get namespace "${namespace}" &>/dev/null
}

# Create namespace if it doesn't exist
ensure_namespace() {
  local namespace=$1
  local create_if_missing=${2:-false}

  if namespace_exists "${namespace}"; then
    log_success "Namespace ${namespace} exists"
    return 0
  else
    if [[ "$create_if_missing" == "true" ]]; then
      log_info "Creating namespace ${namespace}..."
      kubectl create namespace "${namespace}"
      kubectl label namespace "${namespace}" \
        "k10-vm-utils.io/created-by=vm-recovery-utility" \
        "k10-vm-utils.io/created-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_success "Namespace ${namespace} created"
      return 0
    else
      log_error "Namespace ${namespace} does not exist"
      return 1
    fi
  fi
}

# Validate storage class exists
check_storage_class() {
  local storage_class=$1

  if kubectl get storageclass "${storage_class}" &>/dev/null; then
    log_success "StorageClass ${storage_class} exists"
    return 0
  else
    log_error "StorageClass ${storage_class} not found"
    return 1
  fi
}

# Check VolumeSnapshotClass availability
check_snapshot_class() {
  local snapshot_class=${1:-""}

  if [[ -z "$snapshot_class" ]]; then
    # Check for any VolumeSnapshotClass with K10 annotation
    if kubectl get volumesnapshotclass \
      -l "k10.kasten.io/is-snapshot-class=true" \
      -o name 2>/dev/null | grep -q .; then
      log_success "VolumeSnapshotClass with K10 annotation found"
      return 0
    else
      log_warning "No VolumeSnapshotClass with k10.kasten.io/is-snapshot-class=true annotation found"
      return 1
    fi
  else
    if kubectl get volumesnapshotclass "${snapshot_class}" &>/dev/null; then
      log_success "VolumeSnapshotClass ${snapshot_class} exists"
      return 0
    else
      log_error "VolumeSnapshotClass ${snapshot_class} not found"
      return 1
    fi
  fi
}

# Validate namespace resource quotas
validate_namespace_capacity() {
  local namespace=$1

  log_info "Checking namespace ${namespace} resource quotas..."

  # This is a basic check - in production, you'd want more sophisticated quota checking
  if kubectl get resourcequota -n "${namespace}" &>/dev/null; then
    log_info "Resource quotas exist in namespace ${namespace}"
    kubectl get resourcequota -n "${namespace}" -o wide
  else
    log_info "No resource quotas defined in namespace ${namespace}"
  fi

  return 0
}

# Get K10 namespace
get_k10_namespace() {
  local k10_ns
  k10_ns=$(kubectl get namespace -o json | \
    jq -r '.items[] | select(.metadata.name | test("kasten|k10")) | .metadata.name' | \
    head -1 || echo "kasten-io")

  if [[ -z "$k10_ns" ]]; then
    k10_ns="kasten-io"
  fi

  echo "$k10_ns"
}

# Check if K10 is installed
check_k10_installed() {
  local k10_ns
  k10_ns=$(get_k10_namespace)

  if namespace_exists "${k10_ns}"; then
    if kubectl get crd restorepointcontents.apps.kio.kasten.io &>/dev/null; then
      log_success "Kasten K10 is installed in namespace ${k10_ns}"
      return 0
    fi
  fi

  log_error "Kasten K10 not found"
  return 1
}

# Get restore point details
get_restore_point_details() {
  local restore_point=$1
  local namespace=${2:-""}

  if [[ -n "$namespace" ]]; then
    kubectl get restorepointcontent "${restore_point}" -n "${namespace}" \
      -o json 2>/dev/null || echo "{}"
  else
    kubectl get restorepointcontent "${restore_point}" -A \
      -o json 2>/dev/null | jq '.items[0] // {}' || echo "{}"
  fi
}

# Extract VM name from restore point
get_vm_from_restore_point() {
  local restore_point=$1
  local details

  details=$(get_restore_point_details "${restore_point}")
  echo "$details" | jq -r '.metadata.labels."k10.kasten.io/appName" // ""'
}

# Check if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Validate required tools are installed
validate_prerequisites() {
  local missing_tools=()

  if ! command_exists kubectl; then
    missing_tools+=("kubectl")
  fi

  if ! command_exists jq; then
    missing_tools+=("jq")
  fi

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing_tools[*]}"
    log_error "Please install the required tools and try again"
    return 1
  fi

  log_success "All required tools are installed (kubectl, jq)"
  return 0
}

# Validate all prerequisites for VM restore
validate_vm_restore_prerequisites() {
  local errors=0

  log_info "Validating prerequisites..."

  # Check required tools
  if ! validate_prerequisites; then
    ((errors++))
  fi

  # Check K10 installation
  if ! check_k10_installed; then
    ((errors++))
  fi

  # Check KubeVirt installation
  if ! check_kubevirt_installed; then
    ((errors++))
  fi

  # Check CDI installation
  if ! check_cdi_installed; then
    ((errors++))
  fi

  # Check VolumeSnapshotClass
  check_snapshot_class || log_warning "Consider configuring VolumeSnapshotClass for better performance"

  if [[ $errors -gt 0 ]]; then
    log_error "Prerequisite validation failed with ${errors} error(s)"
    return 1
  fi

  log_success "All prerequisites validated successfully"
  return 0
}

# Generate timestamp for naming
generate_timestamp() {
  date -u +%Y%m%d%H%M%S
}

# Sanitize name for Kubernetes resource
sanitize_k8s_name() {
  local name=$1
  # Convert to lowercase, replace invalid characters with hyphens, trim length
  echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63 | sed 's/-$//'
}

# Parse size string (e.g., "30Gi" -> 30)
parse_size() {
  local size=$1
  # Remove all non-numeric characters
  echo "${size//[^0-9]/}"
}

# Wait for resource with timeout
wait_for_resource() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3
  local condition=${4:-""}
  local timeout=${5:-300}

  log_info "Waiting for ${resource_type}/${resource_name} in namespace ${namespace}..."

  if [[ -n "$condition" ]]; then
    if kubectl wait --for="${condition}" \
      "${resource_type}/${resource_name}" -n "${namespace}" \
      --timeout="${timeout}s" 2>/dev/null; then
      log_success "${resource_type}/${resource_name} is ready"
      return 0
    fi
  else
    # Just wait for resource to exist
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      if kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null; then
        log_success "${resource_type}/${resource_name} exists"
        return 0
      fi
      sleep 5
      ((elapsed+=5))
    done
  fi

  log_error "Timeout waiting for ${resource_type}/${resource_name}"
  return 1
}

# Get resource status
get_resource_status() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3

  kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
}

# Print separator line
print_separator() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print header
print_header() {
  local title=$1
  echo ""
  print_separator
  echo -e "${BLUE}${title}${NC}"
  print_separator
  echo ""
}

# Export functions for use in other scripts
export -f log_info log_success log_warning log_error
export -f is_virtual_machine get_vm_disks check_vm_freeze_annotation
export -f check_kubevirt_installed check_cdi_installed
export -f get_pvc_for_datavolume wait_for_vm_ready check_vm_guest_agent
export -f get_vm_state get_vm_resources
export -f namespace_exists ensure_namespace
export -f check_storage_class check_snapshot_class validate_namespace_capacity
export -f get_k10_namespace check_k10_installed
export -f get_restore_point_details get_vm_from_restore_point
export -f command_exists validate_prerequisites validate_vm_restore_prerequisites
export -f generate_timestamp sanitize_k8s_name parse_size
export -f wait_for_resource get_resource_status
export -f print_separator print_header

log_info "Common functions loaded successfully"
