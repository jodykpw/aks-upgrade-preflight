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
./pdb-toggle.sh backup                  # dump all PDBs to a timestamped file
./pdb-toggle.sh delete                  # back up, then delete PDBs (with confirmation)
./pdb-toggle.sh restore [backup-file]   # re-apply PDBs from a backup (defaults to the latest in BACKUP_DIR)
```

**Actions**

| Action    | Description |
|-----------|--------------|
| `backup`  | Dumps all PDBs cluster-wide to a restore-clean JSON file (server-side/status fields stripped). |
| `delete`  | Always backs up first, then deletes PDBs. Prompts for confirmation unless `FORCE=true`. |
| `restore [file]` | Re-applies PDBs from a backup file via `kubectl apply -f`. If `file` is omitted, restores the newest `pdb-backup-*.json` in `BACKUP_DIR` — so a CI/CD restore stage can run with no state passed from the earlier `delete` step, as long as both steps share `BACKUP_DIR` (e.g. the same persisted workspace or a downloaded artifact). |

**Options (environment variables)**

| Variable | Default | Description |
|----------|---------|--------------|
| `BACKUP_DIR` | `./pdb-backups` | Where backup files are written. |
| `EXCLUDE_NAMESPACES` | `"gatekeeper-system kube-system"` | Space-separated namespaces to skip entirely — their PDBs are never backed up, deleted, or (transitively) restored. |
| `INCLUDE_SYSTEM` | `false` | If `true`, also delete the named Azure-managed system PDBs (`coredns-pdb`, `konnectivity-agent`, `metrics-server-pdb`, `calico-typha`, `ama-metrics-pdb`, `retina-pdb`) in namespaces that aren't excluded. |
| `DRY_RUN` | `false` | If `true`, print what would be deleted but change nothing. |
| `FORCE` | `false` | If `true`, skip the interactive confirmation prompt (for CI). |

`EXCLUDE_NAMESPACES` is a hard skip — it applies before anything else and
isn't overridden by `INCLUDE_SYSTEM`. By default it covers `kube-system` and
`gatekeeper-system`, since AKS/Gatekeeper reconcile PDBs in those namespaces
and touching them mid-upgrade can disrupt in-cluster DNS, control-plane
connectivity, or policy enforcement. To bring a namespace back into scope,
override the variable (e.g. `EXCLUDE_NAMESPACES=gatekeeper-system` to allow
`kube-system` PDBs through, combined with `INCLUDE_SYSTEM=true` if you also
want the named platform PDBs deleted).

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
