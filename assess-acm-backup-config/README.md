# Assess ACM Backup Configuration

Diagnose the ACM (Advanced Cluster Management) backup/restore configuration on the currently connected OpenShift cluster.

## Installation

This skill works with **Claude Code**, **Cursor**, or standalone.

### Claude Code

Copy or symlink the `assess-acm-backup-config/` directory into one of these locations:

| Scope | Path |
|-------|------|
| Personal (all projects) | `~/.claude/skills/assess-acm-backup-config/` |
| Project-only | `.claude/skills/assess-acm-backup-config/` |

Then invoke with `/assess-acm-backup-config` or let Claude load it automatically when you ask about ACM backup status.

### Cursor

Copy or symlink the `assess-acm-backup-config/` directory into:

| Scope | Path |
|-------|------|
| Personal (all projects) | `~/.cursor/skills/assess-acm-backup-config/` |
| Project-only | `.cursor/skills/assess-acm-backup-config/` |

Cursor will discover the skill from the `SKILL.md` frontmatter.

### Standalone (no AI tool)

```bash
# Assess a specific cluster context
bash assess-acm-backup-config/scripts/assess-backup-config.sh vb-hub-a

# Or use the current kubeconfig context
bash assess-acm-backup-config/scripts/assess-backup-config.sh
```

The script accepts an optional cluster context name (positional or `--context <name>`). If omitted, it uses the current kubeconfig context. The context must match an entry from `oc config get-contexts`.

The script requires `oc` CLI and a valid kubeconfig context for an OpenShift cluster with ACM installed.

## What It Detects

| Check | How |
|-------|-----|
| Cluster identity | `ClusterVersion.spec.clusterID` |
| OADP installed | `DataProtectionApplication` in `open-cluster-management-backup` |
| Storage connected | `BackupStorageLocation` with phase=Available and OADP owner |
| BackupSchedule state | `BackupSchedule` resource phase (supplementary info) |
| Passive hub | `Restore` with `veleroManagedClustersBackupName: skip` |
| ACM backups in storage | Latest `acm-resources-schedule` backup's `backup-cluster` label |
| **Active hub (primary)** | **`acm-validation-policy-schedule` backups exist AND created by this cluster** |
| Post-failover | Backups with `restore-cluster` label (managed-clusters restore ran) |

## Interpreting Results

### Cluster Roles

| Role | Meaning |
|------|---------|
| **ACTIVE HUB** | Validation backups (`acm-validation-policy-schedule`) exist and were created by this cluster |
| **ACTIVE HUB (paused)** | This cluster owns validation backups, but BackupSchedule is paused -- no new backups will be created |
| **ACTIVE HUB (schedule missing)** | This cluster owns validation backups, but BackupSchedule is gone -- backups will stop after the current interval |
| **ACTIVE HUB (collision)** | This cluster owns validation backups, but another cluster started writing to the same storage |
| **PASSIVE HUB** | Has a `Restore` with `ManagedClusters=skip` (optionally with sync) |
| **PASSIVE HUB (sync)** | Passive + `syncRestoreWithNewBackups: true` (continuous restore) |
| **COLLIDING** | `BackupSchedule` exists but another hub owns validation backups |
| **FAILOVER / ACTIVATION** | `Restore` with `ManagedClusters` != skip (activating this hub) |
| **NOT CONFIGURED** | No `BackupSchedule` or `Restore` found |

### How Active Hub Is Determined

The **primary** indicator is the `acm-validation-policy-schedule` backup. This short-lived backup (TTL = cron interval + 5 minutes) is the heartbeat of an active schedule. If it exists and was created by this cluster (via the `backup-cluster` label), this cluster is the active hub.

The `BackupSchedule` resource is then checked as supplementary context:
- If it's missing or paused, the active hub will stop producing backups at the next interval
- If it's in `BackupCollision`, another cluster has started writing to the same storage
- If it's `Enabled`, everything is healthy

### Diagnostic Analysis

The script cross-references failover history, backup ownership, and schedule state to detect misconfigurations:

| Scenario | Issue |
|----------|-------|
| This cluster ran failover but has no BackupSchedule | Should be active -- needs a BackupSchedule |
| This cluster ran failover but another hub owns latest backups | The other hub should be passive (unless it also ran restore-all) |
| This cluster has a BackupSchedule but another hub owns backups | Likely collision -- only one hub should write backups |
| Passive cluster but no backups in storage | Active hub may not be running, or BSL not syncing |
| Passive cluster but no validation backups | Active hub's cron may have stopped |

## Interactive Fix Mode

When issues are detected, the script offers to fix them interactively. The fix workflow follows this priority order:

1. **Resolve collision** -- if two hubs are writing, ask which should be active
2. **Clean up stale Restore** -- remove Restore if this hub is becoming active
3. **Remove BackupSchedule** -- if this hub should become passive
4. **Create BackupSchedule** -- if this hub should be active (prompts for cron and TTL)
5. **Create passive Restore** -- if this hub should become passive (choice of sync or one-time)
6. **Remote hub instructions** -- prints exact commands to run on the other hub
7. **Verify** -- re-checks BackupSchedule and Restore status

Each step shows the exact command and asks for confirmation before running.

