#!/usr/bin/env bash
# ACM Virtual Machine Backup/Restore Assessment Script
# Assesses whether the ACM virt DR policies (acm-dr-virt-install, acm-dr-virt-backup,
# acm-dr-virt-restore) are correctly configured for backing up or restoring VMs on this cluster.
#
# Usage:
#   assess-virt-backup.sh [--context <name>] [<context>]   Run full assessment
#   assess-virt-backup.sh --guide <topic>                  Show how-to guide
#   assess-virt-backup.sh --guide                          List available topics
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

# ============================================================
# Guide / FAQ system
# ============================================================

GUIDE_TOPICS="backup restore install check schedule separate-backups stop-backup remove-policies hub-backup install-noncompliant backup-noncompliant restore-namespace"

guide_list() {
  printf "${BOLD}${CYAN}Available guide topics:${RESET}\n\n"
  printf "  ${BOLD}backup${RESET}              How do I back up a VM?\n"
  printf "  ${BOLD}restore${RESET}             How do I restore a VM from a backup?\n"
  printf "  ${BOLD}install${RESET}             How do I install the virt DR policies?\n"
  printf "  ${BOLD}check${RESET}               How do I check if my cluster is ready for VM backup?\n"
  printf "  ${BOLD}schedule${RESET}            How do I add a new backup schedule (cron job)?\n"
  printf "  ${BOLD}separate-backups${RESET}    How do I back up VMs into separate backups?\n"
  printf "  ${BOLD}stop-backup${RESET}         How do I stop backing up a VM?\n"
  printf "  ${BOLD}remove-policies${RESET}     How do I remove the virt policies from a cluster?\n"
  printf "  ${BOLD}hub-backup${RESET}          Can I back up VMs on the hub cluster?\n"
  printf "  ${BOLD}install-noncompliant${RESET} Why is acm-dr-virt-install NonCompliant?\n"
  printf "  ${BOLD}backup-noncompliant${RESET}  Why is acm-dr-virt-backup NonCompliant?\n"
  printf "  ${BOLD}restore-namespace${RESET}   How do I restore a VM to a different namespace?\n"
  printf "\nUsage: %s --guide <topic>\n" "$(basename "$0")"
}

guide_backup() {
  cat <<'GUIDE'

=== How do I back up a VM? ===

The virt DR policies are automatically installed when cluster-backup is
enabled on MultiClusterHub (MCH). Follow these steps:

Step 1 -- Verify cluster-backup is enabled on MCH.

    oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(@.name=="cluster-backup")].enabled}{"\n"}{end}'

  If not enabled, the admin must enable it. This installs the backup
  operator, OADP, and creates the virt DR policies + ConfigMaps.

Step 2 -- Verify the policies and ConfigMaps exist on the hub.

    oc get policy -n open-cluster-management-backup | grep acm-dr-virt

  Expected: acm-dr-virt-install, acm-dr-virt-backup, acm-dr-virt-restore

    oc get configmap -n open-cluster-management-backup | grep acm-dr-virt

  Expected: acm-dr-virt-config, acm-dr-virt-schedule-cron,
            acm-dr-virt-restore-config

Step 3 -- Update the DPA spec in the main ConfigMap.

  The admin must configure dpa_spec in acm-dr-virt-config with storage
  location and credentials:

    oc get configmap acm-dr-virt-config -n open-cluster-management-backup -o yaml

  Also needed: a velero credentials Secret (name from
  credentials_hub_secret_name) with your storage credentials.

Step 4 -- Label the ManagedCluster to place the policies.

    oc label managedcluster <cluster-name> acm-virt-config=acm-dr-virt-config

Step 5 -- Wait for the install policy to become compliant.

    oc get policy acm-dr-virt-install -n open-cluster-management-backup

  On hub: validates only (OADP already installed by MCH).
  On managed clusters: installs OADP, copies credentials, creates DPA.

Step 6 -- Label the VM for backup.

    oc label vm <vm-name> -n <vm-namespace> \
      cluster.open-cluster-management.io/backup-vm=<cron-name>

  Predefined schedules in acm-dr-virt-schedule-cron:
    hourly, every_2_hours, every_3_hours, every_4_hours,
    every_5_hours, every_6_hours, twice_a_day, daily_8am, every_sunday

  You can also add custom entries (but cannot modify the predefined ones).

Step 7 -- Verify the velero Schedule was created.

    oc get schedules.velero.io -n <oadp-ns> \
      -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt

Step 8 -- Verify backups are completing.

    oc get backups.velero.io -n <oadp-ns> \
      -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt
    oc get dataupload -n <oadp-ns>

Prerequisite: OpenShift Virtualization 4.20.1 or later on managed clusters.

Official docs:
  https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/virtualization/acm-virt#backing-up-restoring-vm

GUIDE
}

guide_restore() {
  cat <<'GUIDE'

=== How do I restore a VM from a backup? ===

Step 1 -- Find the backup to restore from.

    oc get backups.velero.io -n <oadp-ns> \
      -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startTimestamp'

Step 2 -- Find the VM UID in the backup annotations.

  Each backed-up VM is recorded as:  <uid>: <namespace>--<vmname>

    oc get backup <backup-name> -n <oadp-ns> \
      -o jsonpath='{.metadata.annotations}' | python3 -m json.tool

Step 3 -- Update the restore ConfigMap on the hub.

    oc edit configmap <restore-config-name> -n open-cluster-management-backup

  Add (replace <clusterID> with the target cluster's clusterID):

    data:
      <clusterID>_restoreName: "my-restore-1"
      <clusterID>_backupName: "<backup-name-from-step-1>"
      <clusterID>_vmsUID: "<uid1> <uid2>"

  Get the cluster ID:
    oc get clusterversion version -o jsonpath='{.spec.clusterID}'

Step 4 -- Wait for the restore policy to create the velero Restore.

    oc get restores.velero.io -n <oadp-ns>

Step 5 -- Verify the restore completed.

    oc get restore <restore-name> -n <oadp-ns> -o jsonpath='{.status.phase}'

GUIDE
}

guide_install() {
  cat <<'GUIDE'

=== How do I install the virt DR policies? ===

The virt DR policies are AUTOMATICALLY installed when cluster-backup is
enabled on MultiClusterHub. No manual installation is required.

Step 1 -- Enable cluster-backup on MCH (if not already enabled).

    oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(@.name=="cluster-backup")].enabled}{"\n"}{end}'

  This automatically creates:
    - Backup operator and OADP on the hub
    - Policies: acm-dr-virt-install, acm-dr-virt-backup, acm-dr-virt-restore
    - PolicySets: acm-dr-virt-backup-policyset, acm-dr-virt-restore-policyset
    - ConfigMaps: acm-dr-virt-config, acm-dr-virt-schedule-cron,
                  acm-dr-virt-restore-config
    - Placement: targets clusters with the acm-virt-config label

Step 2 -- Verify they exist:

    oc get policy -n open-cluster-management-backup | grep acm-dr-virt

