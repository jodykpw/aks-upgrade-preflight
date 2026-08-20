#!/usr/bin/env bash
#
# pdb-toggle.sh — back up, delete, and restore PodDisruptionBudgets around an
# AKS (or any Kubernetes) node-drain / cluster upgrade.
#
# Actions:
#   backup                 Dump ALL PDBs cluster-wide to a timestamped, restore-clean file.
#   delete                 Back up first, then delete PDBs.
#   restore [file]          Re-apply PDBs from a backup file (one apply, all namespaces).
#                           If [file] is omitted, restores the newest backup in BACKUP_DIR
#                           (handy for a CI/CD restore step run without state from the
#                           earlier delete step).
#
# Options (environment variables):
#   BACKUP_DIR=./pdb-backups   Where backups are written.
#   EXCLUDE_NAMESPACES="gatekeeper-system kube-system"
#                              Space-separated namespaces to skip entirely (no backup,
#                              delete, or restore).
#   INCLUDE_SYSTEM=false       If true, ALSO delete Azure-managed system PDBs (see note below).
#   DRY_RUN=false              If true, print what would be deleted but change nothing.
#   FORCE=false                If true, skip the interactive confirmation (use in CI).
#
# Requires: kubectl, jq  (bash 4+ not required)
#
# NOTE: By default the delete action EXCLUDES Azure-managed PDBs (kube-system +
# the known platform PDBs). These are reconciled by AKS and deleting them can
# disrupt in-cluster DNS / control-plane connectivity mid-upgrade. If you really
# want every last PDB gone, run with INCLUDE_SYSTEM=true.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./pdb-backups}"
EXCLUDE_NAMESPACES="${EXCLUDE_NAMESPACES:-gatekeeper-system kube-system}"
INCLUDE_SYSTEM="${INCLUDE_SYSTEM:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"

# Azure-managed PDBs recreated by the platform. Excluded unless INCLUDE_SYSTEM=true.
SYSTEM_PDBS='["coredns-pdb","konnectivity-agent","metrics-server-pdb","calico-typha","ama-metrics-pdb","retina-pdb"]'

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH." >&2; exit 1; }
}

timestamp() { date +%Y%m%d-%H%M%S; }

# Dump all PDBs, stripping server-side/status fields so the file re-applies cleanly.
# Human summary -> stderr; the backup file path -> stdout (so callers can capture it).
do_backup() {
  require jq
  mkdir -p "$BACKUP_DIR"
  local out="${1:-$BACKUP_DIR/pdb-backup-$(timestamp).json}"
  kubectl get pdb -A -o json \
    | jq --arg exns "$EXCLUDE_NAMESPACES" '
        ($exns | split(" ") | map(select(length > 0))) as $excluded
        | {apiVersion:"v1", kind:"List", items:[
            .items[]
            | select(.metadata.namespace as $n | ($excluded | index($n) | not))
            | del(
                .status,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.creationTimestamp,
                .metadata.generation,
                .metadata.managedFields,
                .metadata.selfLink,
                .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration"
              )]}' > "$out"
  local n; n=$(jq '.items | length' "$out")
  echo "Backed up $n PDB(s) -> $out" >&2
  echo "$out"
}

# Emit "namespace name" lines for the PDBs that should be deleted.
list_targets() {
  kubectl get pdb -A -o json \
    | jq -r --argjson sys "$SYSTEM_PDBS" --arg incl "$INCLUDE_SYSTEM" --arg exns "$EXCLUDE_NAMESPACES" '
        ($exns | split(" ") | map(select(length > 0))) as $excluded
        | .items[]
        | select(.metadata.namespace as $n | ($excluded | index($n) | not))
        | select(
            $incl == "true"
            or ( .metadata.namespace != "kube-system"
                 and ( .metadata.name as $n | ($sys | index($n) | not) ) )
          )
        | "\(.metadata.namespace) \(.metadata.name)"'
}

do_delete() {
  require jq
  local backup; backup="$(do_backup)"   # always back up first

  local targets=()
  while IFS= read -r line; do
    line="${line%$'\r'}"   # strip stray CR (e.g. Git Bash + native-Windows kubectl/jq writing CRLF)
    [[ -n "$line" ]] && targets+=("$line")
  done < <(list_targets)

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "No PDBs to delete after exclusions." >&2
    return 0
  fi

  echo "The following ${#targets[@]} PDB(s) will be deleted:" >&2
  printf '  %s\n' "${targets[@]}" >&2
  [[ "$INCLUDE_SYSTEM" == "true" ]] && \
    echo "!! INCLUDE_SYSTEM=true — Azure-managed system PDBs are INCLUDED." >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN=true — nothing deleted. Backup kept at: $backup" >&2
    return 0
  fi

  if [[ "$FORCE" != "true" ]]; then
    read -r -p "Proceed with deletion? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted. Backup kept at: $backup" >&2; exit 1; }
  fi

  local ns name
  for line in "${targets[@]}"; do
    ns="${line%% *}"; name="${line#* }"
    kubectl delete pdb "$name" -n "$ns"
  done

  echo "Deleted ${#targets[@]} PDB(s)." >&2
  echo "Restore later with:  $0 restore $backup" >&2
}

do_restore() {
  local file="${1:-}"
  if [[ -z "$file" ]]; then
    # No file given (e.g. a CI/CD restore step) — fall back to the newest
    # backup in BACKUP_DIR. Filenames sort chronologically (pdb-backup-<timestamp>.json).
    file="$(find "$BACKUP_DIR" -maxdepth 1 -name 'pdb-backup-*.json' -type f 2>/dev/null | sort | tail -n1)" || true
    [[ -n "$file" ]] || { echo "ERROR: no file given and no backups found in $BACKUP_DIR:  $0 restore <file>" >&2; exit 1; }
    echo "No file given — restoring latest backup: $file" >&2
  fi
  [[ -f "$file" ]] || { echo "ERROR: file not found: $file" >&2; exit 1; }
  kubectl apply -f "$file"
}

main() {
  require kubectl
  local action="${1:-}"; shift || true
  case "$action" in
    backup)  do_backup "$@" ;;
    delete)  do_delete "$@" ;;
    restore) do_restore "$@" ;;
    *) echo "Usage: $0 {backup | delete | restore <file>}" >&2; exit 1 ;;
  esac
}

main "$@"