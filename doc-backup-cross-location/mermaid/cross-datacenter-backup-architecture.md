# ACM Active/Passive Hub Configuration with Cross-Datacenter S3 Replication

## Table of Contents

- [1. Problem Statement](#1-problem-statement)
- [2. Architecture Overview](#2-architecture-overview)
- [3. S3 Replication Strategies](#3-s3-replication-strategies)
- [4. ACM Hub Configuration](#4-acm-hub-configuration-both-data-centers)
- [5. Failover Procedure](#5-failover-procedure)
- [6. Disaster Recovery Testing](#6-disaster-recovery-testing-non-destructive)
- [7. Network and Managed Cluster Considerations](#7-network-and-managed-cluster-considerations)
- [8. Backup Collision Prevention](#8-backup-collision-prevention)
- [9. Observability Considerations](#9-observability-considerations)
- [10. FAQ](#10-faq)

---

## 1. Problem Statement

Red Hat Advanced Cluster Management (ACM) supports an [active-passive hub cluster configuration](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/business_continuity/business-cont-overview#active-passive-config) for disaster recovery. In this model, a primary hub cluster backs up data at regular intervals using OADP/Velero, and one or more passive hub clusters continuously restore that data so they can take over if the primary fails.

**The limitation**: this configuration requires both hub clusters to share a **single S3 storage location**. This constrains the deployment to a single data center or cloud region, because:

- The S3 bucket becomes a single point of failure. If the storage location is lost, both the backup and the restore capability are gone.
- Customers with two physical data centers cannot leverage local storage in each DC for resilience.
- A full data center outage (compute + storage) leaves no accessible backup.

**The customer requirement** ([ACM-6583](https://issues.redhat.com/browse/ACM-6583)):

- Primary data center with an ACM hub and **its own** S3 object store.
- Secondary data center with an ACM hub and **its own** S3 object store.
- Automatic replication of backup data between the two S3 stores.
- Managed clusters in either location can be managed by whichever hub is active.
- Ability to test disaster recovery (failover and failback) without data loss.

This document describes a recommended architecture that addresses these requirements by combining ACM's built-in backup/restore operator with **S3 cross-datacenter replication**.

---

## 2. Architecture Overview

The architecture places an independent ACM hub cluster and S3-compatible object store in each data center. An S3 replication mechanism keeps the secondary S3 bucket synchronized with the primary. The passive hub reads from its local (replicated) S3 bucket, so it never needs direct network access to the primary DC's storage.

### High-Level Architecture

```mermaid
flowchart TB
  subgraph DC1 ["Data Center 1 (Active)"]
    direction TB
    Hub1["ACM Hub - Active<br/><br/>BackupSchedule<br/>OADP / Velero"]
    S3_1[("S3 Bucket<br/>(Primary)")]
    Hub1 -- "write backups" --> S3_1
    MC_A["Managed Cluster A"]
    MC_B["Managed Cluster B"]
  end

  subgraph DC2 ["Data Center 2 (Passive)"]
    direction TB
    Hub2["ACM Hub - Passive<br/><br/>Restore (sync)<br/>OADP / Velero"]
    S3_2[("S3 Bucket<br/>(Replica)")]
    S3_2 -- "read backups" --> Hub2
    MC_C["Managed Cluster C"]
    MC_D["Managed Cluster D"]
  end

  S3_1 == "S3 Replication<br/>(one-way sync)" ==> S3_2

  Hub1 -. "manages" .-> MC_A
  Hub1 -. "manages" .-> MC_B
  Hub1 -. "manages" .-> MC_C
  Hub1 -. "manages" .-> MC_D
```

### Key Design Principles

1. **Each DC owns its storage**: Both the active and passive hub clusters use a local S3 bucket. Neither hub needs cross-DC network access to the other's S3.

2. **One-way replication (active to passive)**: During normal operation, S3 replication flows from the primary bucket to the replica bucket. The passive hub's `Restore` resource reads from the local replica.

3. **Replication reversal on failover**: When the secondary DC becomes active, the S3 replication direction is reversed so the new active hub's backups flow to the other DC's bucket.

4. **Same OADP/Velero stack on both hubs**: Both hubs run identical ACM versions, OADP operators, and `DataProtectionApplication` configurations (differing only in the S3 endpoint/bucket pointing to local storage).

5. **Managed clusters connect to the active hub**: All managed clusters (in either DC) are managed by whichever hub is currently active. Network connectivity from all managed clusters to both DCs is required.

### Data Flow: Normal Operation

```mermaid
sequenceDiagram
    participant Hub1 as Active Hub (DC1)
    participant S3_DC1 as S3 Bucket (DC1)
    participant S3_DC2 as S3 Bucket (DC2)
    participant Hub2 as Passive Hub (DC2)

    Hub1->>S3_DC1: 1. BackupSchedule runs every N hours
    S3_DC1->>S3_DC2: 2. S3 replication copies new backup objects
    S3_DC2->>Hub2: 3. Passive Restore detects new backups
    Note over Hub2: Has latest policies, apps,<br/>credentials (but NOT<br/>cluster activation data)
```

### Data Flow: Failover

```mermaid
sequenceDiagram
    participant DC1 as DC1 (down)
    participant Hub2 as DC2 Hub (activating)
    participant S3_DC2 as S3 Bucket (DC2)
    participant S3_DC1 as S3 Bucket (DC1)
    participant MC as Managed Clusters

    Note over DC1: DC1 goes down
    Hub2->>S3_DC2: 1. Verify S3 replica is current
    Hub2->>Hub2: 2. Restore activation data<br/>(ManagedClusters: latest)
    MC-->>Hub2: 3. Managed clusters reconnect
    Hub2->>S3_DC2: 4. Create BackupSchedule on DC2
    S3_DC2->>S3_DC1: 5. Reverse replication (DC2 to DC1 when recovered)
```

---

## 3. S3 Replication Strategies

The cross-datacenter architecture requires an S3 replication layer that copies backup objects from the primary bucket to the secondary bucket. Three strategies are presented, covering cloud-native, on-premises, and OpenShift-integrated options.

### 3.1 AWS S3 Cross-Region Replication (CRR)

Best for: Customers running ACM on AWS across two regions.

AWS S3 Cross-Region Replication automatically copies objects from a source bucket in one region to a destination bucket in another region.

**Prerequisites**:
- Two S3 buckets in different AWS regions (e.g., `us-east-1` and `us-west-2`)
- Versioning enabled on both buckets
- An IAM role with `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:GetReplicationConfiguration` permissions

**Configuration**:

```json
{
  "Role": "arn:aws:iam::ACCOUNT-ID:role/replication-role",
  "Rules": [
    {
      "Status": "Enabled",
      "Priority": 1,
      "Filter": {
        "Prefix": ""
      },
      "Destination": {
        "Bucket": "arn:aws:s3:::acm-backup-dc2",
        "StorageClass": "STANDARD"
      },
      "DeleteMarkerReplication": {
        "Status": "Enabled"
      }
    }
  ]
}
```

Apply the replication configuration:

```bash
aws s3api put-bucket-replication \
  --bucket acm-backup-dc1 \
  --replication-configuration file://replication.json
```

**Considerations**:
- Replication is **asynchronous**; most objects replicate within 15 minutes, but large backups may take longer.
- Replication Time Control (RTC) can guarantee 99.99% of objects replicate within 15 minutes (additional cost).
- Delete markers are replicated (enable `DeleteMarkerReplication`), but actual deletions of versioned objects are not replicated by default. This means expired backups cleaned up by Velero TTL on the primary may remain on the replica until manually cleaned or a lifecycle policy is applied.
- **Failover**: To reverse replication, create a new CRR rule on the DC2 bucket pointing to DC1 and remove the rule from DC1.

### 3.2 MinIO Bucket Replication

Best for: On-premises deployments or any environment using MinIO as S3-compatible storage.

MinIO supports [server-side bucket replication](https://min.io/docs/minio/linux/administration/bucket-replication.html) between two MinIO clusters, providing near-real-time object synchronization.

**Prerequisites**:
- Two MinIO clusters (one per DC), each with a bucket for ACM backups
- Versioning enabled on both buckets
- A service account on each MinIO cluster with replication permissions

**Configuration**:

```bash
# Add both MinIO clusters as aliases
mc alias set dc1 https://minio-dc1.example.com ACCESS_KEY SECRET_KEY
mc alias set dc2 https://minio-dc2.example.com ACCESS_KEY SECRET_KEY

# Enable versioning on both buckets
mc version enable dc1/acm-backups
mc version enable dc2/acm-backups

# Set up one-way replication from DC1 to DC2
mc replicate add dc1/acm-backups \
  --remote-bucket https://ACCESS_KEY:SECRET_KEY@minio-dc2.example.com/acm-backups \
  --replicate "delete,delete-marker,existing-objects"
```

**Considerations**:
- MinIO replication is near-real-time with configurable retry and failure queues.
- Supports **active-active replication** (bidirectional), but for ACM use the **active-passive (one-way)** mode to match the backup flow.
- On failover, remove the replication rule from DC1 and add a reverse rule from DC2 to DC1.
- MinIO's `mc replicate status` command shows replication lag and pending objects.

### 3.3 Red Hat OpenShift Data Foundation -- Noobaa Multi-Cloud Gateway (MCG)

Best for: Customers using OpenShift Data Foundation (ODF) who want an OpenShift-native solution, as mentioned in [ACM-6583](https://issues.redhat.com/browse/ACM-6583).

Noobaa MCG can mirror a bucket across multiple backing stores (cloud or on-prem), providing transparent replication.

**Prerequisites**:
- OpenShift Data Foundation (ODF) installed on both hub clusters
- Noobaa MCG operator running in each DC
- Network connectivity between the two MCG instances (or to a common cloud store)

**Configuration approach**:

1. **Create a backing store** in each DC pointing to local storage (PV-based or cloud):

```yaml
apiVersion: noobaa.io/v1alpha1
kind: BackingStore
metadata:
  name: local-dc-store
  namespace: openshift-storage
spec:
  type: pv-pool
  pvPool:
    numVolumes: 3
    resources:
      requests:
        storage: 50Gi
    storageClass: gp3-csi
```

2. **Create a mirror bucket class** that spans both DCs. This requires the MCG instances to be aware of each other's backing stores. Using Noobaa's namespace bucket or mirror policy, data written to one DC is automatically replicated:

```yaml
apiVersion: noobaa.io/v1alpha1
kind: BucketClass
metadata:
  name: cross-dc-mirror
  namespace: openshift-storage
spec:
  placementPolicy:
    tiers:
      - backingStores:
          - local-dc1-store
          - remote-dc2-store
        placement: Mirror
```

3. **Create the ObjectBucketClaim** for ACM backups:

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: acm-backup-bucket
  namespace: open-cluster-management-backup
spec:
  bucketName: acm-cross-dc-backups
  additionalConfig:
    bucketclass: cross-dc-mirror
  storageClassName: openshift-storage.noobaa.io
```

**Considerations**:
- MCG mirror placement writes to **all** backing stores simultaneously, providing strong consistency at the cost of write latency.
- This approach means both hubs can read from the same logical bucket (via their local MCG endpoint), so the `DataProtectionApplication` on each hub can point to the same bucket name via the local MCG S3 endpoint.
- The MCG topology requires careful network planning if the backing stores are in different physical DCs.
- ODF licensing covers MCG.

### Comparison Table

| Feature | AWS S3 CRR | MinIO Replication | Noobaa MCG Mirror |
|---|---|---|---|
| **Environment** | AWS cloud | On-prem / any S3 | OpenShift (ODF) |
| **Replication type** | Async (one-way) | Async (one-way or bidirectional) | Sync (mirror) |
| **Typical lag** | < 15 min (RTC available) | Near real-time | Write-time (sync) |
| **Failover complexity** | Swap CRR rules | Swap replication rules | Automatic (mirror) |
| **Delete replication** | Configurable | Configurable | Automatic |
| **Cost** | Per-object replication fee | Self-hosted | ODF license |
| **Maturity** | Production | Production | Production |

---

## 4. ACM Hub Configuration (Both Data Centers)

Both the active and passive hub clusters must be configured identically in terms of ACM version, installed operators, and namespace layout. The only differences are the S3 endpoint/credentials (each points to local storage) and whether a `BackupSchedule` or `Restore` resource is active.

### 4.1 Prerequisites (Both Hubs)

- Red Hat OpenShift Container Platform (same version on both)
- Red Hat Advanced Cluster Management operator (same version on both)
- `MultiClusterHub` resource created and in `Running` state
- All additional operators installed on the primary hub must also be installed on the passive hub (e.g., Ansible Automation Platform, OpenShift GitOps, cert-manager)

### 4.2 Enable the Backup Operator

On **both** hub clusters, enable the cluster-backup component on the `MultiClusterHub`:

```yaml
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec:
  overrides:
    components:
      - enabled: true
        name: cluster-backup
      # ... other components
```

This automatically installs the OADP operator and the cluster backup and restore operator in the `open-cluster-management-backup` namespace.

### 4.3 Create the Storage Secret

On **each** hub, create a secret with credentials for the **local** S3 bucket in the `open-cluster-management-backup` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: open-cluster-management-backup
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id=<LOCAL_ACCESS_KEY>
    aws_secret_access_key=<LOCAL_SECRET_KEY>
```

### 4.4 Create the DataProtectionApplication

On **each** hub, create a `DataProtectionApplication` pointing to the **local** S3 bucket. The bucket name can be the same on both sides (each hub talks to its own S3 endpoint), or different (each hub uses its local bucket name).

**DC1 (Active Hub)**:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-hub
  namespace: open-cluster-management-backup
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: acm-backup-dc1
          prefix: hub-backup
        config:
          region: us-east-1
          s3ForcePathStyle: "true"            # required for non-AWS S3
          s3Url: https://s3-dc1.example.com   # local S3 endpoint
        credential:
          name: cloud-credentials
          key: cloud
```

**DC2 (Passive Hub)** -- identical except for the bucket/endpoint:

```yaml
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dpa-hub
  namespace: open-cluster-management-backup
spec:
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - aws
    nodeAgent:
      enable: true
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: acm-backup-dc2          # replica bucket
          prefix: hub-backup              # same prefix
        config:
          region: us-west-2
          s3ForcePathStyle: "true"
          s3Url: https://s3-dc2.example.com
        credential:
          name: cloud-credentials
          key: cloud
```

> **Important**: The `prefix` must match on both hubs so the passive hub can find the backup files produced by the active hub after they are replicated.

> **Note for Noobaa MCG**: If using MCG mirror mode, both hubs point to the same logical bucket via their local MCG S3 route (`s3.openshift-storage.svc`). The bucket name and prefix are identical on both sides.

### 4.5 Verify BackupStorageLocation

On both hubs, confirm that the `BackupStorageLocation` is `Available`:

```bash
oc get backupstoragelocation -n open-cluster-management-backup
```

Expected output:

```
NAME          PHASE       LAST VALIDATED   AGE
dpa-hub-1     Available   30s              5m
```

### 4.6 Configure the Active Hub (DC1) -- BackupSchedule

Create the `BackupSchedule` on the **active hub only**:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "0 */2 * * *"       # every 2 hours
  veleroTtl: 120h                      # keep backups for 5 days
  useManagedServiceAccount: true       # enable auto-import on restore
```

Verify:

```bash
oc get backupschedule -n open-cluster-management-backup
# STATUS should be "Enabled"

oc get schedules -n open-cluster-management-backup | grep acm
# Should show 6 Velero schedules
```

### 4.7 Configure the Passive Hub (DC2) -- Restore with Sync

On the **passive hub**, create a `Restore` resource that continuously syncs with new backups:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: open-cluster-management-backup
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m             # check for new backups every 10 minutes
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip      # do NOT activate managed clusters
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

> **Critical**: `veleroManagedClustersBackupName` must be `skip` during passive operation. Setting it to `latest` would activate managed clusters on the passive hub, causing a split-brain situation.

> **Note on replication lag**: The `restoreSyncInterval` should be larger than the expected S3 replication lag. If replication typically takes 5 minutes, a 10-minute sync interval ensures the passive hub sees complete backups. With Noobaa MCG synchronous mirroring, the interval can be shorter.

---

## 5. Failover Procedure

When the primary data center (DC1) becomes unavailable, follow these steps to activate the passive hub in DC2.

### 5.1 Assess the Situation

Before failing over:

1. Confirm that DC1 is truly unavailable (not a transient network issue).
2. Check the replication status of the S3 bucket in DC2:
   - **AWS**: Check S3 replication metrics in CloudWatch.
   - **MinIO**: `mc replicate status dc1/acm-backups`
   - **MCG**: Check the Noobaa dashboard or bucket status.
3. Verify that the passive hub has recent restore data:

```bash
oc get restore -n open-cluster-management-backup -o yaml
# Check .status.lastMessage and timestamps
```

### 5.2 Activate the Passive Hub

On the **DC2 passive hub**, update the existing `Restore` resource or create a new one to restore managed cluster activation data:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-activate
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest   # activates managed clusters
  veleroCredentialsBackupName: skip          # already restored by passive sync
  veleroResourcesBackupName: skip            # already restored by passive sync
```

After applying this, managed clusters will begin connecting to the DC2 hub. Hive-provisioned clusters reconnect automatically. Imported clusters reconnect automatically if `useManagedServiceAccount` was enabled on the `BackupSchedule`; otherwise, they remain in `Pending Import` and must be manually reimported.

### 5.3 Create BackupSchedule on the New Active Hub

Once DC2 is confirmed as the active hub:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "0 */2 * * *"
  veleroTtl: 120h
  useManagedServiceAccount: true
```

### 5.4 Reconfigure S3 Replication

Reverse the S3 replication direction so that DC2's bucket now replicates **to** DC1's bucket. This prepares DC1 to become the passive hub once it is recovered.

- **AWS**: Remove the CRR rule from `acm-backup-dc1`, add a CRR rule on `acm-backup-dc2` targeting `acm-backup-dc1`.
- **MinIO**: `mc replicate rm dc1/acm-backups` and `mc replicate add dc2/acm-backups --remote-bucket ... dc1 ...`
- **MCG**: No action needed if using mirror mode (both DCs already have the data).

### 5.5 Recover the Original Hub (DC1) as Passive

When DC1 comes back online:

1. **Do not** start the `BackupSchedule` on DC1. If one already exists, delete it or set `paused: true`.
2. Verify that the reversed S3 replication is populating DC1's bucket with DC2's backups.
3. Create a passive `Restore` resource on DC1:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: open-cluster-management-backup
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 10m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

DC1 is now the passive hub.

### Failover Summary

| Step | Action | Where |
|------|--------|-------|
| 1 | Confirm DC1 is down, verify S3 replica freshness | DC2 |
| 2 | Restore activation data (`ManagedClusters: latest`) | DC2 |
| 3 | Create `BackupSchedule` | DC2 |
| 4 | Reverse S3 replication direction | S3 layer |
| 5 | Recover DC1 as passive (Restore with sync, no BackupSchedule) | DC1 |

---

## 6. Disaster Recovery Testing (Non-Destructive)

You can test the failover procedure without permanently losing control of managed clusters on the primary hub. This is especially important for validating the cross-datacenter setup.

### 6.1 Prepare the Primary Hub (DC1)

1. **Pause the BackupSchedule**:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: open-cluster-management-backup
spec:
  veleroSchedule: "0 */2 * * *"
  veleroTtl: 120h
  useManagedServiceAccount: true
  paused: true                          # pause backups
```

2. **Tag resources** so they can be cleaned up by a future `CleanupRestored` operation. Create and apply a `Restore` on DC1 to annotate existing resources:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-tag-resources
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: None
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

3. **Disable auto-import** on all managed clusters to prevent DC1 from reclaiming them:

```bash
for mc in $(oc get managedcluster -o name); do
  oc annotate $mc import.open-cluster-management.io/disable-auto-import='' --overwrite
done
```

### 6.2 Activate the Passive Hub (DC2)

Follow the same steps as [Section 5.2](#52-activate-the-passive-hub): restore activation data on DC2.

### 6.3 Run DR Tests

With DC2 now active:
- Verify managed clusters appear and are `Available`.
- Test policy enforcement, application deployment, etc.
- Verify that the `backup-restore-enabled` policy reports no violations on DC2.

### 6.4 Return to the Primary Hub (DC1)

After testing is complete, reverse the process to restore DC1 as the active hub:

1. **Create a BackupSchedule on DC2** (if not already running) and wait for at least one successful backup cycle.

2. **Pause the BackupSchedule on DC2** and set `disable-auto-import` on all managed clusters (same as step 6.1.3).

3. **Restore on DC1** with `CleanupRestored` to bring it up to date with DC2's data:

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-return
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

4. **Re-enable the BackupSchedule on DC1** (set `paused: false`).

5. **Reconfigure DC2 as passive** (delete the BackupSchedule, create a passive Restore).

6. **Restore S3 replication** to the original direction (DC1 → DC2).

For the full procedure, refer to [Restoring data to the initial hub cluster](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/business_continuity/business-cont-overview#restoring-data-to-the-initial-hub-cluster) in the official documentation.

---

## 7. Network and Managed Cluster Considerations

A cross-datacenter deployment introduces network requirements beyond a single-DC setup.

### 7.1 Managed Cluster Connectivity

All managed clusters must be reachable from **both** data centers, since either hub may become the active manager. This means:

- **Firewall rules**: Both DC1 and DC2 hub clusters need outbound access to all managed cluster API servers (port 6443).
- **Managed clusters** need outbound access to both hub cluster API servers for the klusterlet to connect.
- If managed clusters are split across DCs (some in DC1, some in DC2), cross-DC network links must support the management traffic.

### 7.2 DNS and Global Load Balancing

For seamless failover without reconfiguring managed cluster klusterlets:

- Use a **Global Load Balancer** (GLB) or DNS-based failover in front of the hub cluster API servers.
- A single DNS name (e.g., `hub.example.com`) resolves to the active hub.
- On failover, update the DNS record or GLB target to point to the DC2 hub.
- This reduces the need to manually reimport managed clusters after failover.

> **Note**: ACM's `ManagedServiceAccount` auto-import feature provides an alternative to GLB: it stores bootstrap tokens that allow the restore operator to automatically reconnect imported clusters to the new hub without DNS changes. Enable it by setting `useManagedServiceAccount: true` on the `BackupSchedule`.

### 7.3 S3 Replication Network

The S3 replication layer requires network connectivity between the two S3 endpoints:

| Replication Method | Network Requirement |
|---|---|
| AWS S3 CRR | No user-managed network (AWS handles it internally) |
| MinIO | HTTPS connectivity between MinIO clusters (configurable port) |
| Noobaa MCG | Network path between MCG instances or shared cloud store access |

Ensure that the S3 replication traffic is encrypted in transit (TLS) and that the bandwidth between DCs is sufficient for the backup data volume.

### 7.4 Estimating Bandwidth Requirements

The backup data volume depends on:
- Number of managed clusters
- Number of policies, applications, and other hub resources
- Backup frequency (the `veleroSchedule` cron)

As a rough guide:
- A hub managing ~100 clusters with moderate policy/app load produces backups in the range of **100 MB -- 1 GB** per cycle.
- A hub managing ~2000 clusters may produce **several GB** per cycle.
- With a 2-hour backup interval, plan for the full backup volume to transfer within 2 hours.

---

## 8. Backup Collision Prevention

Backup collisions occur when two hub clusters write backups to the same (or replicated) storage location simultaneously. This is a critical concern in the cross-datacenter model.

### 8.1 How Collision Detection Works

The ACM backup operator includes a `BackupCollision` detection mechanism. The `BackupSchedule` controller periodically checks whether the latest backup in the storage location was created by the **current** hub cluster (identified by cluster ID). If a different hub cluster wrote the latest backup, the `BackupSchedule` status transitions to `BackupCollision`, and Velero schedules are deleted to prevent further writes.

### 8.2 Cross-DC Collision Scenarios

With cross-datacenter S3 replication, collisions can arise in these situations:

1. **Split-brain**: Both hubs believe they are active and write backups. Because S3 replication copies objects from both buckets, the merged view contains interleaved backups from two different hub clusters.

2. **Stale BackupSchedule after failover**: The old primary hub recovers and still has an active `BackupSchedule`. It starts writing to its local S3, which replicates to the other DC, causing collision.

### 8.3 Prevention Measures

- **Always pause or delete the `BackupSchedule`** on the old primary before or immediately after failover.
- **Only one hub should have an active `BackupSchedule`** at any time.
- Monitor the `backup-restore-enabled` policy on both hubs. The `acm-backup-clusters-collision-report` policy template reports `BackupCollision` status.
- When recovering the old primary as passive, do **not** re-enable its `BackupSchedule`.

```bash
# Check for collision on any hub
oc get backupschedule -n open-cluster-management-backup -o wide
```

If `BackupCollision` is detected:
1. Identify which hub is the legitimate active hub.
2. Delete the `BackupSchedule` on the illegitimate hub.
3. On the legitimate hub, delete the collided `BackupSchedule` and create a new one.

### 8.4 S3 Replication and Collision Interaction

Because each hub writes to its **own** local S3 bucket and replication is one-way, the collision risk is reduced compared to a shared-bucket model. The passive hub only reads; it never writes backups. Collision can only occur if:
- S3 replication is bidirectional **and** both hubs write simultaneously, or
- The old primary resumes writing after failover and replication copies those backups to the new primary's bucket.

**Recommendation**: Use **one-way replication** (active → passive) and reverse it only during failover. This structurally prevents collisions.

---

## 9. Observability Considerations

If the Observability service (`MultiClusterObservability`) is enabled, additional steps are needed for cross-datacenter failover.

### 9.1 Shared vs. Separate Metrics Storage

Two options for Observability metrics storage:

| Option | Description | Trade-off |
|---|---|---|
| **Shared S3** | Both hubs use the same replicated S3 bucket for Thanos metrics | Metrics continuity on failover, but requires replication of large time-series data |
| **Separate S3** | Each hub has its own Observability S3 bucket | Simpler, but metrics history is lost on failover |

**Recommendation**: For most deployments, use **separate** Observability S3 buckets. Metrics history is valuable but not critical for cluster management. This avoids the complexity and bandwidth cost of replicating potentially large time-series data.

### 9.2 Failover Steps for Observability

1. **Before failover** (if the primary is accessible), shut down the Thanos compactor:

```bash
oc scale statefulset observability-thanos-compact \
  -n open-cluster-management-observability --replicas=0
```

2. **Preserve the tenant ID** by backing up the `observatorium` resource:

```bash
oc get observatorium -n open-cluster-management-observability -o yaml > observatorium-backup.yaml
```

3. **On the new active hub**, restore the `observatorium` resource before enabling Observability:

```bash
oc apply -f observatorium-backup.yaml
```

4. Apply the `MultiClusterObservability` CR:

```bash
oc apply -f mco-cr-backup.yaml
```

The tenant ID is preserved, which maintains continuity in metrics ingestion. Managed clusters will begin sending metrics to the new active hub once they reconnect.

For the full procedure, see [Backing up and restoring Observability service](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/business_continuity/business-cont-overview#backup-restore-observability).

---

## 10. FAQ

### Q: Can I use bidirectional S3 replication?

Bidirectional replication is technically possible (MinIO and AWS support it), but it introduces complexity:
- Both hubs see backups from both hub clusters, which can trigger `BackupCollision`.
- Velero TTL-based cleanup on one side may conflict with the other.

**Recommendation**: Use one-way replication aligned with the active → passive direction, and reverse it on failover.

### Q: What happens if the S3 replication lags behind?

If the primary fails before all backup objects have replicated, the passive hub may restore from a slightly older backup. The `restoreSyncInterval` on the passive hub determines how often it checks for new data. To minimize risk:
- Use AWS S3 Replication Time Control (RTC) for guaranteed SLAs.
- Monitor replication lag with your storage provider's tools.
- Run backups more frequently (e.g., every hour) so the worst-case data loss window is smaller.

### Q: Do I need the same bucket name on both sides?

No. The bucket names can differ (e.g., `acm-backup-dc1` and `acm-backup-dc2`). What matters is that the **prefix** (path within the bucket) is the same, so Velero on the passive hub can find the backup files. The `DataProtectionApplication` on each hub points to its local bucket name.

For Noobaa MCG mirror mode, both hubs use the same logical bucket name through their local MCG S3 endpoints.

### Q: Can managed clusters in DC2 connect to the hub in DC1?

Yes, but network connectivity is required. Managed clusters use outbound connections to the hub cluster API server. As long as the managed cluster can reach the active hub's API server (possibly through a load balancer or VPN), the location of the managed cluster does not matter.

### Q: How do I validate the setup before a real disaster?

Use the non-destructive DR testing procedure in [Section 6](#6-disaster-recovery-testing-non-destructive). Additionally:
- Regularly check the `backup-restore-enabled` policy on both hubs for violations.
- Verify S3 replication status with your storage provider's monitoring tools.
- Periodically test restoring a backup on the passive hub to confirm data integrity.

### Q: What about Hosted Control Planes?

For hosted clusters managed by ACM, the backup/restore process covers the **management configuration** (discovery, import, add-on settings). The hosted control planes and their workloads require a separate backup strategy. See [Backup and restore for hosted control plane overview](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/business_continuity/business-cont-overview#backup-and-restore-for-hosted-control-plane-overview) for details.

### Q: Is Noobaa MCG the recommended approach?

Noobaa MCG is a good choice if you already use OpenShift Data Foundation, because it integrates natively with OpenShift and provides synchronous mirroring. However, it requires ODF licensing and additional infrastructure. For AWS-native deployments, S3 CRR is simpler. For on-premises without ODF, MinIO is a proven and lightweight option.

---

## References

- [ACM 2.15 Business Continuity Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/business_continuity/business-cont-overview#backup-intro)
- [ACM-6583: Document Active/Passive hub configuration with cross-datacenter S3 replication](https://issues.redhat.com/browse/ACM-6583)
- [AWS S3 Cross-Region Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
- [MinIO Bucket Replication](https://min.io/docs/minio/linux/administration/bucket-replication.html)
- [Red Hat OpenShift Data Foundation -- Noobaa MCG](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation)
- [OADP Documentation](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
