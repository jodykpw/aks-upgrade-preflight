# aks-upgrade-preflight

Small bash utilities for checking and clearing PodDisruptionBudget (PDB)
blockers before an AKS (or any Kubernetes) node drain / cluster upgrade.

## Requirements

- `kubectl`, configured against the target cluster
- `jq`
- bash
- `az` — only needed if you use `aks-preflight.sh`'s optional Azure provisioning-state check

## Scripts

### `aks-preflight.sh`

Broader, read-only readiness check. Runs everything below in one pass and
exits `0` only if all of it looks clean:

- all nodes `Ready` and not cordoned
- no node reporting `MemoryPressure` / `DiskPressure` / `PIDPressure`
- no PDB would block a voluntary eviction (delegates to `pdb-checker.sh`)
- no workload pod stuck `Pending`, crash-looping, or failing to pull an image
- if Flux is installed, it's healthy and fully reconciled (delegates to
  `flux-checker.sh`) — skipped automatically if `FLUX_NAMESPACE` doesn't exist
- *(optional)* the AKS control plane and node pools aren't already mid-operation

```bash
./aks-preflight.sh
```

**Options (environment variables)**

| Variable | Default | Description |
|----------|---------|--------------|
| `EXCLUDE_NAMESPACES` | `kube-system` | Space-separated namespaces to skip in the pod-health check. |
| `RESTART_THRESHOLD` | `5` | Container restart count above which a pod is flagged unstable. |
| `FLUX_NAMESPACE` | `flux-system` | Namespace Flux's controllers run in — see `flux-checker.sh`. |
| `RESOURCE_GROUP` / `CLUSTER_NAME` | *(unset)* | Set both to also check via `az` that the AKS control plane and node pools are in `Succeeded` state (i.e. not already mid-upgrade). Skipped if either is unset. |

### `flux-checker.sh`

Read-only check that Flux is healthy and fully reconciled: controllers
running, sources fetching, and every Kustomization (`ks`) / HelmRelease
(`hr`) `Ready` and applied at the latest revision.

```bash
./flux-checker.sh
```

"On latest commit" means a Kustomization's applied revision matches its
source's currently-fetched artifact revision — this is checked entirely
from cluster state, not a live git remote lookup. A Kustomization can show
`Ready=True` yet still be flagged here if its source has since fetched a
newer revision it hasn't caught up to. HelmReleases are checked for `Ready`
+ a non-stuck reconcile attempt only (no revision cross-check), since many
point at a chart version rather than a raw git commit. Suspended resources
(`spec.suspend: true`) are excluded from all checks.

**Options (environment variables)**

| Variable | Default | Description |
|----------|---------|--------------|
| `FLUX_NAMESPACE` | `flux-system` | Namespace the Flux controllers run in. |

Gracefully skips the HelmRelease check (or the OCIRepository/Bucket source
types) if those CRDs aren't installed — it only hard-fails if the Flux
namespace or the Kustomization CRD itself is missing.

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
./aks-preflight.sh || ./pdb-toggle.sh delete   # if blocked, clear PDBs before draining
# ... run the upgrade ...
./pdb-toggle.sh restore <backup-file>          # restore PDBs afterward
```

## CI/CD (GitLab example)

There's no TTY in a CI runner, so `delete`'s interactive confirmation must
be bypassed with `FORCE=true`. Backup and restore steps can share state via
`BACKUP_DIR` (a persisted/cached path, or an uploaded+downloaded artifact)
instead of passing a filename around:

```yaml
variables:
  FORCE: "true"
  BACKUP_DIR: "$CI_PROJECT_DIR/pdb-backups"

delete-pdbs:
  stage: pre-upgrade
  script:
    - ./pdb-toggle.sh delete
  artifacts:
    paths:
      - pdb-backups/

restore-pdbs:
  stage: post-upgrade
  script:
    - ./pdb-toggle.sh restore   # no filename needed — picks up the newest file in BACKUP_DIR
  dependencies:
    - delete-pdbs
```

If you'd rather keep a human approval gate instead of an unattended
`FORCE=true` delete, mark the job `when: manual` in GitLab and let the
pipeline UI be the confirmation step instead of the shell prompt.

## Setup

```bash
chmod +x aks-preflight.sh pdb-checker.sh pdb-toggle.sh flux-checker.sh
```
