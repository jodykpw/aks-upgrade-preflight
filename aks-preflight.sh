#!/usr/bin/env bash
#
# aks-preflight.sh — read-only checks that an AKS (or any Kubernetes) cluster
# is actually ready for a node-image / control-plane upgrade.
#
# Checks:
#   - all nodes are Ready and not cordoned
#   - no node is reporting MemoryPressure / DiskPressure / PIDPressure
#   - no PDB would block a voluntary eviction (disruptionsAllowed < 1)
#   - no workload pod is stuck Pending, crash-looping, or failing to pull an image
#   - if Flux is installed (FLUX_NAMESPACE exists), it's healthy and fully
#     reconciled (delegates to flux-checker.sh) — skipped otherwise
#   - (optional, needs `az` + RESOURCE_GROUP + CLUSTER_NAME) the AKS control
#     plane and node pools aren't already mid-operation
#
# Exits 0 if every check passes, 1 if any check fails — safe to use as a
# CI/CD gate before an upgrade stage runs.
#
# Options (environment variables):
#   EXCLUDE_NAMESPACES=kube-system   Space-separated namespaces to skip in the pod-health check.
#   RESTART_THRESHOLD=5              Container restart count above which a pod is flagged unstable.
#   FLUX_NAMESPACE=flux-system       Namespace Flux's controllers run in (see flux-checker.sh).
#   RESOURCE_GROUP=                  Azure resource group. Set together with CLUSTER_NAME to
#   CLUSTER_NAME=                    also check the AKS control plane / node pool provisioning state.
#
# Requires: kubectl, jq. `az` is only needed if RESOURCE_GROUP/CLUSTER_NAME are set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXCLUDE_NAMESPACES="${EXCLUDE_NAMESPACES:-kube-system}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-5}"
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }
}

exclude_json() {
  jq -nc --arg ns "$EXCLUDE_NAMESPACES" '$ns | split(" ") | map(select(length > 0))'
}

check_nodes_ready() {
  local bad
  bad=$(kubectl get nodes -o json | jq -r '
    .items[]
    | ( [.status.conditions[] | select(.type=="Ready")][0].status // "Unknown" ) as $ready
    | select($ready != "True" or .spec.unschedulable == true)
    | "\(.metadata.name)  ready=\($ready)  cordoned=\(.spec.unschedulable // false)"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ Node(s) not ready / cordoned:"
    echo "$bad"
    return 1
  fi
  echo "✅ All nodes are Ready and schedulable."
}

check_node_pressure() {
  local bad
  bad=$(kubectl get nodes -o json | jq -r '
    .items[] as $n
    | ($n.status.conditions // [])[]
    | select(.type as $t | ["MemoryPressure","DiskPressure","PIDPressure"] | index($t))
    | select(.status == "True")
    | "\($n.metadata.name)  \(.type)=\(.status)"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ Node(s) under resource pressure:"
    echo "$bad"
    return 1
  fi
  echo "✅ No nodes report memory/disk/PID pressure."
}

check_pdbs() {
  local bad
  bad=$(kubectl get pdb -A -o json | jq -r '
    .items[]
    | select(.status.disruptionsAllowed < 1)
    | "\(.metadata.namespace)/\(.metadata.name) (allowed=\(.status.disruptionsAllowed), healthy=\(.status.currentHealthy)/\(.status.desiredHealthy))"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ PDBs that will block node drain:"
    echo "$bad"
    return 1
  fi
  echo "✅ All PDBs allow at least one disruption."
}

check_pod_health() {
  local bad
  bad=$(kubectl get pods -A -o json | jq -r --argjson ex "$(exclude_json)" --argjson threshold "$RESTART_THRESHOLD" '
    .items[]
    | select(.metadata.namespace as $n | ($ex | index($n) | not))
    | select(.status.phase != "Succeeded")
    | . as $p
    | ( [ ($p.status.containerStatuses // [])[], ($p.status.initContainerStatuses // [])[] ]
        | map(.state.waiting.reason // empty)
        | map(select(IN("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerConfigError","InvalidImageName")))
      ) as $badReasons
    | ( [ ($p.status.containerStatuses // [])[] ] | map(.restartCount // 0) ) as $restarts
    | ( $restarts | if length > 0 then max else 0 end ) as $maxRestarts
    | select( ($p.status.phase == "Pending") or ($badReasons | length > 0) or ($maxRestarts > $threshold) )
    | "\($p.metadata.namespace)/\($p.metadata.name)  phase=\($p.status.phase)  issues=\(
        if ($badReasons | length > 0) then ($badReasons | join(","))
        elif ($p.status.phase == "Pending") then "Pending"
        else "restarts=\($maxRestarts)" end
      )"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ Unhealthy pod(s):"
    echo "$bad"
    return 1
  fi
  echo "✅ No pending, crash-looping, or unstable pods."
}

check_flux() {
  FLUX_NAMESPACE="$FLUX_NAMESPACE" bash "$SCRIPT_DIR/flux-checker.sh"
}

check_aks_provisioning_state() {
  require az
  local cp_state bad_pools
  cp_state=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query "provisioningState" -o tsv)
  bad_pools=$(az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" -o json \
    | jq -r '.[] | select(.provisioningState != "Succeeded") | "\(.name): \(.provisioningState)"')

  local ok=true
  if [[ "$cp_state" != "Succeeded" ]]; then
    echo "❌ AKS control plane provisioningState=$cp_state (expected Succeeded — a previous operation may still be in progress)."
    ok=false
  fi
  if [[ -n "$bad_pools" ]]; then
    echo "❌ Node pool(s) not in Succeeded state:"
    echo "$bad_pools"
    ok=false
  fi
  [[ "$ok" == "true" ]] || return 1
  echo "✅ AKS control plane and node pools are all in Succeeded state."
}

main() {
  require kubectl
  require jq

  local overall=0

  echo "== Node readiness =="
  check_nodes_ready || overall=1
  echo

  echo "== Node resource pressure =="
  check_node_pressure || overall=1
  echo

  echo "== PodDisruptionBudgets =="
  check_pdbs || overall=1
  echo

  echo "== Pod health =="
  check_pod_health || overall=1
  echo

  echo "== Flux =="
  if kubectl get namespace "$FLUX_NAMESPACE" >/dev/null 2>&1; then
    check_flux || overall=1
  else
    echo "⏭  Skipped ($FLUX_NAMESPACE namespace not found — Flux not installed?)."
  fi
  echo

  echo "== AKS provisioning state (Azure) =="
  if [[ -n "$RESOURCE_GROUP" && -n "$CLUSTER_NAME" ]]; then
    check_aks_provisioning_state || overall=1
  else
    echo "⏭  Skipped (set RESOURCE_GROUP and CLUSTER_NAME to enable)."
  fi
  echo

  if [[ "$overall" -eq 0 ]]; then
    echo "✅ Cluster looks ready for upgrade."
  else
    echo "❌ Cluster is NOT ready for upgrade — see failures above."
  fi
  exit "$overall"
}

main "$@"
