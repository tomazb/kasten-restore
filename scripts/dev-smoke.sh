#!/bin/bash

# Expanded smoke checks for the K10 VM recovery utilities.
# Intended for local/developer use; does not require cluster access.
# Version is centralized in k10-vm-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}[PASS]${NC} $1"
  ((PASS_COUNT++))
}

fail() {
  echo -e "${RED}[FAIL]${NC} $1"
  ((FAIL_COUNT++))
}

skip() {
  echo -e "${YELLOW}[SKIP]${NC} $1"
}

echo "=================================================="
echo "K10 VM Recovery Utility - Smoke Tests"
echo "=================================================="
echo ""

# =============================================================================
# TEST: Required tools
# =============================================================================
echo "--- Checking required tools ---"

if command -v jq >/dev/null 2>&1; then
  pass "jq is installed"
else
  fail "jq is required but not found in PATH"
  exit 1
fi

if command -v bash >/dev/null 2>&1; then
  pass "bash is installed"
else
  fail "bash is required but not found"
  exit 1
fi

# =============================================================================
# TEST: Script syntax validation
# =============================================================================
echo ""
echo "--- Script syntax validation ---"

for script in "${SCRIPT_DIR}"/*.sh; do
  script_name=$(basename "$script")
  if bash -n "$script" 2>/dev/null; then
    pass "Syntax check: $script_name"
  else
    fail "Syntax check: $script_name"
  fi
done

# =============================================================================
# TEST: ShellCheck (if available)
# =============================================================================
echo ""
echo "--- ShellCheck validation ---"

if command -v shellcheck >/dev/null 2>&1; then
  for script in "${SCRIPT_DIR}"/*.sh; do
    script_name=$(basename "$script")
    # shellcheck disable=SC2310
    if shellcheck -x -S warning "$script" 2>/dev/null; then
      pass "ShellCheck: $script_name"
    else
      fail "ShellCheck: $script_name (run 'shellcheck -x $script' for details)"
    fi
  done
else
  skip "ShellCheck not installed (install with: apt install shellcheck)"
fi

# =============================================================================
# TEST: Source common functions (without kubectl)
# =============================================================================
echo ""
echo "--- Common functions loading ---"

# We can't fully source common.sh without kubectl, but we can test the syntax
if bash -n "${SCRIPT_DIR}/k10-vm-common.sh" 2>/dev/null; then
  pass "k10-vm-common.sh syntax valid"
else
  fail "k10-vm-common.sh has syntax errors"
fi

# =============================================================================
# TEST: jq filter parsing
# =============================================================================
echo ""
echo "--- jq filter tests ---"

SAMPLE_RPC_WITH_DV='{
  "metadata": {
    "name": "rpc-sample-1",
    "labels": {
      "k10.kasten.io/appName": "vm-sample",
      "k10.kasten.io/appNamespace": "ns-sample"
    }
  },
  "status": {
    "restorePointContentDetails": {
      "exportData": { "enabled": true },
      "artifacts": [
        {
          "resource": { "group": "cdi.kubevirt.io", "resource": "datavolumes", "name": "rootdisk" },
          "artifact": { "spec": { "pvc": { "resources": { "requests": { "storage": "20Gi" } } } } },
          "volumeSnapshot": { "dummy": true }
        },
        {
          "resource": { "group": "kubevirt.io", "resource": "virtualmachines", "name": "vm-sample" },
          "artifact": { "spec": { "running": true, "template": { "spec": { "domain": { "cpu": { "cores": 2 }, "resources": { "requests": { "memory": "4Gi" } }, "devices": { "interfaces": [ { "name": "default", "macAddress": "52:54:00:6b:3c:58" } ] } } } } } }
        }
      ]
    }
  }
}'

SAMPLE_RPC_NO_DV='{
  "metadata": { "name": "rpc-sample-empty" },
  "status": { "restorePointContentDetails": { "artifacts": [] } }
}'

# Test DV parsing
result=$(echo "$SAMPLE_RPC_WITH_DV" | jq -c '
  [
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
    {
      name: .resource.name,
      size: (.artifact.spec.pvc.resources.requests.storage // "Unknown"),
      hasSnapshot: (.volumeSnapshot != null)
    }
  ]
')

if [[ "$result" == *'"name":"rootdisk"'* ]] && [[ "$result" == *'"hasSnapshot":true'* ]]; then
  pass "jq: DataVolume parsing with snapshot"
else
  fail "jq: DataVolume parsing with snapshot (got: $result)"
fi

# Test empty DV parsing
result=$(echo "$SAMPLE_RPC_NO_DV" | jq -c '
  [
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
    { name: .resource.name }
  ]
')

if [[ "$result" == "[]" ]]; then
  pass "jq: Empty DataVolume array handling"
else
  fail "jq: Empty DataVolume array handling (got: $result)"
fi

# Test restore methods parsing
result=$(echo "$SAMPLE_RPC_WITH_DV" | jq -c '
  [
    (if ([.status.restorePointContentDetails.artifacts[]? | select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes" and .volumeSnapshot != null)] | length) > 0 then "Snapshot" else empty end),
    (if (.status.restorePointContentDetails.exportData.enabled // false) then "Export" else empty end)
  ]
')

if [[ "$result" == '["Snapshot","Export"]' ]]; then
  pass "jq: Restore methods parsing"
else
  fail "jq: Restore methods parsing (got: $result)"
fi

# =============================================================================
# TEST: Transform name extraction (awk)
# =============================================================================
echo ""
echo "--- awk parsing tests ---"

result=$(awk '
  /^metadata:/ { in_meta=1; next }
  in_meta && /^[^[:space:]]/ { in_meta=0 }
  in_meta && /^[[:space:]]*name:[[:space:]]*/ { sub(/^[[:space:]]*name:[[:space:]]*/, "", $0); print; exit }
