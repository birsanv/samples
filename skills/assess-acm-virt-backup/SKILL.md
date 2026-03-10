---
name: assess-acm-virt-backup
description: Assess ACM virtual machine backup/restore configuration and answer user questions about VM DR. Checks OADP, DPA, velero schedules, VM labels, and policy compliance. Use when the user asks about VM backup/restore status, how to back up or restore a VM, virt DR policy issues, or how to install/configure the ACM virt DR feature.
allowed-tools: Bash, Shell, Read, Grep, Glob
---

# Assess ACM Virtual Machine Backup/Restore Configuration

Diagnose the ACM virtual machine DR policy configuration on the currently connected OpenShift cluster. These policies (`acm-dr-virt-install`, `acm-dr-virt-backup`, `acm-dr-virt-restore`) allow backing up and restoring `kubevirt.io/VirtualMachine` resources using OADP and velero.

## Quick Start

Run the diagnostic script. The script accepts an optional cluster context name.

**Cursor:**

```bash
# Run full assessment (current context)
bash <skill-dir>/scripts/assess-virt-backup.sh

# Run full assessment (specific context)
bash <skill-dir>/scripts/assess-virt-backup.sh vb-hub-a

# List all how-to guides
bash <skill-dir>/scripts/assess-virt-backup.sh --guide

# Show a specific guide (e.g. how to back up a VM)
bash <skill-dir>/scripts/assess-virt-backup.sh --guide backup
```

The script requires `oc` CLI, `python3`, and a valid kubeconfig context for an OpenShift cluster with ACM installed. The `--guide` mode does not require cluster access.

## What It Detects

| Check | How |
|-------|-----|
| Cluster identity | `ClusterVersion.spec.clusterID` + hub vs managed cluster |
| Policy placement | `acm-virt-config` label on `ManagedCluster` |
| Configuration ConfigMap | Reads the ConfigMap named by the label for OADP settings |
| OADP installed | Subscription or CSV in the OADP namespace |
| DPA configured | `DataProtectionApplication` with kubevirt, csi plugins, nodeAgent/kopia |
| BSL available | `BackupStorageLocation` with phase=Available |
| Velero credentials | Secret referenced by `credentials_name` exists |
| Schedule cron config | `schedule_hub_config_name` ConfigMap with cron job definitions |
| VMs labeled for backup | `VirtualMachine` resources with `cluster.open-cluster-management.io/backup-vm` label |
| Velero schedules | kubevirt-type velero Schedules created by the backup policy |
| Backup status | Latest velero Backup phase (Completed or not) |
| Restore config | `restore_hub_config_name` ConfigMap and velero Restore status |
| Policy compliance | `acm-dr-virt-install`, `acm-dr-virt-backup`, `acm-dr-virt-restore` per-template compliance |

## Architecture Overview

The virt DR solution is part of ACM 2.15+ and uses three governance policies that are **automatically installed** when the backup component is enabled on `MultiClusterHub` (`cluster-backup: true`). The policies and their ConfigMaps are created in the `open-cluster-management-backup` namespace.

