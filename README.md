# aks-upgrade-preflight

Small bash utilities for checking and clearing PodDisruptionBudget (PDB)
blockers before an AKS (or any Kubernetes) node drain / cluster upgrade.

## Requirements

- `kubectl`, configured against the target cluster
- `jq`
- bash

## Scripts

### `pdb-checker.sh`

Read-only check. Lists any PDB where `disruptionsAllowed < 1` — i.e. any
PDB that would currently block a voluntary eviction (which is what
`kubectl drain` / an AKS node upgrade relies on).

```bash
./pdb-checker.sh
```

- Exits `0` and prints `✅ All PDBs allow at least one disruption.` if
  nothing is blocking.
- Exits `1` and lists the offending `namespace/name` (with allowed/healthy
  counts) if anything would block a drain. Useful as a CI/preflight gate.

### `pdb-toggle.sh`

Backs up, deletes, and restores PDBs around an upgrade window.

```bash
./pdb-toggle.sh backup                # dump all PDBs to a timestamped file
./pdb-toggle.sh delete                # back up, then delete PDBs (with confirmation)
./pdb-toggle.sh restore <backup-file> # re-apply PDBs from a backup
```

**Actions**

| Action    | Description |
|-----------|--------------|
| `backup`  | Dumps all PDBs cluster-wide to a restore-clean JSON file (server-side/status fields stripped). |
| `delete`  | Always backs up first, then deletes PDBs. Prompts for confirmation unless `FORCE=true`. |
| `restore <file>` | Re-applies PDBs from a backup file via `kubectl apply -f`. |

**Options (environment variables)**

| Variable | Default | Description |
|----------|---------|--------------|
| `BACKUP_DIR` | `./pdb-backups` | Where backup files are written. |
| `INCLUDE_SYSTEM` | `false` | If `true`, also delete Azure-managed system PDBs (`coredns-pdb`, `konnectivity-agent`, `metrics-server-pdb`, `calico-typha`, `ama-metrics-pdb`, `retina-pdb`) and everything in `kube-system`. |
| `DRY_RUN` | `false` | If `true`, print what would be deleted but change nothing. |
| `FORCE` | `false` | If `true`, skip the interactive confirmation prompt (for CI). |

By default, `delete` **excludes** `kube-system` and the known Azure-managed
platform PDBs, since AKS reconciles those and deleting them mid-upgrade can
disrupt in-cluster DNS / control-plane connectivity. Set `INCLUDE_SYSTEM=true`
only if you're sure you want those gone too.

**Example: safe delete/restore cycle around an upgrade**

```bash
DRY_RUN=true ./pdb-toggle.sh delete        # preview what would be deleted
./pdb-toggle.sh delete                     # back up + delete (with confirmation)
# ... perform the AKS node pool / cluster upgrade ...
./pdb-toggle.sh restore ./pdb-backups/pdb-backup-<timestamp>.json
```

## Typical preflight workflow

```bash
./pdb-checker.sh || ./pdb-toggle.sh delete   # if blocked, clear PDBs before draining
# ... run the upgrade ...
./pdb-toggle.sh restore <backup-file>        # restore PDBs afterward
```

## Setup

```bash
chmod +x pdb-checker.sh pdb-toggle.sh
```