The policies do nothing until a ManagedCluster is labeled:

    oc label managedcluster <name> acm-virt-config=acm-dr-virt-config

Note: The sample policies at https://github.com/birsanv/samples/tree/main/virt
are reference implementations. In ACM 2.15+, use the auto-installed version.

GUIDE
}

guide_check() {
  cat <<'GUIDE'

=== How do I check if my cluster is ready for VM backup? ===

Run this script without --guide to perform a full assessment:

    assess-virt-backup.sh [--context <name>]

The script checks all prerequisites:
  - OADP installation and version
  - DPA configuration (kubevirt plugin, nodeAgent, kopia)
  - BackupStorageLocation availability
  - Velero credentials
  - Schedule cron ConfigMap
  - VM backup labels
  - Velero schedules and backup status
  - Policy compliance (all 3 policies, per-template)

Any issues are listed with fix suggestions.

GUIDE
}

guide_schedule() {
  cat <<'GUIDE'

=== How do I add a new backup schedule (cron job)? ===

The acm-dr-virt-schedule-cron ConfigMap comes with 9 predefined schedules:
  hourly, every_2_hours, every_3_hours, every_4_hours, every_5_hours,
  every_6_hours, twice_a_day, daily_8am, every_sunday

IMPORTANT: The predefined entries are managed by the backup component and
cannot be modified or deleted -- they are reconciled. You can ADD new
entries only.

To add a custom schedule:

    oc edit configmap acm-dr-virt-schedule-cron -n open-cluster-management-backup

Add a new key-value pair (do not modify existing ones):

    data:
      # predefined (do not modify)
      daily_8am: "0 8 * * *"
      hourly: "0 */1 * * *"
      ...
      # custom entry
      every_6h: "0 */6 * * *"

The acm-dr-virt-install policy copies this to target clusters.
VMs can then use the new schedule name:

    oc label vm <vm-name> -n <ns> \
      cluster.open-cluster-management.io/backup-vm=every_6h

GUIDE
}

guide_separate_backups() {
  cat <<'GUIDE'

=== How do I back up VMs into separate backups (not grouped)? ===

VMs with the same backup-vm label value are grouped into one velero
Schedule. To separate them, use different cron schedule names even if
the actual cron expression is the same:

In the schedule cron ConfigMap:

    data:
      vm1_hourly: "0 */1 * * *"
      vm2_hourly: "0 */1 * * *"

Then label each VM with its own name:

    oc label vm vm1 -n ns1 cluster.open-cluster-management.io/backup-vm=vm1_hourly
    oc label vm vm2 -n ns2 cluster.open-cluster-management.io/backup-vm=vm2_hourly

This creates two velero Schedules:
  acm-rho-virt-schedule-vm1-hourly
  acm-rho-virt-schedule-vm2-hourly

GUIDE
}

guide_stop_backup() {
  cat <<'GUIDE'

=== How do I stop backing up a VM? ===

Remove the backup label from the VM:

    oc label vm <vm-name> -n <ns> cluster.open-cluster-management.io/backup-vm-

The acm-dr-virt-backup policy will clean up the velero Schedule
automatically if no more VMs reference that cron name.

GUIDE
}

guide_remove_policies() {
  cat <<'GUIDE'

=== How do I remove the virt policies from a cluster? ===

Remove the acm-virt-config label from the ManagedCluster:

    oc label managedcluster <cluster-name> acm-virt-config-

The policies use pruneObjectBehavior: DeleteIfCreated, so resources
created by the enforce templates (OADP subscription, DPA, schedules,
restores) are cleaned up when the policy is removed.

GUIDE
}

guide_hub_backup() {
  cat <<'GUIDE'

=== Can I back up VMs on the hub cluster? ===

Yes, but with these differences:

  - OADP is already installed on the hub when cluster-backup is enabled on MCH
  - The policy does NOT install OADP or create the DPA on hub -- validates only
  - OADP namespace is always open-cluster-management-backup (ignores backupNS)
  - VM schedules are only created if an ACM hub BackupSchedule is running
  - The admin still labels the hub's ManagedCluster:

    oc label managedcluster local-cluster acm-virt-config=acm-dr-virt-config

GUIDE
}

guide_install_noncompliant() {
  cat <<'GUIDE'

=== Why is acm-dr-virt-install NonCompliant? ===

Common causes by template:

  check-config-file
    ConfigMap, cron CM, restore CM, or credentials secret missing on the hub.
    Check:  oc get configmap <name> -n open-cluster-management-backup
            oc get secret <name> -n open-cluster-management-backup

  check-oadp-channel
    OADP subscription channel mismatch or unhealthy catalog source.
    Check:  oc get subscription -n <oadp-ns> -o yaml

  check-dpa-config
    DPA missing kubevirt/csi plugins, nodeAgent not enabled, BSL not Available.
    Check:  oc get dataprotectionapplication -n <oadp-ns> -o yaml

  install-oadp-copy-config
    Enforce template -- fails if resources cannot be created.
    Check operator logs and namespace permissions.

On the hub, the policy does NOT install OADP. If OADP is not installed
(MCH backup not enabled), DPA and BSL templates will report violations.

GUIDE
}

guide_backup_noncompliant() {
  cat <<'GUIDE'

=== Why is acm-dr-virt-backup NonCompliant? ===

Common causes by template:

  create-virt-backup
    Velero CRD not installed or config not propagated yet.
    Wait for acm-dr-virt-install to become Compliant first.

  check-backup-status-completed
    Latest backup or DataUpload not in Completed phase.
    Check:  oc get backup -n <oadp-ns> \
              -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt
            oc get dataupload -n <oadp-ns>

  check-cron-schedule-valid
    A VM uses a backup-vm label value not defined in the cron ConfigMap.
    Check VM labels vs cron ConfigMap keys:
      oc get vm --all-namespaces -l cluster.open-cluster-management.io/backup-vm
      oc get configmap acm-dr-virt-schedule-cron--cls -n <oadp-ns> -o yaml

GUIDE
}

guide_restore_namespace() {
  cat <<'GUIDE'

=== How do I restore a VM to a different namespace? ===

The restore ConfigMap supports namespace mapping via the
<clusterID>_namespaceMapping property:

    data:
      <clusterID>_restoreName: "my-restore"
      <clusterID>_backupName: "<backup-name>"
      <clusterID>_vmsUID: "<uid1>"
      <clusterID>_namespaceMapping: "old-namespace=new-namespace"

Multiple mappings are space-separated:
  "ns1=ns1-new ns2=ns2-new"

GUIDE
}

show_guide() {
  local topic="$1"
  case "$topic" in
    backup)               guide_backup ;;
    restore)              guide_restore ;;
    install)              guide_install ;;
    check)                guide_check ;;
    schedule)             guide_schedule ;;
    separate-backups)     guide_separate_backups ;;
    stop-backup)          guide_stop_backup ;;
    remove-policies)      guide_remove_policies ;;
    hub-backup)           guide_hub_backup ;;
    install-noncompliant) guide_install_noncompliant ;;
    backup-noncompliant)  guide_backup_noncompliant ;;
    restore-namespace)    guide_restore_namespace ;;
    *)
      printf "${RED}Unknown topic: %s${RESET}\n\n" "$topic"
      guide_list
      exit 1 ;;
  esac
}

