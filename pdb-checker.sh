#!/usr/bin/env bash
set -euo pipefail

blocked=$(kubectl get pdb -A -o json \
  | jq -r '.items[]
      | select(.status.disruptionsAllowed < 1)
      | "\(.metadata.namespace)/\(.metadata.name) (allowed=\(.status.disruptionsAllowed), healthy=\(.status.currentHealthy)/\(.status.desiredHealthy))"')

if [[ -n "$blocked" ]]; then
  echo "❌ PDBs that will block node drain:"
  echo "$blocked"
  exit 1
fi
echo "✅ All PDBs allow at least one disruption."