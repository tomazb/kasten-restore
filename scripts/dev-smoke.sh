#!/bin/bash

# Lightweight smoke checks for jq filters used in the VM recovery utilities.
# Intended for local/developer use; does not require cluster access.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for smoke checks but not found in PATH" >&2
  exit 0
fi

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
          "artifact": { "spec": { "running": true, "template": { "spec": { "domain": { "cpu": { "cores": 2 }, "resources": { "requests": { "memory": "4Gi" } }, "devices": { "interfaces": [ { "name": "default", "macAddress": "52:54:00:6b:3c:58" } ] } } } } } } }
        }
      ]
    }
  }
}'

SAMPLE_RPC_NO_DV='{
  "metadata": { "name": "rpc-sample-empty" },
  "status": { "restorePointContentDetails": { "artifacts": [] } }
}'

echo "[SMOKE] Parsing DataVolumes and restore methods (with DV + snapshot/export)..."
echo "$SAMPLE_RPC_WITH_DV" | jq -c '
  {
    datavolumes: [
      .status.restorePointContentDetails.artifacts[]? |
      select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
      {
        name: .resource.name,
        size: (.artifact.spec.pvc.resources.requests.storage // "Unknown"),
        hasSnapshot: (.volumeSnapshot != null)
      }
    ],
    restoreMethods: [
      (if ([.status.restorePointContentDetails.artifacts[]? | select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes" and .volumeSnapshot != null)] | length) > 0 then "Snapshot" else empty end),
      (if (.status.restorePointContentDetails.exportData.enabled // false) then "Export" else empty end)
    ]
  }
'

echo "[SMOKE] Parsing DataVolumes (no DV present, should yield empty array)..."
echo "$SAMPLE_RPC_NO_DV" | jq -c '
  [
    .status.restorePointContentDetails.artifacts[]? |
    select(.resource.group == "cdi.kubevirt.io" and .resource.resource == "datavolumes") |
    {
      name: .resource.name,
      size: (.artifact.spec.pvc.resources.requests.storage // "Unknown"),
      hasSnapshot: (.volumeSnapshot != null)
    }
  ]
'

echo "[SMOKE] Transform name extraction sample..."
awk '
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

echo "[SMOKE] Smoke checks completed."
