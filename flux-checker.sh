#!/usr/bin/env bash
#
# flux-checker.sh — read-only check that Flux is healthy and fully
# reconciled: controllers running, sources fetching, and every
# Kustomization (ks) / HelmRelease (hr) Ready and applied at the latest
# revision.
#
# "On latest commit" here means: a Kustomization's applied revision matches
# its source's currently-fetched artifact revision. This is derived purely
# from cluster state — no network git lookup against the remote is
# performed. HelmReleases are checked for Ready + a non-stuck reconcile
# attempt, but NOT cross-checked against a source revision: many
# HelmReleases point at a HelmRepository/chart version rather than a raw
# git commit, so a revision comparison there would be unreliable.
#
# Options (environment variables):
#   FLUX_NAMESPACE=flux-system   Namespace the Flux controllers run in.
#
# Requires: kubectl, jq.

set -euo pipefail

FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }
}

crd_installed() {
  kubectl get crd "$1" >/dev/null 2>&1
}

check_controllers() {
  local bad
  bad=$(kubectl get pods -n "$FLUX_NAMESPACE" -o json | jq -r '
    .items[]
    | . as $p
    | ( [$p.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown" ) as $ready
    | select($ready != "True")
    | "\($p.metadata.name)  phase=\($p.status.phase)  ready=\($ready)"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ Flux controller pod(s) not Ready in $FLUX_NAMESPACE:"
    echo "$bad"
    return 1
  fi
  echo "✅ All Flux controller pods in $FLUX_NAMESPACE are Ready."
}

# Combine GitRepository/OCIRepository/Bucket items (whichever CRDs are
# installed) into one JSON array, printed to stdout.
fetch_sources() {
  local combined="[]" type items
  for type in gitrepositories.source.toolkit.fluxcd.io \
              ocirepositories.source.toolkit.fluxcd.io \
              buckets.source.toolkit.fluxcd.io; do
    if crd_installed "$type"; then
      items=$(kubectl get "$type" -A -o json | jq -c '.items')
      combined=$(jq -nc --argjson a "$combined" --argjson b "$items" '$a + $b')
    fi
  done
  echo "$combined"
}

check_sources() {
  local sources="$1" bad
  bad=$(jq -r '
    .[]
    | select(.spec.suspend != true)
    | . as $s
    | ( [$s.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown" ) as $ready
    | select($ready != "True")
    | "\($s.kind)/\($s.metadata.namespace)/\($s.metadata.name)  ready=\($ready)"
  ' <<<"$sources")
  if [[ -n "$bad" ]]; then
    echo "❌ Flux source(s) not Ready:"
    echo "$bad"
    return 1
  fi
  echo "✅ All Flux sources (GitRepository/OCIRepository/Bucket) are Ready."
}

check_kustomizations() {
  local sources="$1"
  if ! crd_installed kustomizations.kustomize.toolkit.fluxcd.io; then
    echo "⏭  Kustomization CRD not found — skipping."
    return 0
  fi
  local bad
  bad=$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r --argjson sources "$sources" '
    ($sources | map({key: (.kind + "/" + .metadata.namespace + "/" + .metadata.name), value: (.status.artifact.revision // null)}) | from_entries) as $srcRev
    | .items[]
    | select(.spec.suspend != true)
    | . as $ks
    | ($ks.spec.sourceRef.namespace // $ks.metadata.namespace) as $srcNs
    | ($ks.spec.sourceRef.kind + "/" + $srcNs + "/" + $ks.spec.sourceRef.name) as $srcKey
    | ($srcRev[$srcKey] // null) as $latestRev
    | ( [$ks.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown" ) as $ready
    | ($ks.status.lastAppliedRevision // null) as $applied
    | ($ks.status.lastAttemptedRevision // null) as $attempted
    | select(
        $ready != "True"
        or ($attempted != $applied)
        or ( ($latestRev != null) and ($applied != $latestRev) )
      )
    | "\($ks.metadata.namespace)/\($ks.metadata.name)  ready=\($ready)  applied=\($applied // "none")  latest=\($latestRev // "unknown")"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ Kustomization(s) not Ready / not on latest revision:"
    echo "$bad"
    return 1
  fi
  echo "✅ All Kustomizations are Ready and applied at their source's latest revision."
}

check_helmreleases() {
  if ! crd_installed helmreleases.helm.toolkit.fluxcd.io; then
    echo "⏭  HelmRelease CRD not found — skipping."
    return 0
  fi
  local bad
  bad=$(kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json | jq -r '
    .items[]
    | select(.spec.suspend != true)
    | . as $hr
    | ( [$hr.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown" ) as $ready
    | ($hr.status.lastAppliedRevision // null) as $applied
    | ($hr.status.lastAttemptedRevision // null) as $attempted
    | select($ready != "True" or ($attempted != $applied))
    | "\($hr.metadata.namespace)/\($hr.metadata.name)  ready=\($ready)  applied=\($applied // "none")  attempted=\($attempted // "none")"
  ')
  if [[ -n "$bad" ]]; then
    echo "❌ HelmRelease(s) not Ready / stuck on a failed attempt:"
    echo "$bad"
    return 1
  fi
  echo "✅ All HelmReleases are Ready and reconciled."
}

main() {
  require kubectl
  require jq

  local overall=0 sources

  echo "== Flux controllers ($FLUX_NAMESPACE) =="
  check_controllers || overall=1
  echo

  sources="$(fetch_sources)"

  echo "== Flux sources =="
  check_sources "$sources" || overall=1
  echo

  echo "== Kustomizations (ks) =="
  check_kustomizations "$sources" || overall=1
  echo

  echo "== HelmReleases (hr) =="
  check_helmreleases || overall=1
  echo

  if [[ "$overall" -eq 0 ]]; then
    echo "✅ Flux is healthy and fully reconciled."
  else
    echo "❌ Flux has issues — see failures above."
  fi
  exit "$overall"
}

main "$@"