Issues that can only be fixed on the remote hub (e.g., passive cluster with no backups in storage) are flagged with instructions to log in to the active hub.

## Example Output

### Healthy Active Hub

```
=== SUMMARY ===
This cluster ID:     40fa0dd9-d893-43f7-aa7b-b88b1608aa95
Role:                ACTIVE HUB (BackupSchedule: schedule-acm, phase: Enabled)
Active hub (by backups): this cluster (40fa0dd9-d893-43f7-aa7b-b88b1608aa95)
Active cron schedule: YES (validation backups exist)

No configuration issues detected.
```

### Healthy Passive Hub (Sync)

```
=== SUMMARY ===
This cluster ID:     b7c3e1a2-4f56-4d89-9e12-c34567890abc
Role:                PASSIVE HUB (sync) (Restore with MC=skip, sync=true)
Active hub (by backups): 40fa0dd9-d893-43f7-aa7b-b88b1608aa95
Active cron schedule: YES (validation backups exist)

No configuration issues detected.
```

### Post-Failover Missing Schedule

```
=== SUMMARY ===
This cluster ID:     b7c3e1a2-4f56-4d89-9e12-c34567890abc
Role:                NOT CONFIGURED (no BackupSchedule or Restore)
Active hub (by backups): 40fa0dd9-d893-43f7-aa7b-b88b1608aa95
Active cron schedule: NO (no validation backups)

=== ISSUES DETECTED ===
[1] ERROR This cluster ran managed-clusters restore (failover) so it should
    be the ACTIVE hub, but no BackupSchedule is running.
[2] ERROR This cluster ran failover (intended active hub), but hub
    40fa0dd9-d893-43f7-aa7b-b88b1608aa95 is writing backups. That hub
    should be passive (Restore with MC=skip), unless it also ran a
    restore-all to take over.

Would you like help fixing these issues? [y/N]: y

=== FIX PLAN ===
The following steps are ordered by priority.

Step 1: Remove Restore 'restore-acm-passive-sync' (this hub is becoming active)
  Command: oc delete restore.cluster.open-cluster-management.io ...
  Run this? [y/N]:

Step 2: Create BackupSchedule on this cluster (cron=0 */1 * * *, ttl=120h)
  Command: oc apply -n open-cluster-management-backup -f - ...
  Run this? [y/N]:

=== ACTION REQUIRED ON REMOTE HUB ===
The following must be done on hub 40fa0dd9-d893-43f7-aa7b-b88b1608aa95:

  1. Log in to hub 40fa0dd9-d893-43f7-aa7b-b88b1608aa95
  2. Delete its BackupSchedule:
     oc delete backupschedule -n open-cluster-management-backup --all
  3. Create a passive Restore (with sync):
     oc apply -n open-cluster-management-backup -f - <<'YAML'
     ...
     YAML
  4. Re-run this assessment script on that hub to verify.
```

## Manual Investigation

If you need to dig deeper beyond the script:

```bash
# Full BackupSchedule status
oc get backupschedule -n open-cluster-management-backup -o yaml

# Full Restore status
oc get restore.cluster.open-cluster-management.io -n open-cluster-management-backup -o yaml

# All ACM backups with cluster labels
oc get backups.velero.io -n open-cluster-management-backup \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp,HUB:.metadata.labels.cluster\.open-cluster-management\.io/backup-cluster'

# Velero schedules created by BackupSchedule
oc get schedules.velero.io -n open-cluster-management-backup

# BSL details
oc get bsl -n open-cluster-management-backup -o yaml

# BackupSchedule collision: compare latest backup's hub label with this cluster's ID
oc get clusterversion version -o jsonpath='{.spec.clusterID}'
```

## Key Resources

| Resource | API Group | Namespace |
|----------|-----------|-----------|
| `BackupSchedule` | `cluster.open-cluster-management.io/v1beta1` | `open-cluster-management-backup` |
| `Restore` | `cluster.open-cluster-management.io/v1beta1` | `open-cluster-management-backup` |
| `BackupStorageLocation` | `velero.io/v1` | `open-cluster-management-backup` |
| `Backup` | `velero.io/v1` | `open-cluster-management-backup` |
| `Schedule` | `velero.io/v1` | `open-cluster-management-backup` |
| `ClusterVersion` | `config.openshift.io/v1` | cluster-scoped |

## Key Labels

| Label | Purpose |
|-------|---------|
| `cluster.open-cluster-management.io/backup-cluster` | Hub cluster ID that created the backup |
| `cluster.open-cluster-management.io/restore-cluster` | Hub that ran managed-clusters restore (failover) |
| `velero.io/schedule-name` | Velero schedule that created the backup |
| `cluster.open-cluster-management.io/backup-schedule-type` | Type: credentials, resources, managed-clusters |

## ACM Backup Schedule Names

| Velero Schedule | Contents |
|-----------------|----------|
| `acm-credentials-schedule` | Secrets, ConfigMaps (credentials) |
| `acm-resources-schedule` | Applications, policies, placements |
| `acm-resources-generic-schedule` | User-labeled generic resources |
| `acm-managed-clusters-schedule` | ManagedCluster activation data |
| `acm-validation-policy-schedule` | Cron heartbeat (short TTL) |
