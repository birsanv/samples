---
name: assess-acm-backup-config
description: Assess whether the current OpenShift cluster is in an ACM active-passive backup configuration. Detects backup schedules, passive restores, active hub identity, and validation cron status. Use when the user asks about ACM backup status, active-passive config, which hub is active, or backup health.
allowed-tools: Bash, Shell, Read, Grep, Glob
---

# Assess ACM Backup Configuration

Diagnose the ACM (Advanced Cluster Management) backup/restore configuration on the currently connected OpenShift cluster.

## Quick Start

Run the diagnostic script. The script path depends on the AI tool:

**Claude Code:**

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/assess-backup-config.sh
```

**Cursor:**

```bash
bash <skill-dir>/scripts/assess-backup-config.sh
```

The script requires `oc` CLI logged in to an OpenShift cluster with ACM installed.

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

### Cluster roles

| Role | Meaning |
|------|---------|
| **ACTIVE HUB** | Validation backups exist and were created by this cluster |
| **ACTIVE HUB (paused)** | Owns validation backups, but BackupSchedule is paused |
| **ACTIVE HUB (schedule missing)** | Owns validation backups, but BackupSchedule is gone |
| **ACTIVE HUB (collision)** | Owns validation backups, but another cluster started writing |
| **PASSIVE HUB** | Has a `Restore` with `ManagedClusters=skip` |
| **PASSIVE HUB (sync)** | Passive + `syncRestoreWithNewBackups: true` |
| **COLLIDING** | `BackupSchedule` exists but another hub owns validation backups |
| **FAILOVER / ACTIVATION** | `Restore` with `ManagedClusters` != skip |
| **NOT CONFIGURED** | No `BackupSchedule` or `Restore` found |

### How active hub is determined

The primary indicator is the `acm-validation-policy-schedule` backup -- a short-lived heartbeat (TTL = cron interval + 5 min). If it exists and was created by this cluster (`backup-cluster` label), this is the active hub. The `BackupSchedule` state is then checked as supplementary context (missing, paused, collision).

### Diagnostic analysis

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