# --- Parse arguments ---
CTX=""
GUIDE_TOPIC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      CTX="$2"; shift 2 ;;
    --context=*)
      CTX="${1#--context=}"; shift ;;
    --guide)
      if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
        GUIDE_TOPIC="$2"; shift 2
      else
        guide_list; exit 0
      fi ;;
    --guide=*)
      GUIDE_TOPIC="${1#--guide=}"; shift ;;
    -h|--help)
      printf "Usage: %s [--context <name>] [<context>]\n" "$(basename "$0")"
      printf "       %s --guide [<topic>]\n\n" "$(basename "$0")"
      printf "  --context <name>   kubeconfig context to use\n"
      printf "  <context>          positional shorthand for --context\n"
      printf "  --guide [<topic>]  show how-to guide (omit topic to list all)\n"
      printf "  (no argument)      use current kubeconfig context, run assessment\n"
      exit 0 ;;
    *)
      CTX="$1"; shift ;;
  esac
done

if [[ -n "$GUIDE_TOPIC" ]]; then
  show_guide "$GUIDE_TOPIC"
  exit 0
fi

OC_CTX=()
if [[ -n "$CTX" ]]; then
  OC_CTX=(--context "$CTX")
fi

run_oc() { oc "${OC_CTX[@]}" "$@"; }

declare -A MC_CONTEXT_MAP=()

run_oc_on_cluster() {
  local cluster="$1"; shift
  local ctx="${MC_CONTEXT_MAP[$cluster]:-}"
  if [[ -n "$ctx" ]]; then
    oc --context "$ctx" "$@"
  else
    run_oc "$@"
  fi
}

header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }
info()   { printf "${GREEN}[OK]${RESET} %s\n" "$1"; }
warn()   { printf "${YELLOW}[WARN]${RESET} %s\n" "$1"; }
err()    { printf "${RED}[ERROR]${RESET} %s\n" "$1"; }

ISSUES=()
add_issue() {
  local level="$1" msg="$2" fix="${3:-none}"
  ISSUES+=("${level}|${msg}|${fix}")
}

# ============================================================
# Pre-flight
# ============================================================
header "Pre-flight Checks"

if ! command -v oc &>/dev/null; then
  err "oc CLI not found"; exit 1
fi

if ! run_oc whoami &>/dev/null; then
  if [[ -n "$CTX" ]]; then
    err "Cannot connect using context '$CTX'"
  else
    err "Not logged in to an OpenShift cluster"
  fi
  exit 1
fi

if [[ -n "$CTX" ]]; then
  CLUSTER_NAME="$CTX"
else
  CLUSTER_NAME=$(oc config current-context 2>/dev/null || echo "unknown")
fi
printf "Cluster context: %s\n" "$CLUSTER_NAME"

# ============================================================
# 1. Cluster Identity
# ============================================================
header "1. Cluster Identity"

