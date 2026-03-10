---
name: backup-acm-vm
description: Interactively back up VirtualMachines on an OpenShift cluster using ACM virt DR policies. Discovers all VMs, lets the user select which to back up, sets the backup label, and ensures policies and configuration are in place. Use when the user asks to back up a VM, start VM backup, or set up VM backup on a cluster.
allowed-tools: Bash, Shell, Read, Grep, Glob
---

# Back Up VirtualMachines with ACM Virt DR Policies

Interactive tool that discovers VMs on the current cluster, lets the user choose which ones to back up, and walks through the full setup: verifying policies and ConfigMaps (auto-created when `cluster-backup` is enabled on MCH), labeling the ManagedCluster, and applying backup labels to VMs.

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

The script requires `oc` CLI, `python3`, and a valid kubeconfig context for an OpenShift cluster with OpenShift Virtualization installed.

## What It Does

The script walks through 8 steps interactively:

### Step 1: Discover VirtualMachines

On the hub, uses the ACM search API to discover VMs across all managed clusters. Falls back to local `oc get` if search is unavailable or on managed clusters. VMs are grouped by owning cluster and show:
- Namespace and name
- Running status
- Current backup schedule (if any)
- OS type (from `os.template.kubevirt.io/*` or `kubevirt.io/os` labels)
- VM UID

### Step 2: Remove VMs from backup

Shows only the VMs that already have a backup schedule, grouped by cluster. The user selects which to remove using numbers, filters, or Enter to skip.

### Step 3: Select VMs to back up

Shows all VMs except those just removed, grouped by cluster. VMs already backed up are included (to allow changing their schedule).

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

### Step 4: Choose backup schedule

The `acm-dr-virt-schedule-cron` ConfigMap is auto-created with 9 predefined schedules: `hourly`, `every_2_hours`, `every_3_hours`, `every_4_hours`, `every_5_hours`, `every_6_hours`, `twice_a_day`, `daily_8am`, `every_sunday`. The script lists these for selection.

If the chosen schedule name is not in the cron ConfigMap, the script offers to add it (with a user-supplied cron expression). Note: predefined entries are managed by the backup component and cannot be modified or deleted.

### Step 5: Verify policy infrastructure

The policies and ConfigMaps are auto-created when `cluster-backup` is enabled on MCH. The script verifies they exist:

| Check | If missing |
|-------|-----------|
| **Policies on hub** | Advises enabling `cluster-backup` on MCH (auto-installs policies) |
| **ManagedCluster label** | Offers to set `acm-virt-config=acm-dr-virt-config` |
| **Configuration ConfigMap** | Should exist if `cluster-backup` is enabled; offers to create skeleton as fallback |
| **Schedule cron ConfigMap** | Auto-created with 9 predefined schedules |
| **Restore ConfigMap** | Auto-created empty |
| **DPA and BSL** | Reports status; DPA is created by the policy once config is complete |

### Step 6: Apply backup labels

Applies `cluster.open-cluster-management.io/backup-vm=<schedule>` to each selected VM. Skips VMs already on the same schedule. Shows success/failure for each.

### Step 7: Verify backup policy

After labeling, waits for `acm-dr-virt-backup` to reconcile and reports per-template compliance. If the cron schedule is invalid, offers to add it to the ConfigMap.

### Step 8: Summary and next steps

Reports what was done and what the user should expect (velero Schedule creation, backups starting).

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

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| OpenShift Virtualization 4.20.1+ | `kubevirt.io` CRD must exist |
| ACM 2.15+ with `cluster-backup` enabled | Policies and ConfigMaps are auto-created |
| OADP installed | Auto-installed on hub by MCH; on managed clusters by the virt policy |
| DPA configured | `dpa_spec` must be set in `acm-dr-virt-config` ConfigMap |
| Storage credentials | Velero secret for the backup storage |

## Relationship to Other Skills

- **assess-acm-virt-backup**: Use to diagnose issues after backup is set up. Run when policies are NonCompliant or backups are failing.
- **assess-acm-backup-config**: For the ACM hub-level active-passive backup configuration (different from VM backup).

## Source Policies

Auto-installed by ACM when `cluster-backup` is enabled on MCH. Reference implementation: https://github.com/birsanv/samples/tree/main/virt

Official docs: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/virtualization/acm-virt#backing-up-restoring-vm