See the [official documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/virtualization/acm-virt#backing-up-restoring-vm).

| Policy | Role |
|--------|------|
| `acm-dr-virt-install` | Installs OADP, copies credentials and config to the cluster, configures DPA |
| `acm-dr-virt-backup` | Creates velero Schedules for VMs with the `backup-vm` label |
| `acm-dr-virt-restore` | Creates velero Restores using the restore ConfigMap |

Policies are placed on any cluster (hub or managed) whose `ManagedCluster` has the `acm-virt-config=<configmap>` label.

### How it gets installed

1. Enable `cluster-backup` on `MultiClusterHub` -- this installs the backup operator and OADP on the hub
2. The backup component automatically creates the three policies and the default ConfigMaps:
   - `acm-dr-virt-config` -- main configuration
   - `acm-dr-virt-schedule-cron` -- predefined cron schedules (managed by the backup component)
   - `acm-dr-virt-restore-config` -- restore operations
3. The admin updates `dpa_spec` in `acm-dr-virt-config` for the storage location
4. The admin labels a `ManagedCluster` with `acm-virt-config=acm-dr-virt-config` to place the policies

**Prerequisite:** OpenShift Virtualization 4.20.1 or later on managed clusters.

### Hub vs managed cluster differences

On the **hub**, the install policy does NOT install OADP or create the DPA -- it assumes OADP was installed via the MCH backup option. It only validates the configuration.

On **managed clusters**, the install policy installs OADP (Subscription, OperatorGroup), copies the velero secret from the hub, and creates the DPA.

## Interpreting Results

### Common issues

| Scenario | Cause | Fix |
|----------|-------|-----|
| No `acm-virt-config` label | Policies not placed on this cluster | `oc label managedcluster <name> acm-virt-config=acm-dr-virt-config` |
| ConfigMap not found | `cluster-backup` not enabled on MCH, or custom name used | Enable backup on MCH; the ConfigMaps are auto-created |
| DPA missing kubevirt plugin | DPA spec in ConfigMap lacks `kubevirt` | Add `kubevirt` to `dpa_spec.configuration.velero.defaultPlugins` |
| DPA nodeAgent not enabled | DataMover won't work | Set `nodeAgent.enable=true` and `uploaderType=kopia` in `dpa_spec` |
| BSL not Available | Storage connectivity issue | Check credentials, bucket name, region, endpoint |
| No VMs labeled | No VMs will be backed up | `oc label vm <name> -n <ns> cluster.open-cluster-management.io/backup-vm=<cron-name>` |
| Invalid cron name on VM | VM uses a schedule name not in the cron ConfigMap | Fix the label value to match a key in `schedule_hub_config_name` ConfigMap |
| Backup not Completed | DataUpload may have failed | Check DataUpload resources and velero logs |
| install policy NonCompliant | OADP, DPA, or credentials issue | Check the violating template name for specifics |
| backup policy NonCompliant | Schedule or backup issue | Check `create-virt-backup` and `check-backup-status-completed` templates |
| restore policy NonCompliant | Restore phase not Completed | Check velero Restore status and logs |

### How backup works

1. Enable `cluster-backup: true` on `MultiClusterHub` -- policies and ConfigMaps are auto-created
2. Update `dpa_spec` in the `acm-dr-virt-config` ConfigMap for your storage location
3. Label the `ManagedCluster` with `acm-virt-config=acm-dr-virt-config`
4. `acm-dr-virt-install` installs OADP and configures DPA on the target cluster
5. VM users add `cluster.open-cluster-management.io/backup-vm: <cron-name>` to their VMs
6. `acm-dr-virt-backup` creates one velero `Schedule` per cron job name, grouping all VMs with the same cron
7. Schedule name: `acm-rho-virt-schedule-<cron-name>` (underscores replaced with dashes)
8. Backup includes VM namespaces, uses `orLabelSelectors` with `app` and `kubevirt.io/domain` keys
9. Uses `snapshotMoveData: true` (CSI with DataMover)

### How restore works

1. Admin creates or updates the `restore_hub_config_name` ConfigMap with:
   - `<clusterID>_restoreName`: name for the velero Restore
   - `<clusterID>_backupName`: name of the velero Backup to restore from
   - `<clusterID>_vmsUID`: space-separated UIDs of VMs to restore
2. `acm-dr-virt-restore` creates the velero Restore targeting the specified VMs by UID
3. VM UIDs are found in the backup's annotations (`uid: namespace--vmname`)

## Manual Investigation

```bash
# ConfigMap referenced by the ManagedCluster label
oc get managedcluster <name> -o jsonpath='{.metadata.labels.acm-virt-config}'

# Read the virt config
oc get configmap <name> -n open-cluster-management-backup -o yaml

# DPA status with plugin details
oc get dataprotectionapplication -n <ns> -o yaml

# VMs labeled for backup
oc get virtualmachines.kubevirt.io --all-namespaces -l cluster.open-cluster-management.io/backup-vm

# Kubevirt velero schedules
oc get schedules.velero.io -n <ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt

# Latest backups
oc get backups.velero.io -n <ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp,ERRORS:.status.errors'

# DataUpload status (for DataMover)
oc get dataupload -n <ns>

# Velero restores
oc get restores.velero.io -n <ns>

# Policy compliance per template
oc get policy.policy.open-cluster-management.io -n open-cluster-management-backup
```

## Key Resources

| Resource | API Group | Namespace |
|----------|-----------|-----------|
| `ManagedCluster` | `cluster.open-cluster-management.io/v1` | cluster-scoped |
| `Policy` | `policy.open-cluster-management.io/v1` | `open-cluster-management-backup` |
| `ConfigMap` (acm-virt-config) | `v1` | `open-cluster-management-backup` |
| `DataProtectionApplication` | `oadp.openshift.io/v1alpha1` | OADP namespace |
| `BackupStorageLocation` | `velero.io/v1` | OADP namespace |
| `Schedule` | `velero.io/v1` | OADP namespace |
| `Backup` | `velero.io/v1` | OADP namespace |
| `Restore` | `velero.io/v1` | OADP namespace |
| `DataUpload` | `velero.io/v2alpha1` | OADP namespace |
| `VirtualMachine` | `kubevirt.io/v1` | any namespace |

## Key Labels

| Label | Purpose |
|-------|---------|
| `acm-virt-config` | On `ManagedCluster` -- triggers policy placement, value is the ConfigMap name |
| `cluster.open-cluster-management.io/backup-vm` | On `VirtualMachine` -- value is the cron schedule name |
| `cluster.open-cluster-management.io/backup-cluster` | On velero `Schedule`/`Backup` -- cluster ID that created it |
| `cluster.open-cluster-management.io/backup-schedule-type` | `kubevirt` for VM backup schedules and backups |

## ConfigMaps (auto-created by backup component)

These ConfigMaps are automatically created in `open-cluster-management-backup` when `cluster-backup` is enabled on MCH. The admin can also create additional ConfigMaps using these as templates.

| ConfigMap | Purpose | Key Properties |
|-----------|---------|----------------|
| `acm-dr-virt-config` | Main config | `backupNS`, `channel`, `dpa_name`, `dpa_spec`, `credentials_name`, `credentials_hub_secret_name`, `schedule_hub_config_name`, `restore_hub_config_name`, `scheduleTTL` |
| `acm-dr-virt-schedule-cron` | Cron definitions (managed by backup component) | Predefined: `hourly`, `every_2_hours`, `every_3_hours`, `every_4_hours`, `every_5_hours`, `every_6_hours`, `twice_a_day`, `daily_8am`, `every_sunday`. You can add new entries but cannot modify or delete existing ones -- they are reconciled by the backup component. |
| `acm-dr-virt-restore-config` | Restore specs | `<clusterID>_restoreName`, `<clusterID>_backupName`, `<clusterID>_vmsUID`, `<clusterID>_namespaceMapping` (optional) |

## Frequently Asked Questions

When the user asks any of the following questions, use the answers below as guidance. Walk the user through the steps interactively, running commands on their behalf to check current state and fill in cluster-specific values.

---

### Q: How do I back up a VM?

The virt DR policies are automatically installed when `cluster-backup` is enabled on `MultiClusterHub`. Walk the user through these steps:

**Step 1 -- Verify `cluster-backup` is enabled on MCH.**

```bash
oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(@.name=="cluster-backup")].enabled}{"\n"}{end}'
```

If not enabled, the admin must enable it -- this installs the backup operator, OADP, and creates the virt DR policies and ConfigMaps automatically.

**Step 2 -- Verify the policies exist on the hub.**

```bash
oc get policy -n open-cluster-management-backup | grep acm-dr-virt
```

The three policies (`acm-dr-virt-install`, `acm-dr-virt-backup`, `acm-dr-virt-restore`) and ConfigMaps (`acm-dr-virt-config`, `acm-dr-virt-schedule-cron`, `acm-dr-virt-restore-config`) should exist.

**Step 3 -- Update the DPA spec in the main ConfigMap.**

The admin must configure `dpa_spec` in `acm-dr-virt-config` with the storage location and credentials:

```bash
oc get configmap acm-dr-virt-config -n open-cluster-management-backup -o yaml
```

Also needed: a **velero credentials Secret** (name matches `credentials_hub_secret_name`) with storage credentials.

**Step 4 -- Label the ManagedCluster to place the policies.**

```bash
oc label managedcluster <cluster-name> acm-virt-config=acm-dr-virt-config
```

**Step 5 -- Wait for the install policy to be compliant.**

Once the label is set, the `acm-dr-virt-install` policy installs OADP and configures the DPA on the target cluster. Check compliance:

```bash
oc get policy acm-dr-virt-install -n open-cluster-management-backup
```

On the hub cluster, the policy only validates (does not install OADP) -- OADP must already be installed via the MCH backup option.

**Step 6 -- Label the VM for backup.**

On the cluster where the VM runs:

```bash
oc label vm <vm-name> -n <vm-namespace> cluster.open-cluster-management.io/backup-vm=<cron-name>
```

The `<cron-name>` must match a key in `acm-dr-virt-schedule-cron`. Predefined schedules: `hourly`, `every_2_hours`, `every_3_hours`, `every_4_hours`, `every_5_hours`, `every_6_hours`, `twice_a_day`, `daily_8am`, `every_sunday`. You can also add custom entries.

```bash
oc get configmap acm-dr-virt-schedule-cron -n open-cluster-management-backup -o yaml
```

**Step 7 -- Verify the velero Schedule was created.**

The `acm-dr-virt-backup` policy creates a velero Schedule named `acm-rho-virt-schedule-<cron-name>`:

```bash
oc get schedules.velero.io -n <oadp-ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt
```

**Step 8 -- Verify backups are completing.**

```bash
oc get backups.velero.io -n <oadp-ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt
oc get dataupload -n <oadp-ns>
```

Run the assessment script to validate everything at once:

```bash
bash <skill-dir>/scripts/assess-virt-backup.sh
```

---

### Q: How do I restore a VM from a backup?

**Step 1 -- Find the backup to restore from.**

List available kubevirt backups on the cluster:

```bash
oc get backups.velero.io -n <oadp-ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp'
```

**Step 2 -- Find the VM UID in the backup annotations.**

Each backed-up VM is recorded as an annotation on the velero Backup in the format `<uid>: <namespace>--<vmname>`:

```bash
oc get backup <backup-name> -n <oadp-ns> -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

**Step 3 -- Update the restore ConfigMap on the hub.**

Edit the restore ConfigMap (name from `restore_hub_config_name`) with the cluster ID, backup name, and VM UIDs:

```bash
oc edit configmap <restore-config-name> -n open-cluster-management-backup
```

Add these keys (replace `<clusterID>` with the target cluster's `spec.clusterID`):

```yaml
data:
  <clusterID>_restoreName: "my-restore-1"
  <clusterID>_backupName: "acm-rho-virt-schedule-daily-8am-20260310080052"
  <clusterID>_vmsUID: "uid1 uid2"
```

Get the cluster ID:

```bash
oc get clusterversion version -o jsonpath='{.spec.clusterID}'
```

**Step 4 -- Wait for the restore policy to create the velero Restore.**

```bash
oc get restores.velero.io -n <oadp-ns>
```

**Step 5 -- Verify the restore completed.**

```bash
oc get restore <restore-name> -n <oadp-ns> -o jsonpath='{.status.phase}'
```

The `check-velero-restore-status` template in the `acm-dr-virt-restore` policy also reports on this.

---

### Q: How do I install the virt DR policies?

The virt DR policies are **automatically installed** when `cluster-backup` is enabled on `MultiClusterHub`. No manual installation is required.

**Step 1 -- Enable `cluster-backup` on MCH (if not already enabled):**

```bash
oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(@.name=="cluster-backup")].enabled}{"\n"}{end}'
```

If not enabled, the admin enables it through the MCH spec. This automatically:
- Installs the backup operator and OADP on the hub
- Creates the three policies: `acm-dr-virt-install`, `acm-dr-virt-backup`, `acm-dr-virt-restore`
- Creates PolicySets: `acm-dr-virt-backup-policyset`, `acm-dr-virt-restore-policyset`
- Creates ConfigMaps: `acm-dr-virt-config`, `acm-dr-virt-schedule-cron`, `acm-dr-virt-restore-config`
- Creates Placement: targets clusters with the `acm-virt-config` label

**Step 2 -- Verify the policies exist:**

```bash
oc get policy -n open-cluster-management-backup | grep acm-dr-virt
```

The policies do nothing until a `ManagedCluster` is labeled with `acm-virt-config=acm-dr-virt-config`.

**Note:** The sample policies at https://github.com/birsanv/samples/tree/main/virt are reference implementations. In ACM 2.15+, use the auto-installed version.

---

### Q: How do I check if my cluster is ready for VM backup?

Run the assessment script:

```bash
bash <skill-dir>/scripts/assess-virt-backup.sh
```

The script checks all prerequisites: OADP installation, DPA configuration (kubevirt plugin, nodeAgent, kopia), BSL availability, credentials, schedule cron config, VM labels, velero schedules, backup status, and policy compliance. Any issues are listed with fix suggestions.

---

### Q: How do I add a new backup schedule (cron job)?

The `acm-dr-virt-schedule-cron` ConfigMap comes with 9 predefined schedules: `hourly`, `every_2_hours`, `every_3_hours`, `every_4_hours`, `every_5_hours`, `every_6_hours`, `twice_a_day`, `daily_8am`, `every_sunday`.

**Important:** The predefined entries are managed by the backup component and cannot be modified or deleted -- they are reconciled. You can **add new entries** only.

To add a custom schedule:

```bash
oc edit configmap acm-dr-virt-schedule-cron -n open-cluster-management-backup
```

Add a new key-value pair:

```yaml
data:
  # predefined entries (do not modify)
  daily_8am: "0 8 * * *"
  hourly: "0 */1 * * *"
  # ...
  # custom entry (add your own)
  every_6h: "0 */6 * * *"
```

The `acm-dr-virt-install` policy copies this ConfigMap to target clusters. VMs can then use the new schedule name:

```bash
oc label vm <vm-name> -n <ns> cluster.open-cluster-management.io/backup-vm=every_6h
```

---

### Q: How do I back up VMs into separate backups (not grouped)?

VMs with the same `backup-vm` label value are grouped into one velero Schedule. To separate them, use different cron schedule names -- even if the actual cron expression is the same:

```yaml
# In the schedule cron ConfigMap:
data:
  vm1_hourly: "0 */1 * * *"
  vm2_hourly: "0 */1 * * *"
```

Then label each VM with its own schedule name:

```bash
oc label vm vm1 -n ns1 cluster.open-cluster-management.io/backup-vm=vm1_hourly
oc label vm vm2 -n ns2 cluster.open-cluster-management.io/backup-vm=vm2_hourly
```

This creates two separate velero Schedules: `acm-rho-virt-schedule-vm1-hourly` and `acm-rho-virt-schedule-vm2-hourly`.

---

### Q: Why is the acm-dr-virt-install policy NonCompliant?

Common causes and how to check:

| Template | Likely cause | How to check |
|----------|-------------|--------------|
| `check-config-file` | ConfigMap, cron CM, restore CM, or credentials secret missing on the hub | `oc get configmap <name> -n open-cluster-management-backup` |
| `check-oadp-channel` | OADP subscription channel mismatch or unhealthy catalog source | `oc get subscription -n <oadp-ns> -o yaml` |
| `check-dpa-config` | DPA missing kubevirt/csi plugins, nodeAgent not enabled, BSL not Available | `oc get dpa -n <oadp-ns> -o yaml` |
| `install-oadp-copy-config` | Enforce template -- fails if resources can't be created | Check operator logs and namespace permissions |

On the hub, the policy does not install OADP. If the hub's OADP is not installed (MCH backup not enabled), the policy will report violations for DPA and BSL.

---

### Q: Why is the acm-dr-virt-backup policy NonCompliant?

| Template | Likely cause | How to check |
|----------|-------------|--------------|
| `create-virt-backup` | Velero CRD not installed or config not propagated yet | Wait for install policy to be Compliant first |
| `check-backup-status-completed` | Latest backup or DataUpload not in Completed phase | `oc get backup -n <oadp-ns> -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt` and `oc get dataupload -n <oadp-ns>` |
| `check-cron-schedule-valid` | A VM uses a `backup-vm` label value not in the cron ConfigMap | Check VM labels vs cron ConfigMap keys |

---

### Q: How do I restore a VM to a different namespace?

The restore ConfigMap supports namespace mapping via the `<clusterID>_namespaceMapping` property:

```yaml
data:
  <clusterID>_restoreName: "my-restore"
  <clusterID>_backupName: "acm-rho-virt-schedule-daily-8am-20260310080052"
  <clusterID>_vmsUID: "uid1"
  <clusterID>_namespaceMapping: "old-namespace=new-namespace"
```

Multiple mappings are space-separated: `"ns1=ns1-new ns2=ns2-new"`.

---

### Q: How do I stop backing up a VM?

Remove the backup label from the VM:

```bash
oc label vm <vm-name> -n <ns> cluster.open-cluster-management.io/backup-vm-
```

The `acm-dr-virt-backup` policy will clean up the velero Schedule if no more VMs reference that cron name.

---

### Q: How do I remove the virt policies from a cluster?

Remove the `acm-virt-config` label from the ManagedCluster:

```bash
oc label managedcluster <cluster-name> acm-virt-config-
```

The policies use `pruneObjectBehavior: DeleteIfCreated`, so resources created by the enforce templates (OADP subscription, DPA, schedules, restores) are cleaned up when the policy is removed.

---

### Q: Can I back up VMs on the hub cluster?

Yes, but with these differences:
- OADP is already installed on the hub when `cluster-backup` is enabled on MCH
- The policy will NOT install OADP or create the DPA on the hub -- it only validates
- The OADP namespace is always `open-cluster-management-backup` on the hub (ignores `backupNS`)
- VM backup schedules are only created on the hub if an ACM hub `BackupSchedule` is already running
- The admin still needs to set `acm-virt-config` on the hub's `ManagedCluster` (usually `local-cluster`)

```bash
oc label managedcluster local-cluster acm-virt-config=acm-dr-virt-config
```

## Policies Reference

Source: auto-installed by ACM when `cluster-backup` is enabled on MCH. Reference implementation: https://github.com/birsanv/samples/tree/main/virt

### acm-dr-virt-install templates

| Template | What it checks |
|----------|---------------|
| `check-config-file` | ConfigMap, restore ConfigMap, cron ConfigMap, and credentials secret all exist on the hub |
| `check-oadp-channel` | OADP subscription channel matches expected version for the OCP release |
| `check-dpa-config` | DPA has kubevirt+csi plugins, nodeAgent with kopia, BSL is Available |
| `install-oadp-copy-config` | (enforce) Copies config to cluster, installs OADP subscription, creates DPA |

### acm-dr-virt-backup templates

| Template | What it checks |
|----------|---------------|
| `create-virt-backup` | (enforce) Creates velero Schedules for VMs with the backup label |
| `check-backup-status-completed` | Latest backup and DataUploads are in Completed phase |
| `check-cron-schedule-valid` | All VM backup label values match a key in the cron ConfigMap |

### acm-dr-virt-restore templates

| Template | What it checks |
|----------|---------------|
| `create-velero-restore` | (enforce) Creates velero Restore from the restore ConfigMap settings |
| `check-velero-restore-status` | Velero Restore phase is Completed |