CLUSTER_ID=$(run_oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
if [[ -z "$CLUSTER_ID" ]]; then
  warn "Could not read ClusterVersion.spec.clusterID"
  CLUSTER_ID="unknown"
fi
printf "Cluster ID: ${BOLD}%s${RESET}\n" "$CLUSTER_ID"

IS_HUB=false
if run_oc get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null; then
  IS_HUB=true
  info "This is an ACM hub cluster"
else
  printf "This is a managed cluster (no MultiClusterHub CRD)\n"
fi

# ============================================================
# 2. ManagedClusters with acm-virt-config label
# ============================================================
header "2. Policy Placement (acm-virt-config label)"

LOCAL_MC=""
VIRT_CONFIG_NAME=""
declare -a VIRT_CLUSTER_LIST=()

if [[ "$IS_HUB" == true ]]; then
  LOCAL_MC=$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "local-cluster")

  VIRT_MC_JSON=$(run_oc get managedclusters -l acm-virt-config -o json 2>/dev/null || echo '{"items":[]}')
  VIRT_CLUSTER_LIST=( $(echo "$VIRT_MC_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for mc in items:
    print(mc['metadata']['name'])
" 2>/dev/null) )

  if [[ ${#VIRT_CLUSTER_LIST[@]} -eq 0 ]]; then
    warn "No ManagedClusters with acm-virt-config label found."
    printf "  Virt policies are not placed on any cluster.\n"
    printf "  To enable: oc label managedcluster <name> acm-virt-config=acm-dr-virt-config\n"
    add_issue "WARN" \
      "No acm-virt-config label on any ManagedCluster. Virt policies are not placed." \
      "oc label managedcluster <name> acm-virt-config=acm-dr-virt-config"
  else
    VIRT_CONFIG_NAME=$(echo "$VIRT_MC_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if items:
    print(items[0].get('metadata', {}).get('labels', {}).get('acm-virt-config', ''))
" 2>/dev/null || echo "")

    info "${#VIRT_CLUSTER_LIST[@]} cluster(s) with acm-virt-config label"
    for vc in "${VIRT_CLUSTER_LIST[@]}"; do
      vc_cfg=$(echo "$VIRT_MC_JSON" | python3 -c "
import sys, json
name = '$vc'
items = json.load(sys.stdin).get('items', [])
for mc in items:
    if mc['metadata']['name'] == name:
        print(mc.get('metadata', {}).get('labels', {}).get('acm-virt-config', ''))
        break
" 2>/dev/null || echo "")
      printf "  ${CYAN}%s${RESET}  config=%s\n" "$vc" "$vc_cfg"
    done

    # Build context map for managed clusters
    ALL_CONTEXTS=$(oc config get-contexts -o name 2>/dev/null || echo "")
    for vc in "${VIRT_CLUSTER_LIST[@]}"; do
      if [[ "$vc" == "$LOCAL_MC" ]]; then
        continue
      fi
      for ctx_name in $ALL_CONTEXTS; do
        if [[ "$ctx_name" == "$vc" ]]; then
          MC_CONTEXT_MAP["$vc"]="$ctx_name"
          break
        fi
      done
      if [[ -z "${MC_CONTEXT_MAP[$vc]:-}" ]]; then
        for ctx_name in $ALL_CONTEXTS; do
          if echo "$ctx_name" | grep -qi "$vc"; then
            MC_CONTEXT_MAP["$vc"]="$ctx_name"
            break
          fi
        done
      fi
      if [[ -n "${MC_CONTEXT_MAP[$vc]:-}" ]]; then
        printf "  (context for %s: %s)\n" "$vc" "${MC_CONTEXT_MAP[$vc]}"
      else
        printf "  ${YELLOW}(no kubeconfig context for %s -- remote checks skipped)${RESET}\n" "$vc"
      fi
    done
  fi
else
  MC_JSON=$(run_oc get managedclusters --no-headers 2>/dev/null || echo "")
  if [[ -n "$MC_JSON" ]]; then
    MC_NAME=$(echo "$MC_JSON" | awk '{print $1;exit}')
    VIRT_CONFIG_NAME=$(run_oc get managedcluster "$MC_NAME" -o jsonpath='{.metadata.labels.acm-virt-config}' 2>/dev/null || echo "")
    if [[ -n "$VIRT_CONFIG_NAME" ]]; then
      VIRT_CLUSTER_LIST=("$MC_NAME")
      LOCAL_MC="$MC_NAME"
      info "acm-virt-config label found: ${VIRT_CONFIG_NAME} (on $MC_NAME)"
    fi
  fi
  if [[ -z "$VIRT_CONFIG_NAME" ]]; then
    warn "No acm-virt-config label found."
    printf "  To enable: oc label managedcluster <name> acm-virt-config=acm-dr-virt-config\n"
    add_issue "WARN" \
      "No acm-virt-config label on ManagedCluster. Virt policies are not placed on this cluster." \
      "oc label managedcluster <name> acm-virt-config=acm-dr-virt-config"
  fi
fi

# ============================================================
# 3. Configuration ConfigMap
# ============================================================
header "3. Configuration ConfigMap"

BACKUP_NS="open-cluster-management-backup"
SCHEDULE_CRON_CM=""
RESTORE_CM=""
DPA_NAME=""
CRED_SECRET=""
CRED_HUB_SECRET=""

if [[ -n "$VIRT_CONFIG_NAME" ]]; then
  CONFIG_JSON=$(run_oc get configmap "$VIRT_CONFIG_NAME" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
  if [[ -z "$CONFIG_JSON" ]]; then
    CONFIG_JSON=$(run_oc get configmap "$VIRT_CONFIG_NAME" -n open-cluster-management-backup -o json 2>/dev/null || echo "")
  fi

  if [[ -z "$CONFIG_JSON" ]]; then
    err "ConfigMap '${VIRT_CONFIG_NAME}' not found in namespace ${BACKUP_NS}"
    add_issue "ERROR" \
      "ConfigMap '${VIRT_CONFIG_NAME}' referenced by acm-virt-config label does not exist in ${BACKUP_NS}." \
      "Ensure cluster-backup is enabled on MCH (auto-creates acm-dr-virt-config). If using a custom name, create it manually."
  else
    info "ConfigMap '${VIRT_CONFIG_NAME}' found"

    BACKUP_NS=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
print(d.get('backupNS', 'open-cluster-management-backup'))
" 2>/dev/null || echo "open-cluster-management-backup")

    if [[ "$IS_HUB" == true ]]; then
      BACKUP_NS="open-cluster-management-backup"
    fi
    printf "OADP namespace: ${BOLD}%s${RESET}\n" "$BACKUP_NS"

    SCHEDULE_CRON_CM=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('schedule_hub_config_name', ''))
" 2>/dev/null || echo "")

    RESTORE_CM=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('restore_hub_config_name', ''))
" 2>/dev/null || echo "")

    DPA_NAME=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('dpa_name', ''))
" 2>/dev/null || echo "")

    CRED_SECRET=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('credentials_name', ''))
" 2>/dev/null || echo "")

    CRED_HUB_SECRET=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('credentials_hub_secret_name', ''))
" 2>/dev/null || echo "")

    DPA_SPEC=$(echo "$CONFIG_JSON" | python3 -c "
import sys, json; print(json.load(sys.stdin).get('data', {}).get('dpa_spec', ''))
" 2>/dev/null || echo "")

    printf "  schedule_hub_config_name: %s\n" "${SCHEDULE_CRON_CM:-<not set>}"
    printf "  restore_hub_config_name:  %s\n" "${RESTORE_CM:-<not set>}"
    printf "  dpa_name:                 %s\n" "${DPA_NAME:-<not set>}"
    printf "  credentials_name:         %s\n" "${CRED_SECRET:-<not set>}"
    printf "  credentials_hub_secret:   %s\n" "${CRED_HUB_SECRET:-<not set>}"

    if [[ -z "$DPA_SPEC" ]]; then
      add_issue "WARN" \
        "dpa_spec is empty in ConfigMap '${VIRT_CONFIG_NAME}'. DPA will not be created on managed clusters." \
        "Set dpa_spec with backup locations and OADP configuration."
    fi
  fi
else
  printf "Skipped (no acm-virt-config label).\n"
fi

# ============================================================
# 4-7. OADP / DPA / BSL / Credentials (per virt-labeled cluster)
# ============================================================
header "4-7. OADP Stack (per cluster)"

if [[ ${#VIRT_CLUSTER_LIST[@]} -eq 0 ]]; then
  printf "Skipped (no virt-labeled clusters).\n"
else
  # Hub-level credential check (once)
  if [[ -n "$CRED_HUB_SECRET" && "$IS_HUB" == true ]]; then
    if run_oc get secret "$CRED_HUB_SECRET" -n "$BACKUP_NS" &>/dev/null; then
      info "Hub secret '$CRED_HUB_SECRET' exists (will be copied to managed clusters)"
    else
      warn "Hub secret '$CRED_HUB_SECRET' NOT found in $BACKUP_NS"
      add_issue "WARN" \
        "Hub credentials secret '${CRED_HUB_SECRET}' missing. Managed clusters will not get storage credentials." \
        "Create secret '${CRED_HUB_SECRET}' in ${BACKUP_NS} with storage credentials."
    fi
  fi

  for TC in "${VIRT_CLUSTER_LIST[@]}"; do
    printf "\n  ${BOLD}${CYAN}--- Cluster: %s ---${RESET}\n" "$TC"

    TC_IS_HUB=false
    if [[ "$TC" == "$LOCAL_MC" ]]; then
      TC_IS_HUB="$IS_HUB"
    elif [[ -n "${MC_CONTEXT_MAP[$TC]:-}" ]]; then
      if run_oc_on_cluster "$TC" get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null; then
        TC_IS_HUB=true
      fi
    else
      printf "  ${YELLOW}(no kubeconfig context -- cannot validate OADP stack remotely)${RESET}\n"
      continue
    fi

    # --- 4. OADP Installation ---
    printf "\n  ${BOLD}OADP Installation:${RESET}\n"
    TC_OADP_OK=false

    if ! run_oc_on_cluster "$TC" get namespace "$BACKUP_NS" &>/dev/null; then
      err "Namespace $BACKUP_NS does not exist on '$TC'"
      add_issue "ERROR" \
        "OADP namespace '${BACKUP_NS}' does not exist on '${TC}'." \
        "Install OADP in ${BACKUP_NS} on ${TC}."
    else
      OADP_SUB=$(run_oc_on_cluster "$TC" get subscriptions.operators.coreos.com -n "$BACKUP_NS" -o json 2>/dev/null || echo '{"items":[]}')
      OADP_SUB_LINE1=$(echo "$OADP_SUB" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
oadp = [s for s in items if s.get('spec',{}).get('name','') == 'redhat-oadp-operator']
print(len(oadp))
for s in oadp:
    name = s['metadata']['name']
    channel = s.get('spec',{}).get('channel','?')
    csv = s.get('status',{}).get('installedCSV','?')
    print(f'    {name}: channel={channel} csv={csv}')
" 2>/dev/null || echo "0")

      SUB_COUNT=$(echo "$OADP_SUB_LINE1" | head -1)
      SUB_DETAILS=$(echo "$OADP_SUB_LINE1" | tail -n +2)

      if [[ "$SUB_COUNT" -gt 0 ]]; then
        TC_OADP_OK=true
        info "OADP subscription found on '$TC'"
        [[ -n "$SUB_DETAILS" ]] && echo "$SUB_DETAILS"
      else
        OADP_CSV_COUNT=$(run_oc_on_cluster "$TC" get csv -n "$BACKUP_NS" --no-headers 2>/dev/null | grep -c "oadp" || true)
        if [[ "$OADP_CSV_COUNT" -gt 0 ]]; then
          TC_OADP_OK=true
          info "OADP CSV found on '$TC' (installed by MCH/policy)"
        else
          if [[ "$TC_IS_HUB" == true ]]; then
            err "OADP not installed on '$TC' (hub). Enable cluster-backup on MCH."
            add_issue "ERROR" \
              "OADP not installed on '${TC}' (hub)." \
              "Enable cluster-backup on the MCH of '${TC}'."
          else
            err "OADP not installed on '$TC'"
            add_issue "ERROR" \
              "OADP not installed on '${TC}'." \
              "The acm-dr-virt-install policy should install OADP. Check policy compliance."
          fi
        fi
      fi
    fi

    # --- 5. DataProtectionApplication ---
    printf "\n  ${BOLD}DataProtectionApplication:${RESET}\n"
    if [[ "$TC_OADP_OK" == true ]]; then
      DPA_JSON=$(run_oc_on_cluster "$TC" get dataprotectionapplications.oadp.openshift.io -n "$BACKUP_NS" -o json 2>/dev/null || echo '{"items":[]}')
      DPA_STATUS=$(echo "$DPA_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
print(len(items))
for d in items:
    name = d['metadata']['name']
    conds = d.get('status', {}).get('conditions', [])
    reconciled = any(c.get('type') == 'Reconciled' and c.get('status') == 'True' for c in conds)
    plugins = d.get('spec', {}).get('configuration', {}).get('velero', {}).get('defaultPlugins', [])
    node_agent = d.get('spec', {}).get('configuration', {}).get('nodeAgent', {})
    uploader = node_agent.get('uploaderType', 'n/a')
    na_enabled = node_agent.get('enable', False)
    has_kubevirt = 'kubevirt' in plugins
    has_csi = 'csi' in plugins
    status_str = 'Reconciled' if reconciled else 'NOT reconciled'
    print(f'    {name}: {status_str}  plugins={plugins}  nodeAgent={na_enabled}/{uploader}')
    if not has_kubevirt:
        print(f'    WARN: kubevirt plugin MISSING')
    if not has_csi:
        print(f'    WARN: csi plugin MISSING')
    if not na_enabled:
        print(f'    WARN: nodeAgent not enabled (required for DataMover)')
    if uploader != 'kopia':
        print(f'    WARN: uploaderType should be kopia, got {uploader}')
" 2>/dev/null || echo "0")

      DPA_COUNT=$(echo "$DPA_STATUS" | head -1)
      DPA_DETAILS=$(echo "$DPA_STATUS" | tail -n +2)

      if [[ "$DPA_COUNT" -gt 0 ]]; then
        info "DPA found on '$TC' ($DPA_COUNT)"
        echo "$DPA_DETAILS"

        if echo "$DPA_DETAILS" | grep -q "WARN: kubevirt plugin MISSING"; then
          add_issue "ERROR" \
            "DPA on '${TC}' is missing 'kubevirt' plugin." \
            "Add 'kubevirt' to DPA defaultPlugins on ${TC}."
        fi
        if echo "$DPA_DETAILS" | grep -q "WARN: csi plugin MISSING"; then
          add_issue "WARN" \
            "DPA on '${TC}' is missing 'csi' plugin." \
            "Add 'csi' to DPA defaultPlugins on ${TC}."
        fi
        if echo "$DPA_DETAILS" | grep -q "WARN: nodeAgent not enabled"; then
          add_issue "WARN" \
            "DPA nodeAgent not enabled on '${TC}'." \
            "Set nodeAgent.enable=true and uploaderType=kopia in the DPA on ${TC}."
        fi
        if echo "$DPA_DETAILS" | grep -q "NOT reconciled"; then
          add_issue "ERROR" \
            "DPA on '${TC}' is NOT reconciled." \
            "Check DPA status and OADP logs on ${TC}."
        fi
      else
        err "No DPA on '$TC' in $BACKUP_NS"
        if [[ "$TC_IS_HUB" == true ]]; then
          add_issue "ERROR" \
            "No DPA on '${TC}' (hub). Create DPA manually or via MCH backup." \
            "Enable cluster-backup on MCH of '${TC}' and patch the DPA."
        else
          add_issue "ERROR" \
            "No DPA on '${TC}'." \
            "The acm-dr-virt-install policy should create it. Check policy compliance."
        fi
      fi
    else
      printf "    Skipped (OADP not installed on '$TC').\n"
    fi

    # --- 6. BackupStorageLocation ---
    printf "\n  ${BOLD}BackupStorageLocation:${RESET}\n"
    if [[ "$TC_OADP_OK" == true ]]; then
      BSL_JSON=$(run_oc_on_cluster "$TC" get backupstoragelocations.velero.io -n "$BACKUP_NS" -o json 2>/dev/null || echo '{"items":[]}')
      BSL_INFO=$(echo "$BSL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
avail = 0
print(len(items))
for b in items:
    name = b['metadata']['name']
    phase = b.get('status', {}).get('phase', 'Unknown')
    print(f'    {name}: {phase}')
    if phase == 'Available':
        avail += 1
print(f'available={avail}')
" 2>/dev/null || echo "0")

      BSL_COUNT=$(echo "$BSL_INFO" | head -1)
      BSL_DETAILS=$(echo "$BSL_INFO" | sed -n '2,/^available=/p' | grep -v "^available=")
      BSL_AVAIL=$(echo "$BSL_INFO" | grep "^available=" | cut -d= -f2)

      if [[ "$BSL_COUNT" -gt 0 ]]; then
        [[ -n "$BSL_DETAILS" ]] && echo "$BSL_DETAILS"
        if [[ "${BSL_AVAIL:-0}" -gt 0 ]]; then
          info "$BSL_AVAIL BSL(s) Available on '$TC'"
        else
          err "No BSL in Available phase on '$TC'"
          add_issue "ERROR" \
            "No BSL Available on '${TC}'." \
            "Check BSL config, credentials, and bucket connectivity on ${TC}."
        fi
      else
        err "No BSL found on '$TC'"
        add_issue "ERROR" \
          "No BSL found on '${TC}'." \
          "DPA or OADP config issue on ${TC}."
      fi
    else
      printf "    Skipped (OADP not installed on '$TC').\n"
    fi

    # --- 7. Velero Credentials ---
    printf "\n  ${BOLD}Velero Credentials:${RESET}\n"
    if [[ -n "$CRED_SECRET" ]]; then
      if run_oc_on_cluster "$TC" get secret "$CRED_SECRET" -n "$BACKUP_NS" &>/dev/null; then
        info "Credentials secret '$CRED_SECRET' exists on '$TC'"
      else
        err "Credentials secret '$CRED_SECRET' NOT found on '$TC'"
        add_issue "ERROR" \
          "Velero credentials secret '${CRED_SECRET}' missing on '${TC}'." \
          "The install policy copies it from hub. Check policy compliance on ${TC}."
      fi
    else
      printf "    credentials_name not set in config. Skipping.\n"
    fi
  done
fi

# ============================================================
# 8. Schedule Cron ConfigMap
# ============================================================
header "8. Schedule Cron Configuration"

CRON_ENTRIES=""
if [[ -n "$SCHEDULE_CRON_CM" ]]; then
  CRON_CM_JSON=$(run_oc get configmap "$SCHEDULE_CRON_CM" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
  if [[ -z "$CRON_CM_JSON" ]]; then
    err "Schedule cron ConfigMap '$SCHEDULE_CRON_CM' not found in $BACKUP_NS"
    add_issue "ERROR" \
      "Schedule cron ConfigMap '${SCHEDULE_CRON_CM}' missing from ${BACKUP_NS}." \
      "Create it with cron job definitions (e.g. daily_8am: '0 8 * * *')."
  else
    info "Schedule cron ConfigMap '$SCHEDULE_CRON_CM' found"
    CRON_ENTRIES=$(echo "$CRON_CM_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', {})
if not data:
    print('  (empty)')
for k, v in data.items():
    print(f'  {k}: {v}')
" 2>/dev/null || echo "  (parse error)")
    echo "$CRON_ENTRIES"
  fi

  CLS_CRON_CM=$(run_oc get configmap "acm-dr-virt-schedule-cron--cls" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
  if [[ -n "$CLS_CRON_CM" ]]; then
    info "Cluster-local cron ConfigMap 'acm-dr-virt-schedule-cron--cls' exists (copied by policy)"
  fi
else
  warn "schedule_hub_config_name not set. No backup schedules will be created."
fi

# ============================================================
# 9-11. VMs / Schedules / Backups (per virt-labeled cluster)
# ============================================================
header "9-11. VMs, Schedules & Backups (per cluster)"

VM_LABEL="cluster.open-cluster-management.io/backup-vm"
SCHED_LABEL="cluster.open-cluster-management.io/backup-schedule-type=kubevirt"
BKP_LABEL="cluster.open-cluster-management.io/backup-schedule-type=kubevirt"
TOTAL_VM_COUNT=0

if [[ ${#VIRT_CLUSTER_LIST[@]} -eq 0 ]]; then
  printf "Skipped (no virt-labeled clusters).\n"
else
  for TC in "${VIRT_CLUSTER_LIST[@]}"; do
    printf "\n  ${BOLD}${CYAN}--- Cluster: %s ---${RESET}\n" "$TC"

    if [[ "$TC" != "$LOCAL_MC" && -z "${MC_CONTEXT_MAP[$TC]:-}" ]]; then
      printf "  ${YELLOW}(no kubeconfig context -- cannot check VMs/schedules remotely)${RESET}\n"
      continue
    fi

    # --- 9. VMs with backup label ---
    printf "\n  ${BOLD}VirtualMachines with backup label:${RESET}\n"
    TC_VM_CRD=false
    if run_oc_on_cluster "$TC" get crd virtualmachines.kubevirt.io &>/dev/null; then
      TC_VM_CRD=true
    fi

    TC_VM_COUNT=0
    if [[ "$TC_VM_CRD" == true ]]; then
      VM_JSON=$(run_oc_on_cluster "$TC" get virtualmachines.kubevirt.io --all-namespaces -l "$VM_LABEL" -o json 2>/dev/null || echo '{"items":[]}')
      VM_INFO=$(echo "$VM_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
print(len(items))
crons = {}
for vm in items:
    name = vm['metadata']['name']
    ns = vm['metadata']['namespace']
    uid = vm['metadata'].get('uid', '?')
    cron = vm['metadata'].get('labels', {}).get('cluster.open-cluster-management.io/backup-vm', '?')
    print(f'    {ns}/{name}  uid={uid}  schedule={cron}')
    crons.setdefault(cron, []).append(f'{ns}/{name}')
print('---')
for c, vms in sorted(crons.items()):
    print(f'    schedule \"{c}\": {len(vms)} VM(s)')
" 2>/dev/null || echo "0")

      TC_VM_COUNT=$(echo "$VM_INFO" | head -1)
      VM_DETAILS=$(echo "$VM_INFO" | tail -n +2)

      if [[ "$TC_VM_COUNT" -gt 0 ]]; then
        info "$TC_VM_COUNT VM(s) labeled for backup on '$TC'"
        echo "$VM_DETAILS"
        TOTAL_VM_COUNT=$((TOTAL_VM_COUNT + TC_VM_COUNT))
      else
        printf "    No VMs with backup label on '$TC'\n"
      fi
    else
      printf "    VirtualMachine CRD not installed on '$TC'\n"
    fi

    # --- 10. Velero Schedules ---
    printf "\n  ${BOLD}Velero Backup Schedules (kubevirt):${RESET}\n"
    TC_SCH_JSON=$(run_oc_on_cluster "$TC" get schedules.velero.io -n "$BACKUP_NS" -l "$SCHED_LABEL" -o json 2>/dev/null || echo '{"items":[]}')
    TC_SCH_INFO=$(echo "$TC_SCH_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
print(len(items))
for s in items:
    name = s['metadata']['name']
    phase = s.get('status', {}).get('phase', 'Unknown')
    paused = s.get('spec', {}).get('paused', False)
    cron = s.get('spec', {}).get('schedule', '?')
    last = s.get('status', {}).get('lastBackup', 'never')
    ns_list = s.get('spec', {}).get('template', {}).get('includedNamespaces', [])
    ann = s.get('metadata', {}).get('annotations', {})
    vm_count = sum(1 for k, v in ann.items() if '--' in v)
    status = 'Paused' if paused else phase
    print(f'    {name}: {status}  cron=\"{cron}\"  lastBackup={last}  VMs={vm_count}  ns={ns_list}')
" 2>/dev/null || echo "0")

    TC_SCH_COUNT=$(echo "$TC_SCH_INFO" | head -1)
    TC_SCH_DETAILS=$(echo "$TC_SCH_INFO" | tail -n +2)

    if [[ "$TC_SCH_COUNT" -gt 0 ]]; then
      info "$TC_SCH_COUNT kubevirt schedule(s) on '$TC'"
      echo "$TC_SCH_DETAILS"
    else
      if [[ "$TC_VM_COUNT" -gt 0 ]]; then
        warn "No kubevirt schedules on '$TC', but VMs with backup label exist."
        add_issue "WARN" \
          "VMs have backup labels on '${TC}' but no velero Schedule exists." \
          "Check the acm-dr-virt-backup policy status on ${TC}."
      else
        printf "    No kubevirt schedules on '$TC'\n"
      fi
    fi

    # --- 11. Latest Backup (per active schedule) ---
    printf "\n  ${BOLD}Latest Backup (per active schedule):${RESET}\n"
    ACTIVE_SCHEDULES=$(echo "$TC_SCH_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for s in items:
    print(s['metadata']['name'])
" 2>/dev/null || echo "")

    if [[ -z "$ACTIVE_SCHEDULES" ]]; then
      printf "    No active schedules on '$TC'\n"
      continue
    fi

    TC_BKP_JSON=$(run_oc_on_cluster "$TC" get backups.velero.io -n "$BACKUP_NS" -l "$BKP_LABEL" -o json 2>/dev/null || echo '{"items":[]}')
    TC_BKP_INFO=$(echo "$TC_BKP_JSON" | ACTIVE_SCHEDULES="$ACTIVE_SCHEDULES" python3 -c "
import sys, json, os
items = json.load(sys.stdin).get('items', [])
active = set(os.environ.get('ACTIVE_SCHEDULES', '').split())

by_schedule = {}
for b in items:
    sch = b['metadata'].get('labels', {}).get('velero.io/schedule-name', '')
    if not sch or sch not in active:
        continue
    ts = b.get('status', {}).get('startTimestamp', '')
    if sch not in by_schedule or ts > by_schedule[sch].get('status', {}).get('startTimestamp', ''):
        by_schedule[sch] = b

latest = sorted(by_schedule.values(),
    key=lambda b: b.get('status', {}).get('startTimestamp', ''), reverse=True)
BLUE = '\033[34m'
YELLOW = '\033[33m'
RED = '\033[31m'
RESET = '\033[0m'
print(len(latest))
for b in latest:
    name = b['metadata']['name']
    phase = b.get('status', {}).get('phase', 'Unknown')
    started = b.get('status', {}).get('startTimestamp', '?')
    errors = b.get('status', {}).get('errors', 0)
    warnings = b.get('status', {}).get('warnings', 0)
    sch = b['metadata'].get('labels', {}).get('velero.io/schedule-name', '?')
    if phase == 'Completed':
        bullet = f'{BLUE}\u25cf{RESET}'
    elif phase == 'PartiallyFailed':
        bullet = f'{YELLOW}\u25cf{RESET}'
    else:
        bullet = f'{RED}\u25cf{RESET}'
    print(f'    {bullet} {name}: {phase}  started={started}  errors={errors}  warnings={warnings}  schedule={sch}')
" 2>/dev/null || echo "0")

    TC_BKP_COUNT=$(echo "$TC_BKP_INFO" | head -1)
    TC_BKP_DETAILS=$(echo "$TC_BKP_INFO" | tail -n +2)

    if [[ "$TC_BKP_COUNT" -gt 0 ]]; then
      info "Latest backup for $TC_BKP_COUNT schedule(s) on '$TC'"
      echo "$TC_BKP_DETAILS"

      FAILED_BKPS=$(echo "$TC_BKP_DETAILS" | grep -cv "Completed" || true)
      if [[ "$FAILED_BKPS" -gt 0 ]]; then
        add_issue "WARN" \
          "$FAILED_BKPS backup(s) not Completed on '${TC}'." \
          "oc get dataupload -n ${BACKUP_NS}; oc logs -n ${BACKUP_NS} -l app.kubernetes.io/name=velero (on ${TC})"
      fi
    else
      warn "Active schedules on '$TC' but no backups found yet."
    fi
  done

  if [[ "$TOTAL_VM_COUNT" -eq 0 ]]; then
    warn "No VMs with backup label found on any virt-labeled cluster."
  fi
fi

# ============================================================
# 12. Restore Configuration
# ============================================================
header "12. Restore Configuration"

RESTORE_ACTIVE=false
if [[ -n "$RESTORE_CM" ]]; then
  RESTORE_CM_JSON=$(run_oc get configmap "$RESTORE_CM" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
  if [[ -z "$RESTORE_CM_JSON" ]]; then
    warn "Restore ConfigMap '$RESTORE_CM' not found in $BACKUP_NS"
    add_issue "WARN" \
      "Restore ConfigMap '${RESTORE_CM}' not found. Create it (empty data if no restore needed)." \
      "oc create configmap ${RESTORE_CM} -n ${BACKUP_NS}"
  else
    info "Restore ConfigMap '$RESTORE_CM' found"
    RESTORE_DATA=$(echo "$RESTORE_CM_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', {})
if not data:
    print('  (empty -- no restore configured)')
else:
    clusters = {}
    for k, v in data.items():
        parts = k.rsplit('_', 1)
        if len(parts) == 2:
            cid, prop = parts
            clusters.setdefault(cid, {})[prop] = v
    if clusters:
        for cid, props in clusters.items():
            rn = props.get('restoreName', '')
            bn = props.get('backupName', '')
            uids = props.get('vmsUID', '')
            if rn:
                print(f'  cluster={cid}: restoreName={rn} backupName={bn} vmsUID={uids}')
    else:
        for k, v in data.items():
            print(f'  {k}: {v}')
" 2>/dev/null || echo "  (parse error)")
    echo "$RESTORE_DATA"

    if echo "$RESTORE_DATA" | grep -q "restoreName="; then
      RESTORE_ACTIVE=true
    fi
  fi

  CLS_RESTORE_CM=$(run_oc get configmap "acm-dr-virt-restore-config--cls" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
  if [[ -n "$CLS_RESTORE_CM" ]]; then
    info "Cluster-local restore ConfigMap 'acm-dr-virt-restore-config--cls' exists"
  fi
else
  printf "restore_hub_config_name not set. Restore check skipped.\n"
fi

if [[ "$RESTORE_ACTIVE" == true ]]; then
  printf "\n${BOLD}Velero Restores:${RESET}\n"
  VREST_JSON=$(run_oc get restores.velero.io -n "$BACKUP_NS" -o json 2>/dev/null || echo '{"items":[]}')
  echo "$VREST_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for r in items:
    name = r['metadata']['name']
    phase = r.get('status', {}).get('phase', 'Unknown')
    backup = r.get('spec', {}).get('backupName', '?')
    print(f'  {name}: phase={phase}  backup={backup}')
if not items:
    print('  (no velero restores found)')
" 2>/dev/null || true
fi

# ============================================================
# 13. Policy Compliance
# ============================================================
header "13. Policy Compliance"

POLICY_CRD_EXISTS=false
if run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
  POLICY_CRD_EXISTS=true
fi

if [[ "$POLICY_CRD_EXISTS" == true ]]; then
  VIRT_CLUSTERS=$(run_oc get managedclusters -l acm-virt-config --no-headers 2>/dev/null | awk '{print $1}' || echo "")
  if [[ -z "$VIRT_CLUSTERS" ]]; then
    warn "No ManagedClusters with acm-virt-config label found."
    printf "  Virt policies are not placed on any cluster.\n"
  else
    printf "Clusters with acm-virt-config label: %s\n\n" "$(echo $VIRT_CLUSTERS | tr '\n' ' ')"
  fi

  for POLICY_NAME in acm-dr-virt-install acm-dr-virt-backup acm-dr-virt-restore; do
    printf "\n${BOLD}%s:${RESET}\n" "$POLICY_NAME"

    ROOT_POLICY=$(run_oc get policy.policy.open-cluster-management.io "$POLICY_NAME" -n "$BACKUP_NS" -o json 2>/dev/null || echo "")
    if [[ -z "$ROOT_POLICY" ]]; then
      printf "  (root policy not found in ${BACKUP_NS})\n"
      continue
    fi

    ROOT_COMPLIANCE=$(echo "$ROOT_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(p.get('status', {}).get('compliant', 'Unknown'))
" 2>/dev/null || echo "Unknown")
    printf "  Root policy compliance: %s\n" "$ROOT_COMPLIANCE"

    echo "$ROOT_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
cluster_statuses = p.get('status', {}).get('status', [])
if cluster_statuses:
    for cs in cluster_statuses:
        cname = cs.get('clustername', '?')
        ccomp = cs.get('compliant', '?')
        icon = 'OK' if ccomp == 'Compliant' else 'ISSUE'
        print(f'  [{icon}] {cname}: {ccomp}')
" 2>/dev/null || true

    if [[ -z "$VIRT_CLUSTERS" ]]; then
      printf "  (no clusters to check)\n"
      continue
    fi

    for TARGET_CLUSTER in $VIRT_CLUSTERS; do
      printf "\n  ${CYAN}Cluster: %s${RESET}\n" "$TARGET_CLUSTER"

      REPL_POLICY=$(run_oc get policy.policy.open-cluster-management.io "${BACKUP_NS}.${POLICY_NAME}" -n "$TARGET_CLUSTER" -o json 2>/dev/null || echo "")
      if [[ -z "$REPL_POLICY" ]]; then
        printf "    (replicated policy not found in namespace ${TARGET_CLUSTER})\n"
        continue
      fi

      CLUSTER_COMPLIANCE=$(echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(p.get('status', {}).get('compliant', 'Unknown'))
" 2>/dev/null || echo "Unknown")

      echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
for d in details:
    tname = d.get('templateMeta', {}).get('name', '?')
    comp = d.get('compliant', '?')
    conds = d.get('conditions', [])
    msg = ''
    if conds:
        msg = conds[0].get('message', '')[:120]
    status_icon = 'OK' if comp == 'Compliant' else 'ISSUE'
    print(f'    [{status_icon}] {tname}: {comp}')
    if comp != 'Compliant' and msg:
        print(f'          {msg}')
" 2>/dev/null || true

      if [[ "$CLUSTER_COMPLIANCE" == "NonCompliant" ]]; then
        VIOLATION_TEMPLATES=$(echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
violated = [d.get('templateMeta', {}).get('name', '?') for d in details if d.get('compliant') != 'Compliant']
print(', '.join(violated))
" 2>/dev/null || echo "?")

        if [[ "$POLICY_NAME" == "acm-dr-virt-install" ]]; then
          add_issue "ERROR" \
            "Policy '${POLICY_NAME}' is NonCompliant on '${TARGET_CLUSTER}'. Violating: ${VIOLATION_TEMPLATES}." \
            "Check OADP installation, DPA config, and credential secrets on ${TARGET_CLUSTER}."
        else
          add_issue "WARN" \
            "Policy '${POLICY_NAME}' is NonCompliant on '${TARGET_CLUSTER}'. Violating: ${VIOLATION_TEMPLATES}." \
            "See template details above for specifics."
        fi
      fi
    done
  done
else
  warn "Policy CRD not found. Cannot check policy compliance."
fi

# ============================================================
# Summary
# ============================================================
header "Summary"

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  printf "\n${GREEN}No configuration issues detected.${RESET}\n\n"
  if [[ ${#VIRT_CLUSTER_LIST[@]} -gt 0 ]]; then
    printf "All virt-labeled clusters (%s) are correctly configured for ACM VM backup/restore.\n" "${VIRT_CLUSTER_LIST[*]}"
  else
    printf "Cluster ${BOLD}%s${RESET} has no virt-labeled ManagedClusters.\n" "$CLUSTER_ID"
  fi
  exit 0
fi

printf "\n${BOLD}Issues found: %d${RESET}\n\n" "${#ISSUES[@]}"

ERROR_COUNT=0
WARN_COUNT=0

for issue in "${ISSUES[@]}"; do
  IFS='|' read -r level msg fix <<< "$issue"
  case "$level" in
    ERROR) err "$msg"; ERROR_COUNT=$((ERROR_COUNT + 1)) ;;
    WARN)  warn "$msg"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
  if [[ "$fix" != "none" ]]; then
    printf "   Fix: %s\n" "$fix"
  fi
  printf "\n"
done

printf "${BOLD}Totals:${RESET} %d error(s), %d warning(s)\n" "$ERROR_COUNT" "$WARN_COUNT"

# Suggest relevant guides based on issues found
SUGGESTED_GUIDES=()
for issue in "${ISSUES[@]}"; do
  IFS='|' read -r level msg _ <<< "$issue"
  case "$msg" in
    *"acm-virt-config label"*)     SUGGESTED_GUIDES+=("backup") ;;
    *"ConfigMap"*"not found"*)     SUGGESTED_GUIDES+=("backup") ;;
    *"OADP"*"not installed"*)      SUGGESTED_GUIDES+=("install") ;;
    *"kubevirt plugin"*)           SUGGESTED_GUIDES+=("backup") ;;
    *"acm-dr-virt-install"*)       SUGGESTED_GUIDES+=("install-noncompliant") ;;
    *"acm-dr-virt-backup"*)        SUGGESTED_GUIDES+=("backup-noncompliant") ;;
    *"No DataProtection"*)         SUGGESTED_GUIDES+=("backup") ;;
    *"BackupStorageLocation"*)     SUGGESTED_GUIDES+=("backup") ;;
    *"no velero Schedule"*)        SUGGESTED_GUIDES+=("backup") ;;
    *"not in Completed phase"*)    SUGGESTED_GUIDES+=("backup-noncompliant") ;;
  esac
done

if [[ ${#SUGGESTED_GUIDES[@]} -gt 0 ]]; then
  UNIQUE_GUIDES=$(printf '%s\n' "${SUGGESTED_GUIDES[@]}" | sort -u | tr '\n' ' ')
  printf "\n${BOLD}${CYAN}Suggested guides:${RESET}\n"
  for g in $UNIQUE_GUIDES; do
    printf "  %s --guide %s\n" "$(basename "$0")" "$g"
  done
fi

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