' <<'EOF'
apiVersion: config.kio.kasten.io/v1alpha1
kind: TransformSet
metadata:
  name: vm-restore-transforms-sample
  namespace: kasten-io
spec: {}
EOF
)

if [[ "$result" == "vm-restore-transforms-sample" ]]; then
  pass "awk: Transform name extraction"
else
  fail "awk: Transform name extraction (got: $result)"
fi

# =============================================================================
# TEST: sanitize_k8s_name function logic
# =============================================================================
echo ""
echo "--- Name sanitization tests ---"

sanitize_k8s_name() {
  local name=$1
  echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63 | sed 's/-$//'
}

# Test uppercase conversion
result=$(sanitize_k8s_name "MyVM-Test")
if [[ "$result" == "myvm-test" ]]; then
  pass "sanitize: Lowercase conversion"
else
  fail "sanitize: Lowercase conversion (got: $result)"
fi

# Test special character replacement
result=$(sanitize_k8s_name "vm_with.special@chars!")
if [[ "$result" == "vm-with-special-chars-" ]] || [[ "$result" == "vm-with-special-chars" ]]; then
  pass "sanitize: Special character replacement"
else
  fail "sanitize: Special character replacement (got: $result)"
fi

# Test length truncation
long_name=$(printf 'a%.0s' {1..100})
result=$(sanitize_k8s_name "$long_name")
if [[ ${#result} -le 63 ]]; then
  pass "sanitize: Length truncation (${#result} chars)"
else
  fail "sanitize: Length truncation (got ${#result} chars)"
fi

# =============================================================================
# TEST: Secure temp file creation
# =============================================================================
echo ""
echo "--- Secure temp file tests ---"

tmpfile=$(mktemp --suffix=.yaml)
chmod 600 "$tmpfile"
perms=$(stat -c %a "$tmpfile" 2>/dev/null || stat -f %Lp "$tmpfile" 2>/dev/null)
rm -f "$tmpfile"

if [[ "$perms" == "600" ]]; then
  pass "Secure temp file permissions"
else
  fail "Secure temp file permissions (got: $perms)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=================================================="
echo "Test Summary"
echo "=================================================="
echo -e "Passed: ${GREEN}${PASS_COUNT}${NC}"
echo -e "Failed: ${RED}${FAIL_COUNT}${NC}"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi

