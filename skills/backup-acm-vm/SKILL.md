---
name: backup-acm-vm
description: Interactively back up VirtualMachines on an OpenShift cluster using ACM virt DR policies. Discovers all VMs via the ACM search API, lets the user select which to back up, sets the backup label, and ensures policies and configuration are in place. Use when the user asks to back up a VM, start VM backup, or set up VM backup on a cluster.
allowed-tools: Bash, Shell, Read, Grep, Glob
---

# Back Up VirtualMachines with ACM Virt DR Policies

Interactive tool that discovers VMs across all managed clusters via the ACM search API, lets the user choose which ones to back up, and walks through the full setup: verifying policies, assigning backup configuration ConfigMaps to clusters, and applying backup labels to VMs.

See the [official documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/virtualization/acm-virt#backing-up-restoring-vm).

## Quick Start

Run the interactive script:

**Cursor:**

```bash
# Interactive mode (current context)
bash <skill-dir>/scripts/backup-vm.sh

# Interactive mode (specific context)
bash <skill-dir>/scripts/backup-vm.sh --context vb-hub-a

# List all VMs and their backup status (no changes)
bash <skill-dir>/scripts/backup-vm.sh --list
```

The script requires `oc` CLI, `python3`, and a valid kubeconfig context for an ACM hub cluster.

## What It Does

The script walks through 9 steps interactively:

### Step 1: Discover VirtualMachines

Uses the ACM search API (via `oc port-forward` to the search service) to discover VMs across **all** managed clusters from the hub. If search is unavailable or returns no VMs, the script exits with a warning. VMs are displayed showing:
- Cluster, namespace, and name
- Running status
- Current backup schedule (if any)
- OS type (from `os.template.kubevirt.io/*` or `kubevirt.io/os` labels, or inferred from VM name)

### Step 2: Remove VMs from backup

Shows only the VMs that already have a backup schedule. The user selects which to remove using numbers, filters, or Enter to skip. Input is validated with retry on invalid selections.

For remote clusters without a direct kubeconfig context, labels are removed via ManifestWork (ServerSideApply) through the hub.

### Step 3: Select VMs to back up

Shows all VMs except those just removed. VMs already backed up are included (to allow changing their schedule). Input is validated with retry.

**Selection syntax** (used in both steps 2 and 3):

| Syntax | Example | Description |
|--------|---------|-------------|
| Numbers | `1,2,3` | Select by displayed index |
| `all` | `all` | Select all listed VMs |
| `cluster=<name>` | `cluster=spoke1` | All VMs on that cluster |
| `ns=<namespace>` | `ns=default` | All VMs in that namespace |
| `os=<type>` | `os=fedora` | All VMs with that OS type |
| `label=<key>=<val>` | `label=app=web` | All VMs with that label |

Filters can be combined with spaces: `ns=default os=fedora`

### Step 4: Verify backup prerequisites

Runs immediately after VM selection, checking only the clusters that own the selected VMs:

#### Step 4a: Check ManagedCluster backup configuration

Verifies each cluster owning selected VMs has the `acm-virt-config` label pointing to a configuration ConfigMap.

#### Step 4b: Assign backup configuration to clusters

For clusters missing the label:
- Lists existing virt ConfigMaps in the backup namespace (any CM with both `backupNS` and `dpa_spec` keys, excluding internal `--cls` copies) and shows which clusters use each one.
- The user can select an existing ConfigMap or create a new one.
- When creating a new ConfigMap, the user picks an existing CM to copy from (for pre-populated DPA settings), then edits the copy for the target cluster's specific configuration (e.g. different cloud provider, bucket, or credentials).
- Labels the ManagedCluster with the chosen ConfigMap name.

#### Step 4c: Check OADP and DPA

Verifies DataProtectionApplication and BackupStorageLocation exist on each target cluster. If a managed cluster is itself a hub (detected via `product.open-cluster-management.io` clusterClaim), advises that OADP is managed by its own MCH.

#### Step 4d: Check install policy compliance

Verifies `acm-dr-virt-install` is Compliant on each target cluster. Waits for reconciliation if needed, shows per-template status, and offers targeted fix suggestions (DPA patching, ConfigMap editing, etc.).

### Step 5: Choose backup schedule

The `acm-dr-virt-schedule-cron` ConfigMap is auto-created with 9 predefined schedules: `hourly`, `every_2_hours`, `every_3_hours`, `every_4_hours`, `every_5_hours`, `every_6_hours`, `twice_a_day`, `daily_8am`, `every_sunday`. The script lists these for selection.

If the chosen schedule name is not in the cron ConfigMap, the script offers to add it (with a user-supplied cron expression). Note: predefined entries are managed by the backup component and cannot be modified or deleted.

### Step 6: Apply backup labels

Applies `cluster.open-cluster-management.io/backup-vm=<schedule>` to each selected VM. Skips VMs already on the same schedule. Shows success/failure for each.

For remote clusters without a direct kubeconfig context, labels are applied via ManifestWork (ServerSideApply) through the hub. The ManifestWork is created, waited on until applied, then cleaned up with `deleteOption: Orphan` so the label persists.

### Step 7: Verify backup policy

After labeling, waits for `acm-dr-virt-backup` to reconcile and reports per-template compliance. If the cron schedule is invalid, offers to add it to the ConfigMap.

### Step 8: Summary and next steps

Reports what was done and what the user should expect (velero Schedule creation, backups starting).

### Step 9: Backup Status

Reads the `acm-dr-virt-backup` policy for each virt-labeled cluster and displays:
- Overall policy compliance (colored bullet)
- Per-template compliance status (✓/✗) with condition messages
- For non-compliant templates: violations in red, notifications in dim text

This section runs even if no VMs were selected (e.g. user pressed Enter to skip), providing a status overview of all configured clusters.

## When to Use This Skill

- User says "back up my VM" or "I want to back up a VM"
- User wants to know which VMs are on the cluster and their backup status
- User wants to enable VM backup on a cluster for the first time
- User wants to add more VMs to an existing backup schedule

## Key Concepts

- VMs are backed up by the `acm-dr-virt-backup` ACM policy
- The policy creates velero Schedules for VMs with the `cluster.open-cluster-management.io/backup-vm` label
- The label value is the name of a cron schedule defined in a ConfigMap
- VMs with the same label value are grouped into one velero Schedule
- Backup uses CSI with DataMover (`snapshotMoveData: true`)
- On remote clusters without direct kubeconfig access, VM labels are applied via ManifestWork with ServerSideApply

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| OpenShift Virtualization 4.20.1+ | `kubevirt.io` CRD must exist |
| ACM 2.15+ with `cluster-backup` enabled | Policies and ConfigMaps are auto-created |
| ACM Search API | Must be functional on the hub for VM discovery |
| OADP installed | Auto-installed on hub by MCH; on managed clusters by the virt policy |
| DPA configured | `dpa_spec` must be set in the virt configuration ConfigMap |
| Storage credentials | Velero secret for the backup storage |

## Relationship to Other Skills

- **assess-acm-virt-backup**: Use to diagnose issues after backup is set up. Run when policies are NonCompliant or backups are failing.
- **assess-acm-backup-config**: For the ACM hub-level active-passive backup configuration (different from VM backup).

## Source Policies

Auto-installed by ACM when `cluster-backup` is enabled on MCH. Reference implementation: https://github.com/birsanv/samples/tree/main/virt

Official docs: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/virtualization/acm-virt#backing-up-restoring-vm
