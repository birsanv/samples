#!/usr/bin/env bash
# ACM Backup Configuration Assessment Script
# Requires: oc (logged in to an OpenShift cluster with ACM installed)
#
# Usage: assess-backup-config.sh [--context <name>] [<context>]
#   --context <name>   Use the specified kubeconfig context
#   <context>          Positional shorthand for --context
#   (no argument)      Use the current kubeconfig context
set -euo pipefail

NS="open-cluster-management-backup"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# --- Parse arguments ---
CTX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      CTX="$2"; shift 2 ;;
    --context=*)
      CTX="${1#--context=}"; shift ;;
    -h|--help)
      printf "Usage: %s [--context <name>] [<context>]\n" "$(basename "$0")"
      printf "  --context <name>   kubeconfig context to use\n"
      printf "  <context>          positional shorthand for --context\n"
      printf "  (no argument)      use current kubeconfig context\n"
      exit 0 ;;
    *)
      CTX="$1"; shift ;;
  esac
done

# Build the oc context flag used for every oc invocation
OC_CTX=()
if [[ -n "$CTX" ]]; then
  OC_CTX=(--context "$CTX")
fi

# Wrapper so every oc call uses the chosen context
run_oc() { oc "${OC_CTX[@]}" "$@"; }

# String form for use inside eval'd command strings
if [[ -n "$CTX" ]]; then
  OC="oc --context $CTX"
else
  OC="oc"
fi

header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }
info()   { printf "${GREEN}[OK]${RESET} %s\n" "$1"; }
warn()   { printf "${YELLOW}[WARN]${RESET} %s\n" "$1"; }
err()    { printf "${RED}[ERROR]${RESET} %s\n" "$1"; }

hub_label() {
  local id="$1"
  if [[ "$id" == "$CLUSTER_ID" ]]; then
    printf "this cluster (%s)" "$id"
  else
    printf "%s" "$id"
  fi
}

# --- Pre-flight ---
header "Pre-flight Checks"

if ! command -v oc &>/dev/null; then
  err "oc CLI not found"; exit 1
fi

if ! run_oc whoami &>/dev/null; then
  if [[ -n "$CTX" ]]; then
    err "Cannot connect using context '$CTX' -- check that it exists and is logged in"
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

# --- 1. This cluster's identity ---
header "1. Cluster Identity"

CLUSTER_ID=$(run_oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
if [[ -z "$CLUSTER_ID" ]]; then
  warn "Could not read ClusterVersion.spec.clusterID"
  CLUSTER_ID="unknown"
fi
printf "This cluster ID: ${BOLD}%s${RESET}\n" "$CLUSTER_ID"

# --- 2. OADP / Velero namespace ---
header "2. Backup Namespace & OADP"

if ! run_oc get namespace "$NS" &>/dev/null; then
  err "Namespace $NS does not exist. OADP/Velero is not installed for ACM backup."
  printf "\nResult: This cluster is NOT in an active-passive backup configuration.\n"
  exit 0
fi
info "Namespace $NS exists"

DPA_COUNT=$(run_oc get dataprotectionapplications.oadp.openshift.io -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DPA_COUNT" -gt 0 ]]; then
  info "DataProtectionApplication found ($DPA_COUNT)"
else
  warn "No DataProtectionApplication in $NS"
fi

# --- 3. BackupStorageLocation ---
header "3. Backup Storage Location (BSL)"

BSL_JSON=$(run_oc get backupstoragelocations.velero.io -n "$NS" -o json 2>/dev/null || echo '{"items":[]}')
BSL_COUNT=$(echo "$BSL_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

if [[ "$BSL_COUNT" -eq 0 ]]; then
  err "No BackupStorageLocation found in $NS"
  printf "\nResult: This cluster is NOT connected to backup storage.\n"
  exit 0
fi

BSL_AVAILABLE=0
echo "$BSL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for b in items:
    name = b['metadata']['name']
    phase = b.get('status', {}).get('phase', 'Unknown')
    owners = len(b['metadata'].get('ownerReferences', []))
    flag = 'Available' if (phase == 'Available' and owners > 0) else phase
    print(f'  {name}: {flag}')
" 2>/dev/null

BSL_AVAILABLE=$(echo "$BSL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
print(sum(1 for b in items if b.get('status',{}).get('phase')=='Available' and b['metadata'].get('ownerReferences')))
" 2>/dev/null)

if [[ "$BSL_AVAILABLE" -gt 0 ]]; then
  info "$BSL_AVAILABLE BSL(s) available and owned by OADP"
else
  warn "No BSL is both Available and owned by OADP"
fi

# --- 4. BackupSchedule ---
header "4. ACM BackupSchedule"

SCHED_JSON=$(run_oc get backupschedules.cluster.open-cluster-management.io -n "$NS" -o json 2>/dev/null || echo '{"items":[]}')
SCHED_COUNT=$(echo "$SCHED_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

HAS_SCHEDULE=false
SCHEDULE_PHASE=""
SCHEDULE_NAME=""

if [[ "$SCHED_COUNT" -gt 0 ]]; then
  HAS_SCHEDULE=true
  echo "$SCHED_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for s in items:
    name = s['metadata']['name']
    phase = s.get('status', {}).get('phase', 'Unknown')
    msg = s.get('status', {}).get('lastMessage', '')
    print(f'  {name}: phase={phase}  msg={msg}')
" 2>/dev/null
  SCHEDULE_PHASE=$(echo "$SCHED_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if items: print(items[0].get('status',{}).get('phase','Unknown'))
" 2>/dev/null)
  SCHEDULE_NAME=$(echo "$SCHED_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if items: print(items[0]['metadata']['name'])
" 2>/dev/null)
else
  info "No BackupSchedule found on this cluster"
fi

# --- Pre-fetch failover data (needed by step 5 and step 8) ---
FAILOVER_JSON=$(run_oc get backups.velero.io -n "$NS" -l cluster.open-cluster-management.io/restore-cluster -o json 2>/dev/null || echo '{"items":[]}')
FAILOVER_COUNT=$(echo "$FAILOVER_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")
FAILOVER_HUB=""
if [[ "$FAILOVER_COUNT" -gt 0 ]]; then
  FAILOVER_HUB=$(echo "$FAILOVER_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b['metadata'].get('creationTimestamp',''), reverse=True)
if items:
    labels = items[0].get('metadata',{}).get('labels',{})
    print(labels.get('cluster.open-cluster-management.io/restore-cluster', 'unknown'))
" 2>/dev/null)
fi

# --- 5. ACM Restore (passive hub indicator) ---
header "5. ACM Restore"

RESTORE_JSON=$(run_oc get restores.cluster.open-cluster-management.io -n "$NS" -o json 2>/dev/null || echo '{"items":[]}')
RESTORE_COUNT=$(echo "$RESTORE_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

HAS_RESTORE=false
RESTORE_SYNC=false
RESTORE_MC="unknown"
RESTORE_PHASE="Unknown"
RESTORE_SYNC_INTERVAL=""
RESTORE_COMPLETION_TS=""

if [[ "$RESTORE_COUNT" -gt 0 ]]; then
  HAS_RESTORE=true

  # List all restores
  echo "$RESTORE_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for r in items:
    name = r['metadata']['name']
    phase = r.get('status', {}).get('phase', 'Unknown')
    mc = r.get('spec', {}).get('veleroManagedClustersBackupName', 'not set')
    sync = r.get('spec', {}).get('syncRestoreWithNewBackups', False)
    interval = r.get('spec', {}).get('restoreSyncInterval', '')
    print(f'  {name}: phase={phase}  MC={mc}  sync={sync}  interval={interval}')
" 2>/dev/null

  if [[ "$RESTORE_COUNT" -gt 1 ]]; then
    printf "  ${YELLOW}Multiple Restore resources found -- using the most recent one.${RESET}\n"
  fi

  # Extract fields from the latest restore (sorted by creationTimestamp)
  RESTORE_DETAILS=$(echo "$RESTORE_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda r: r['metadata'].get('creationTimestamp',''), reverse=True)
r = items[0]
name = r['metadata']['name']
mc = r.get('spec',{}).get('veleroManagedClustersBackupName','not set')
sync = str(r.get('spec',{}).get('syncRestoreWithNewBackups', False)).lower()
phase = r.get('status',{}).get('phase','Unknown')
interval = r.get('spec',{}).get('restoreSyncInterval','')
completion = r.get('status',{}).get('completionTimestamp','')
print(f'{name}|{mc}|{sync}|{phase}|{interval}|{completion}')
" 2>/dev/null)

  RESTORE_NAME_LATEST=$(echo "$RESTORE_DETAILS" | cut -d'|' -f1)
  RESTORE_MC=$(echo "$RESTORE_DETAILS" | cut -d'|' -f2)
  RESTORE_SYNC=$(echo "$RESTORE_DETAILS" | cut -d'|' -f3)
  RESTORE_PHASE=$(echo "$RESTORE_DETAILS" | cut -d'|' -f4)
  RESTORE_SYNC_INTERVAL=$(echo "$RESTORE_DETAILS" | cut -d'|' -f5)
  RESTORE_COMPLETION_TS=$(echo "$RESTORE_DETAILS" | cut -d'|' -f6)

  if [[ "$RESTORE_COUNT" -gt 1 ]]; then
    printf "  Using: ${BOLD}%s${RESET} (phase=%s)\n" "$RESTORE_NAME_LATEST" "$RESTORE_PHASE"
  fi

  if [[ "$RESTORE_MC" == "skip" ]]; then
    if [[ "$RESTORE_PHASE" == "Enabled" || "$RESTORE_PHASE" == "EnabledWithErrors" ]]; then
      SYNC_MSG=""
      if [[ -n "$RESTORE_SYNC_INTERVAL" ]]; then
        SYNC_MSG=" every $RESTORE_SYNC_INTERVAL"
      fi
      info "Passive hub -- actively syncing passive data${SYNC_MSG} (phase: $RESTORE_PHASE)"
    elif [[ "$RESTORE_PHASE" == "Finished" || "$RESTORE_PHASE" == "FinishedWithErrors" ]]; then
      COMPLETED_MSG=""
      if [[ -n "$RESTORE_COMPLETION_TS" ]]; then
        COMPLETED_MSG=" at $RESTORE_COMPLETION_TS"
      fi
      if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" ]]; then
        warn "This cluster performed the last failover (managed-clusters restore) -- it is the active hub."
        printf "     A subsequent Restore with MC=skip was run (completed${COMPLETED_MSG}), likely to re-sync or fix passive data.\n"
        printf "     Regardless, this cluster should be the active hub and must have a BackupSchedule running.\n"
        if [[ "$HAS_SCHEDULE" != true ]]; then
          err "No BackupSchedule found -- backups are not being created. Create one now."
        elif [[ "$SCHEDULE_PHASE" == "Paused" ]]; then
          err "BackupSchedule is paused -- no new backups will be created. Unpause it."
        elif [[ "$SCHEDULE_PHASE" == "BackupCollision" ]]; then
          err "BackupSchedule is in BackupCollision -- another cluster started writing to the same storage."
        else
          info "BackupSchedule is running (phase: $SCHEDULE_PHASE)"
        fi
      else
        warn "Passive hub but data is NOT syncing -- restore completed once${COMPLETED_MSG} (phase: $RESTORE_PHASE)"
        printf "     Passive data will become stale. To keep syncing, create a new Restore with syncRestoreWithNewBackups: true.\n"
      fi
    else
      printf "  Restore phase: %s (MC=skip)\n" "$RESTORE_PHASE"
    fi
  fi
else
  # Determine if this cluster should be passive (not the active hub)
  THIS_IS_ACTIVE=false
  if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" ]]; then
    THIS_IS_ACTIVE=true
  elif [[ "$HAS_SCHEDULE" == true && "$SCHEDULE_PHASE" != "BackupCollision" && "$SCHEDULE_PHASE" != "Paused" ]]; then
    THIS_IS_ACTIVE=true
  fi

  if [[ "$THIS_IS_ACTIVE" == true ]]; then
    info "No Restore found -- not a passive hub"
  else
    warn "No Restore found. If another hub is the active hub, this cluster should have a"
    printf "     Restore with syncRestoreWithNewBackups: true and MC=skip to be a proper passive hub.\n"
  fi
fi

# --- 6. Velero backups from storage (who is the active hub?) ---
header "6. ACM Backups in Storage"

BACKUP_JSON=$(run_oc get backups.velero.io -n "$NS" -l velero.io/schedule-name=acm-resources-schedule -o json 2>/dev/null || echo '{"items":[]}')
BACKUP_COUNT=$(echo "$BACKUP_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

ACTIVE_HUB_ID="none"

if [[ "$BACKUP_COUNT" -gt 0 ]]; then
  info "$BACKUP_COUNT acm-resources-schedule backup(s) found"
  ACTIVE_HUB_ID=$(echo "$BACKUP_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b.get('status',{}).get('startTimestamp',''), reverse=True)
if items:
    labels = items[0].get('metadata',{}).get('labels',{})
    print(labels.get('cluster.open-cluster-management.io/backup-cluster', 'unknown'))
" 2>/dev/null)
  printf "  Latest backup created by: ${BOLD}%s${RESET}\n" "$(hub_label "$ACTIVE_HUB_ID")"

  # Warn if this cluster should be active but backups come from elsewhere
  if [[ "$ACTIVE_HUB_ID" != "$CLUSTER_ID" ]]; then
    THIS_SHOULD_BE_ACTIVE=false
    if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" ]]; then
      THIS_SHOULD_BE_ACTIVE=true
    fi
    if [[ "$HAS_SCHEDULE" == true && "$SCHEDULE_PHASE" != "BackupCollision" && "$SCHEDULE_PHASE" != "Paused" ]]; then
      THIS_SHOULD_BE_ACTIVE=true
    fi
    if [[ "$THIS_SHOULD_BE_ACTIVE" == true ]]; then
      warn "This cluster should be the active hub, but the latest backups come from a different cluster."
      printf "     Expected backups from this cluster (%s), got %s.\n" "$CLUSTER_ID" "$ACTIVE_HUB_ID"
    fi
  fi
else
  warn "No acm-resources-schedule backups found in storage"
fi

# --- 7. Validation policy (primary active hub check) ---
header "7. Active Hub Detection (Validation Policy)"

VAL_JSON=$(run_oc get backups.velero.io -n "$NS" -l velero.io/schedule-name=acm-validation-policy-schedule -o json 2>/dev/null || echo '{"items":[]}')
VAL_COUNT=$(echo "$VAL_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

CRON_ACTIVE=false
VAL_HUB_ID="unknown"
VAL_OWNED_BY_THIS_CLUSTER=false

if [[ "$VAL_COUNT" -gt 0 ]]; then
  CRON_ACTIVE=true
  LATEST_VAL_NAME=$(echo "$VAL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b.get('status',{}).get('startTimestamp',''), reverse=True)
if items: print(items[0]['metadata']['name'])
" 2>/dev/null)
  LATEST_VAL_PHASE=$(echo "$VAL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b.get('status',{}).get('startTimestamp',''), reverse=True)
if items: print(items[0].get('status',{}).get('phase','Unknown'))
" 2>/dev/null)
  LATEST_VAL_TS=$(echo "$VAL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b.get('status',{}).get('startTimestamp',''), reverse=True)
if items: print(items[0].get('status',{}).get('startTimestamp','?'))
" 2>/dev/null)
  VAL_HUB_ID=$(echo "$VAL_JSON" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
items.sort(key=lambda b: b.get('status',{}).get('startTimestamp',''), reverse=True)
if items: print(items[0].get('metadata',{}).get('labels',{}).get('cluster.open-cluster-management.io/backup-cluster','unknown'))
" 2>/dev/null)
  info "Validation backup: $LATEST_VAL_NAME  phase=$LATEST_VAL_PHASE  started=$LATEST_VAL_TS"
  printf "  Created by: ${BOLD}%s${RESET}\n" "$(hub_label "$VAL_HUB_ID")"

  if [[ "$VAL_HUB_ID" == "$CLUSTER_ID" ]]; then
    VAL_OWNED_BY_THIS_CLUSTER=true
    info "This cluster is the active hub (validation backups are created by this cluster)"
    if [[ "$HAS_SCHEDULE" != true ]]; then
      warn "But no BackupSchedule exists -- backups will stop after the current interval expires."
    elif [[ "$SCHEDULE_PHASE" == "Paused" ]]; then
      warn "But the BackupSchedule is paused -- no new backups will be created in the next interval."
    elif [[ "$SCHEDULE_PHASE" == "BackupCollision" ]]; then
      warn "BackupSchedule is in BackupCollision -- another cluster has started writing to the same storage."
    fi
  else
    printf "  Another hub (%s) is the active cluster creating backups.\n" "$VAL_HUB_ID"
  fi
else
  warn "No acm-validation-policy-schedule backups found -- no hub is actively creating backups."
fi

# --- 8. Post-failover detection (display pre-fetched data) ---
header "8. Post-Failover Detection"

if [[ "$FAILOVER_COUNT" -gt 0 ]]; then
  printf "  Last failover (managed-clusters restore) by: ${BOLD}%s${RESET}\n" "$(hub_label "$FAILOVER_HUB")"
  if [[ "$FAILOVER_HUB" == "$CLUSTER_ID" ]]; then
    printf "  ${BOLD}>> This cluster activated managed clusters -- it should be running a BackupSchedule.${RESET}\n"
  else
    printf "  >> Hub %s activated managed clusters -- it should be the active hub; this cluster should be passive.\n" "$FAILOVER_HUB"
  fi
else
  info "No failover restores detected"
fi

# --- 9. Backup & Restore Policy Validation ---
header "9. Backup & Restore Policy Validation"

POLICY_FOUND=false
POLICY_COMPLIANT=true
POLICY_VIOLATION_TEMPLATES=""
AI_COMPLIANT=true
AI_VIOLATION_TEMPLATES=""

POLICY_CRD_EXISTS=true
if ! run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
  POLICY_CRD_EXISTS=false
  warn "Policy CRD not found -- governance framework may not be installed."
fi

if [[ "$POLICY_CRD_EXISTS" == true ]]; then
  LOCAL_CLUSTER_NAME=$(run_oc get managedclusters.cluster.open-cluster-management.io -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "")
  [[ -z "$LOCAL_CLUSTER_NAME" ]] && LOCAL_CLUSTER_NAME="local-cluster"

  # ---- backup-restore-enabled ----
  printf "${BOLD}backup-restore-enabled policy:${RESET}\n"
  BR_ROOT=$(run_oc get policy.policy.open-cluster-management.io backup-restore-enabled -n "$NS" -o json 2>/dev/null || echo "")
  if [[ -z "$BR_ROOT" ]]; then
    BR_SEARCH_NS=$(run_oc get policy.policy.open-cluster-management.io -A --no-headers 2>/dev/null | awk '$2=="backup-restore-enabled"{print $1;exit}' || echo "")
    if [[ -n "$BR_SEARCH_NS" ]]; then
      BR_ROOT=$(run_oc get policy.policy.open-cluster-management.io backup-restore-enabled -n "$BR_SEARCH_NS" -o json 2>/dev/null || echo "")
    fi
  fi

  if [[ -z "$BR_ROOT" ]]; then
    warn "Policy not found. It is installed when cluster-backup is enabled on MultiClusterHub."
    printf "  If hub self-management is disabled (disableHubSelfManagement=true),\n"
    printf "  set the is-hub=true label on the ManagedCluster resource representing the local cluster.\n"
  else
    POLICY_FOUND=true
    BR_COMPLIANCE=$(echo "$BR_ROOT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',{}).get('compliant','Unknown'))" 2>/dev/null || echo "Unknown")

    if [[ "$BR_COMPLIANCE" == "Compliant" ]]; then
      info "Overall: Compliant"
    else
      err "Overall: ${BR_COMPLIANCE}"
      POLICY_COMPLIANT=false
    fi

    BR_ORIG_NS=$(echo "$BR_ROOT" | python3 -c "import sys,json;print(json.load(sys.stdin)['metadata']['namespace'])" 2>/dev/null || echo "$NS")
    BR_REPLICATED=$(run_oc get policy.policy.open-cluster-management.io "${BR_ORIG_NS}.backup-restore-enabled" -n "$LOCAL_CLUSTER_NAME" -o json 2>/dev/null || echo "")
    [[ -z "$BR_REPLICATED" ]] && BR_REPLICATED="$BR_ROOT"

    echo "$BR_REPLICATED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
details = data.get('status', {}).get('details', [])
for d in details:
    name = d.get('templateMeta', {}).get('name', 'unknown')
    compliant = d.get('compliant', 'Unknown')
    history = d.get('history', [])
    msg = ''
    if history:
        msg = history[0].get('message', '')
    if compliant == 'Compliant':
        print(f'  \033[32m[OK]\033[0m {name}')
    elif compliant == 'NonCompliant':
        print(f'  \033[31m[VIOLATION]\033[0m {name}')
        if msg:
            if len(msg) > 300:
                msg = msg[:300] + '...'
            print(f'       {msg}')
    else:
        print(f'  \033[33m[{compliant}]\033[0m {name}')
        if msg:
            if len(msg) > 300:
                msg = msg[:300] + '...'
            print(f'       {msg}')
" 2>/dev/null || true

    POLICY_VIOLATION_TEMPLATES=$(echo "$BR_REPLICATED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
details = data.get('status', {}).get('details', [])
violations = [d.get('templateMeta',{}).get('name','?') for d in details if d.get('compliant') == 'NonCompliant']
print(','.join(violations))
" 2>/dev/null || echo "")
  fi

  # ---- backup-restore-auto-import ----
  printf "\n${BOLD}backup-restore-auto-import policy:${RESET}\n"
  AI_ROOT=$(run_oc get policy.policy.open-cluster-management.io backup-restore-auto-import -n "$NS" -o json 2>/dev/null || echo "")
  if [[ -z "$AI_ROOT" ]]; then
    AI_SEARCH_NS=$(run_oc get policy.policy.open-cluster-management.io -A --no-headers 2>/dev/null | awk '$2=="backup-restore-auto-import"{print $1;exit}' || echo "")
    if [[ -n "$AI_SEARCH_NS" ]]; then
      AI_ROOT=$(run_oc get policy.policy.open-cluster-management.io backup-restore-auto-import -n "$AI_SEARCH_NS" -o json 2>/dev/null || echo "")
    fi
  fi

  if [[ -z "$AI_ROOT" ]]; then
    info "Policy not found (only present when useManagedServiceAccount is enabled on BackupSchedule)."
  else
    AI_COMPLIANCE=$(echo "$AI_ROOT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',{}).get('compliant','Unknown'))" 2>/dev/null || echo "Unknown")

    if [[ "$AI_COMPLIANCE" == "Compliant" ]]; then
      info "Overall: Compliant"
    else
      err "Overall: ${AI_COMPLIANCE}"
      AI_COMPLIANT=false
    fi

    AI_ORIG_NS=$(echo "$AI_ROOT" | python3 -c "import sys,json;print(json.load(sys.stdin)['metadata']['namespace'])" 2>/dev/null || echo "$NS")
    AI_REPLICATED=$(run_oc get policy.policy.open-cluster-management.io "${AI_ORIG_NS}.backup-restore-auto-import" -n "$LOCAL_CLUSTER_NAME" -o json 2>/dev/null || echo "")
    [[ -z "$AI_REPLICATED" ]] && AI_REPLICATED="$AI_ROOT"

    echo "$AI_REPLICATED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
details = data.get('status', {}).get('details', [])
for d in details:
    name = d.get('templateMeta', {}).get('name', 'unknown')
    compliant = d.get('compliant', 'Unknown')
    history = d.get('history', [])
    msg = ''
    if history:
        msg = history[0].get('message', '')
    if compliant == 'Compliant':
        print(f'  \033[32m[OK]\033[0m {name}')
    elif compliant == 'NonCompliant':
        print(f'  \033[31m[VIOLATION]\033[0m {name}')
        if msg:
            if len(msg) > 300:
                msg = msg[:300] + '...'
            print(f'       {msg}')
    else:
        print(f'  \033[33m[{compliant}]\033[0m {name}')
        if msg:
            if len(msg) > 300:
                msg = msg[:300] + '...'
            print(f'       {msg}')
" 2>/dev/null || true

    AI_VIOLATION_TEMPLATES=$(echo "$AI_REPLICATED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
details = data.get('status', {}).get('details', [])
violations = [d.get('templateMeta',{}).get('name','?') for d in details if d.get('compliant') == 'NonCompliant']
print(','.join(violations))
" 2>/dev/null || echo "")
  fi
fi

# --- Summary ---
header "SUMMARY"

printf "This cluster ID:     ${BOLD}%s${RESET}\n" "$CLUSTER_ID"

ROLE=""

# Helper: print schedule health warnings for the active hub
print_schedule_health() {
  if [[ "$HAS_SCHEDULE" != true ]]; then
    printf "                     ${RED}No BackupSchedule found -- backups are not being created.${RESET}\n"
  elif [[ "$SCHEDULE_PHASE" == "Paused" ]]; then
    printf "                     ${YELLOW}BackupSchedule is paused -- no new backups will be created.${RESET}\n"
  elif [[ "$SCHEDULE_PHASE" == "BackupCollision" ]]; then
    printf "                     ${YELLOW}BackupSchedule is in collision -- another cluster started writing to the same storage.${RESET}\n"
  fi
}

# Helper: print passive role based on restore phase
print_passive_role() {
  if [[ "$RESTORE_PHASE" == "Enabled" || "$RESTORE_PHASE" == "EnabledWithErrors" ]]; then
    ROLE="PASSIVE_SYNC"
    SYNC_DETAIL=""
    [[ -n "$RESTORE_SYNC_INTERVAL" ]] && SYNC_DETAIL=", syncing every $RESTORE_SYNC_INTERVAL"
    printf "Role:                ${CYAN}PASSIVE HUB (syncing)${RESET} (Restore phase: %s%s)\n" "$RESTORE_PHASE" "$SYNC_DETAIL"
  elif [[ "$RESTORE_PHASE" == "Finished" || "$RESTORE_PHASE" == "FinishedWithErrors" ]]; then
    ROLE="PASSIVE_STALE"
    COMPLETED_DETAIL=""
    [[ -n "$RESTORE_COMPLETION_TS" ]] && COMPLETED_DETAIL=" at $RESTORE_COMPLETION_TS"
    printf "Role:                ${YELLOW}PASSIVE HUB (not syncing)${RESET} -- passive data was restored once%s\n" "$COMPLETED_DETAIL"
    printf "                     and is no longer being updated. Data will become stale.\n"
  else
    ROLE="PASSIVE"
    printf "Role:                ${CYAN}PASSIVE HUB${RESET} (Restore phase: %s, MC=skip)\n" "$RESTORE_PHASE"
  fi
}

# --- Role determination (priority order) ---

# 1. Failover: this cluster performed the last managed-clusters restore → it IS the active hub
if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" ]]; then
  ROLE="ACTIVE"
  printf "Role:                ${GREEN}ACTIVE HUB${RESET} -- this cluster performed the last failover (managed-clusters restore)\n"
  print_schedule_health
  if [[ "$ACTIVE_HUB_ID" != "none" && "$ACTIVE_HUB_ID" != "unknown" && "$ACTIVE_HUB_ID" != "$CLUSTER_ID" ]]; then
    printf "                     ${YELLOW}But latest backups in storage come from hub %s -- that hub should be passive.${RESET}\n" "$ACTIVE_HUB_ID"
  fi

# 2. Validation backups owned by this cluster → active hub
elif [[ "$VAL_OWNED_BY_THIS_CLUSTER" == true ]]; then
  ROLE="ACTIVE"
  printf "Role:                ${GREEN}ACTIVE HUB${RESET} (validation backups confirm this cluster is active"
  if [[ "$HAS_SCHEDULE" == true && "$SCHEDULE_PHASE" != "BackupCollision" && "$SCHEDULE_PHASE" != "Paused" ]]; then
    printf ", BackupSchedule: %s, phase: %s" "$SCHEDULE_NAME" "$SCHEDULE_PHASE"
  fi
  printf ")\n"
  print_schedule_health

# 3. Validation backups exist but from another hub
elif [[ "$CRON_ACTIVE" == true && "$VAL_HUB_ID" != "unknown" ]]; then
  if [[ "$HAS_RESTORE" == true && "$RESTORE_MC" == "skip" ]]; then
    print_passive_role
  elif [[ "$HAS_RESTORE" == true && "$RESTORE_MC" != "skip" ]]; then
    ROLE="FAILOVER"
    printf "Role:                ${YELLOW}FAILOVER / ACTIVATION${RESET} (Restore with MC=%s)\n" "$RESTORE_MC"
  elif [[ "$HAS_SCHEDULE" == true ]]; then
    ROLE="COLLIDING"
    printf "Role:                ${YELLOW}COLLIDING${RESET} -- this cluster has a BackupSchedule but\n"
    printf "                     hub %s wrote the last backup to storage and is the active cluster. Only one hub should write backups.\n" "$VAL_HUB_ID"
  else
    ROLE="NONE"
    printf "Role:                ${RED}NOT CONFIGURED${RESET} -- another hub (%s) is the active hub,\n" "$VAL_HUB_ID"
    printf "                     but this cluster has no Restore running. To be a proper passive hub,\n"
    printf "                     create a Restore with syncRestoreWithNewBackups: true and MC=skip.\n"
  fi
  printf "Active hub:          ${BOLD}%s${RESET}\n" "$(hub_label "$VAL_HUB_ID")"

# 4. No validation backups at all
else
  if [[ "$HAS_RESTORE" == true && "$RESTORE_MC" == "skip" ]]; then
    print_passive_role
    printf "                     ${YELLOW}No validation backups found -- the active hub's cron may have stopped.${RESET}\n"
  elif [[ "$HAS_RESTORE" == true && "$RESTORE_MC" != "skip" ]]; then
    ROLE="FAILOVER"
    printf "Role:                ${YELLOW}FAILOVER / ACTIVATION${RESET} (Restore with MC=%s)\n" "$RESTORE_MC"
  elif [[ "$HAS_SCHEDULE" == true ]]; then
    ROLE="ACTIVE_NO_VALIDATION"
    printf "Role:                ${YELLOW}ACTIVE HUB (no validation backups yet)${RESET} (BackupSchedule: %s, phase: %s)\n" "$SCHEDULE_NAME" "$SCHEDULE_PHASE"
  else
    ROLE="NONE"
    printf "Role:                ${RED}NOT CONFIGURED${RESET} (no BackupSchedule or Restore)\n"
  fi
fi

# Warn if this is not the active hub and there's no proper passive sync running
if [[ "$ROLE" != "ACTIVE" && "$ROLE" != "ACTIVE_NO_VALIDATION" && "$ROLE" != "COLLIDING" \
   && "$ROLE" != "FAILOVER" && "$ROLE" != "PASSIVE_SYNC" ]]; then
  if [[ "$ROLE" == "PASSIVE_STALE" || "$ROLE" == "PASSIVE" ]]; then
    printf "                     ${YELLOW}This hub is not actively syncing passive data. A proper passive hub should\n"
    printf "                     have a Restore with syncRestoreWithNewBackups: true in Enabled state.${RESET}\n"
  elif [[ "$ROLE" == "NONE" ]]; then
    printf "                     ${YELLOW}This hub is neither active nor passive -- it will not receive backup data.${RESET}\n"
  fi
fi

printf "Active hub (by backups): ${BOLD}%s${RESET}\n" "$(hub_label "$ACTIVE_HUB_ID")"

# --- Diagnostic Analysis ---
# Collect issues as: ISSUE_ID|SEVERITY|DESCRIPTION|FIX_TYPE
# FIX_TYPE: create_schedule, remove_schedule, remove_restore, remote_only, none
ISSUES=()
ISSUE_NUM=0

add_issue() {
  ISSUE_NUM=$((ISSUE_NUM + 1))
  ISSUES+=("$ISSUE_NUM|$1|$2|$3")
}

# Failover happened on this cluster but no BackupSchedule is running
if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" && "$HAS_SCHEDULE" != true ]]; then
  add_issue "ERROR" \
    "This cluster ran managed-clusters restore (failover) so it should be the ACTIVE hub, but no BackupSchedule is running." \
    "create_schedule"
fi

# Failover happened on this cluster but a DIFFERENT hub owns the latest backups.
# Since FAILOVER_HUB == CLUSTER_ID, this cluster has the most recent managed-clusters
# restore -- if the other hub had taken over since, its ID would be in FAILOVER_HUB instead.
if [[ -n "$FAILOVER_HUB" && "$FAILOVER_HUB" == "$CLUSTER_ID" \
   && "$ACTIVE_HUB_ID" != "none" && "$ACTIVE_HUB_ID" != "unknown" \
   && "$ACTIVE_HUB_ID" != "$CLUSTER_ID" ]]; then
  add_issue "ERROR" \
    "This cluster performed the most recent failover, so it is the active hub. Hub $ACTIVE_HUB_ID is still writing backups and should be switched to passive (Restore with MC=skip)." \
    "create_schedule_and_warn_remote"
fi

# BackupSchedule is in BackupCollision -- another cluster is the active one
if [[ "$HAS_SCHEDULE" == true && "$SCHEDULE_PHASE" == "BackupCollision" ]]; then
  add_issue "WARN" \
    "BackupSchedule '$SCHEDULE_NAME' is in BackupCollision -- another cluster owns the latest backups. This schedule should be removed and the hub configured as passive." \
    "remove_collision_schedule"
fi

# This cluster is active but a different hub owns the latest backups (collision likely)
if [[ "$HAS_SCHEDULE" == true && "$SCHEDULE_PHASE" != "BackupCollision" \
   && "$ACTIVE_HUB_ID" != "none" && "$ACTIVE_HUB_ID" != "unknown" \
   && "$ACTIVE_HUB_ID" != "$CLUSTER_ID" ]]; then
  add_issue "WARN" \
    "This cluster has a BackupSchedule but the latest backups belong to hub $ACTIVE_HUB_ID. Two hubs may be writing to the same storage (collision). Only one hub should have a BackupSchedule." \
    "choose_active"
fi

# This cluster is passive but no hub is creating backups
if [[ ("$ROLE" == "PASSIVE" || "$ROLE" == "PASSIVE_SYNC") \
   && ("$ACTIVE_HUB_ID" == "none" || "$ACTIVE_HUB_ID" == "unknown") ]]; then
  add_issue "WARN" \
    "This cluster is passive but no ACM backups were found in storage. The active hub may not be running a BackupSchedule, or BSL sync has not completed." \
    "remote_only"
fi

# Passive cluster but the active cron is not running anywhere
if [[ ("$ROLE" == "PASSIVE" || "$ROLE" == "PASSIVE_SYNC") && "$CRON_ACTIVE" == false ]]; then
  add_issue "WARN" \
    "This cluster is passive but no validation-policy backups exist. The active hub's cron may have stopped or backups expired." \
    "remote_only"
fi

# This cluster is not the active hub and has no syncing passive Restore
if [[ "$ROLE" != "ACTIVE" && "$ROLE" != "ACTIVE_NO_VALIDATION" && "$ROLE" != "FAILOVER" \
   && "$ROLE" != "PASSIVE_SYNC" ]]; then
  if [[ "$HAS_RESTORE" != true ]]; then
    add_issue "WARN" \
      "No Restore running on this cluster. If another hub is the active hub, this cluster should have a Restore with syncRestoreWithNewBackups: true and MC=skip to be a proper passive hub." \
      "create_passive"
  elif [[ "$RESTORE_MC" == "skip" && "$RESTORE_PHASE" != "Enabled" && "$RESTORE_PHASE" != "EnabledWithErrors" ]]; then
    add_issue "WARN" \
      "Restore exists but is not actively syncing (phase: $RESTORE_PHASE). A proper passive hub should have a Restore with syncRestoreWithNewBackups: true in Enabled state." \
      "create_passive"
  fi
fi

# backup-restore-enabled policy violations
if [[ "$POLICY_FOUND" == true && "$POLICY_COMPLIANT" == false && -n "$POLICY_VIOLATION_TEMPLATES" ]]; then
  add_issue "ERROR" \
    "backup-restore-enabled policy is NonCompliant. Violating templates: ${POLICY_VIOLATION_TEMPLATES}. See section 9 above for details." \
    "none"
fi

# backup-restore-auto-import policy violations
if [[ "$AI_COMPLIANT" == false && -n "$AI_VIOLATION_TEMPLATES" ]]; then
  add_issue "WARN" \
    "backup-restore-auto-import policy is NonCompliant. Violating templates: ${AI_VIOLATION_TEMPLATES}. See section 9 above for details." \
    "none"
fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  printf "\n${GREEN}No configuration issues detected.${RESET}\n\n"
  exit 0
fi

# --- Display Issues ---
printf "\n"
header "ISSUES DETECTED"

for issue in "${ISSUES[@]}"; do
  IFS='|' read -r num severity desc fix_type <<< "$issue"
  if [[ "$severity" == "ERROR" ]]; then
    printf "${RED}[%d] %s${RESET} %s\n" "$num" "$severity" "$desc"
  else
    printf "${YELLOW}[%d] %s${RESET}  %s\n" "$num" "$severity" "$desc"
  fi
done

# --- Check if any issue is fixable from this cluster ---
HAS_LOCAL_FIX=false
for issue in "${ISSUES[@]}"; do
  IFS='|' read -r num severity desc fix_type <<< "$issue"
  if [[ "$fix_type" != "remote_only" && "$fix_type" != "none" ]]; then
    HAS_LOCAL_FIX=true
    break
  fi
done

if [[ "$HAS_LOCAL_FIX" == false ]]; then
  printf "\n${YELLOW}These issues require action on the remote (active) hub.${RESET}\n"
  printf "Log in to the active hub and re-run this script there.\n\n"
  exit 0
fi

# --- Interactive Fix Mode ---
printf "\n"
printf "${BOLD}Would you like help fixing these issues? [y/N]:${RESET} "
read -r FIX_ANSWER
if [[ ! "$FIX_ANSWER" =~ ^[Yy] ]]; then
  printf "Exiting without changes.\n\n"
  exit 0
fi

run_with_confirm() {
  local step_num="$1"
  local description="$2"
  local command="$3"
  printf "\n${BOLD}${CYAN}Step %s: %s${RESET}\n" "$step_num" "$description"
  printf "  Command: ${BOLD}%s${RESET}\n" "$command"
  printf "  ${BOLD}Run this? [y/N]:${RESET} "
  read -r answer
  if [[ "$answer" =~ ^[Yy] ]]; then
    printf "  Running...\n"
    if eval "$command"; then
      info "Done."
    else
      err "Command failed (exit code $?)."
    fi
    return 0
  else
    printf "  Skipped.\n"
    return 1
  fi
}

# --- Build Ordered Fix Plan ---
header "FIX PLAN"
printf "The following steps are ordered by priority.\n"
printf "You will be prompted before each step.\n"

STEP=0
NEEDS_SCHEDULE=false
NEEDS_SCHEDULE_REMOVE=false
NEEDS_RESTORE_REMOVE=false
NEEDS_COLLISION_CLEANUP=false
NEEDS_PASSIVE=false
WARN_REMOTE_HUB=""

for issue in "${ISSUES[@]}"; do
  IFS='|' read -r num severity desc fix_type <<< "$issue"
  case "$fix_type" in
    create_schedule)
      NEEDS_SCHEDULE=true
      ;;
    create_schedule_and_warn_remote)
      NEEDS_SCHEDULE=true
      WARN_REMOTE_HUB="$ACTIVE_HUB_ID"
      ;;
    choose_active)
      NEEDS_SCHEDULE_REMOVE=true
      WARN_REMOTE_HUB="$ACTIVE_HUB_ID"
      ;;
    remove_collision_schedule)
      NEEDS_COLLISION_CLEANUP=true
      ;;
    create_passive)
      NEEDS_PASSIVE=true
      ;;
  esac
done

# Step order:
# 1. If collision: ask whether THIS hub or the OTHER should be active
# 2. Clean up stale Restore if this hub should become active
# 3. Remove BackupSchedule if this hub should become passive
# 4. Create BackupSchedule if this hub should be active
# 5. Create passive Restore if this hub should become passive
# 6. Warn about remote hub actions

# BackupCollision: the schedule is already stale, offer to remove it and set up passive
if [[ "$NEEDS_COLLISION_CLEANUP" == true ]]; then
  STEP=$((STEP + 1))
  printf "\n${YELLOW}The BackupSchedule '%s' is in BackupCollision -- another cluster is the active hub.${RESET}\n" "$SCHEDULE_NAME"
  printf "  This schedule is no longer producing valid backups and should be removed.\n"
  run_with_confirm "$STEP" \
    "Remove colliding BackupSchedule '${SCHEDULE_NAME}'" \
    "$OC delete backupschedule ${SCHEDULE_NAME} -n ${NS}"

  # Offer to set up passive if no Restore is syncing
  if [[ "$RESTORE_PHASE" != "Enabled" && "$RESTORE_PHASE" != "EnabledWithErrors" ]]; then
    STEP=$((STEP + 1))
    printf "\n${BOLD}What type of passive restore do you want?${RESET}\n"
    printf "  ${BOLD}1)${RESET} Passive with sync (continuously restores new backups -- recommended)\n"
    printf "  ${BOLD}2)${RESET} Skip for now\n"
    printf "  ${BOLD}Choice [1/2]:${RESET} "
    read -r PASSIVE_CHOICE

    if [[ "$PASSIVE_CHOICE" == "1" ]]; then
      run_with_confirm "$STEP" \
        "Create passive sync Restore on this cluster" \
        "$OC apply -n ${NS} -f - <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: ${NS}
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 30m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
YAML"
    else
      printf "  Skipped.\n"
    fi
  fi
fi

if [[ "$NEEDS_SCHEDULE_REMOVE" == true ]]; then
  printf "\n${BOLD}Two hubs are writing backups. Which hub should be the ACTIVE one?${RESET}\n"
  printf "  ${BOLD}1)${RESET} This cluster (%s) -- keep BackupSchedule here, other hub should go passive\n" "$CLUSTER_ID"
  printf "  ${BOLD}2)${RESET} The other hub (%s) -- remove BackupSchedule here, make this cluster passive\n" "$ACTIVE_HUB_ID"
  printf "  ${BOLD}Choice [1/2]:${RESET} "
  read -r COLLISION_CHOICE

  if [[ "$COLLISION_CHOICE" == "2" ]]; then
    NEEDS_SCHEDULE=false
    NEEDS_SCHEDULE_REMOVE=true

    STEP=$((STEP + 1))
    RESTORE_NAMES=$(echo "$RESTORE_JSON" 2>/dev/null | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for r in items: print(r['metadata']['name'])
" 2>/dev/null || true)

    run_with_confirm "$STEP" \
      "Remove BackupSchedule '${SCHEDULE_NAME}' (this hub will stop creating backups)" \
      "$OC delete backupschedule ${SCHEDULE_NAME} -n ${NS}"

    if [[ "$HAS_RESTORE" != true ]]; then
      STEP=$((STEP + 1))
      printf "\n${BOLD}What type of passive restore do you want?${RESET}\n"
      printf "  ${BOLD}1)${RESET} Passive with sync (continuously restores new backups)\n"
      printf "  ${BOLD}2)${RESET} Passive one-time (restore once, no continuous sync)\n"
      printf "  ${BOLD}Choice [1/2]:${RESET} "
      read -r PASSIVE_CHOICE

      if [[ "$PASSIVE_CHOICE" == "1" ]]; then
        run_with_confirm "$STEP" \
          "Create passive sync Restore on this cluster" \
          "$OC apply -n ${NS} -f - <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: ${NS}
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 30m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
YAML"
      else
        run_with_confirm "$STEP" \
          "Create passive Restore on this cluster" \
          "$OC apply -n ${NS} -f - <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive
  namespace: ${NS}
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
YAML"
      fi
    fi
  else
    NEEDS_SCHEDULE_REMOVE=false
    WARN_REMOTE_HUB="$ACTIVE_HUB_ID"
  fi
fi

if [[ "$NEEDS_SCHEDULE" == true ]]; then
  # Only offer to remove the Restore if it's actively syncing (Enabled/EnabledWithErrors).
  # A Finished restore is harmless -- it already completed and won't interfere.
  if [[ "$HAS_RESTORE" == true && ("$RESTORE_PHASE" == "Enabled" || "$RESTORE_PHASE" == "EnabledWithErrors") ]]; then
    STEP=$((STEP + 1))
    printf "\n${YELLOW}Note:${RESET} An active Restore '%s' (phase=%s) is syncing passive data.\n" "$RESTORE_NAME_LATEST" "$RESTORE_PHASE"
    printf "  Since this hub should be the active hub, the syncing Restore should be removed first.\n"
    run_with_confirm "$STEP" \
      "Remove Restore '${RESTORE_NAME_LATEST}' (stop passive sync -- this hub is becoming active)" \
      "$OC delete restore.cluster.open-cluster-management.io ${RESTORE_NAME_LATEST} -n ${NS}"
  elif [[ "$HAS_RESTORE" == true ]]; then
    printf "\n${GREEN}Note:${RESET} Existing Restore '%s' (phase=%s) is in a terminal state -- no need to remove it.\n" "$RESTORE_NAME_LATEST" "$RESTORE_PHASE"
  fi

  STEP=$((STEP + 1))
  printf "\n${BOLD}Configure the BackupSchedule:${RESET}\n"
  printf "  ${BOLD}Cron expression${RESET} (how often to back up, e.g. '0 */2 * * *' for every 2h)\n"
  printf "  Press Enter for default [0 */1 * * *]: "
  read -r CRON_INPUT
  CRON="${CRON_INPUT:-0 */1 * * *}"

  printf "  ${BOLD}Backup TTL${RESET} (how long to keep backups, e.g. '120h')\n"
  printf "  Press Enter for default [120h]: "
  read -r TTL_INPUT
  TTL="${TTL_INPUT:-120h}"

  run_with_confirm "$STEP" \
    "Create BackupSchedule on this cluster (cron=$CRON, ttl=$TTL)" \
    "$OC apply -n ${NS} -f - <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: BackupSchedule
metadata:
  name: schedule-acm
  namespace: ${NS}
spec:
  veleroSchedule: ${CRON}
  veleroTtl: ${TTL}
YAML"
fi

# Create passive Restore if this hub should be passive but has no syncing Restore
if [[ "$NEEDS_PASSIVE" == true && "$NEEDS_COLLISION_CLEANUP" == false ]]; then
  STEP=$((STEP + 1))
  run_with_confirm "$STEP" \
    "Create passive sync Restore on this cluster (MC=skip, sync every 30m)" \
    "$OC apply -n ${NS} -f - <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-sync
  namespace: ${NS}
spec:
  syncRestoreWithNewBackups: true
  restoreSyncInterval: 30m
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
YAML"
fi

# --- Remote hub warnings ---
if [[ -n "$WARN_REMOTE_HUB" ]]; then
  printf "\n"
  header "ACTION REQUIRED ON REMOTE HUB"
  printf "${YELLOW}The following must be done on hub %s:${RESET}\n" "$WARN_REMOTE_HUB"
  printf "\n"

  if [[ "$NEEDS_SCHEDULE" == true || ("$NEEDS_SCHEDULE_REMOVE" != true) ]]; then
    printf "  ${BOLD}1.${RESET} Log in to hub %s\n" "$WARN_REMOTE_HUB"
    printf "  ${BOLD}2.${RESET} Delete its BackupSchedule:\n"
    printf "     ${CYAN}oc delete backupschedule -n %s --all${RESET}\n" "$NS"
    printf "  ${BOLD}3.${RESET} Create a passive Restore (with sync):\n"
    printf "     ${CYAN}oc apply -n %s -f - <<'YAML'\n" "$NS"
    printf "     apiVersion: cluster.open-cluster-management.io/v1beta1\n"
    printf "     kind: Restore\n"
    printf "     metadata:\n"
    printf "       name: restore-acm-passive-sync\n"
    printf "       namespace: %s\n" "$NS"
    printf "     spec:\n"
    printf "       syncRestoreWithNewBackups: true\n"
    printf "       restoreSyncInterval: 30m\n"
    printf "       cleanupBeforeRestore: CleanupRestored\n"
    printf "       veleroManagedClustersBackupName: skip\n"
    printf "       veleroCredentialsBackupName: latest\n"
    printf "       veleroResourcesBackupName: latest\n"
    printf "     YAML${RESET}\n"
    printf "  ${BOLD}4.${RESET} Re-run this assessment script on that hub to verify.\n"
  fi
fi

# --- Verification ---
STEP=$((STEP + 1))
printf "\n"
run_with_confirm "$STEP" \
  "Verify: re-check BackupSchedule and Restore status" \
  "echo '--- BackupSchedules ---' && $OC get backupschedules.cluster.open-cluster-management.io -n ${NS} 2>/dev/null || echo 'None' && echo '--- Restores ---' && $OC get restores.cluster.open-cluster-management.io -n ${NS} 2>/dev/null || echo 'None' && echo '--- BSL ---' && $OC get bsl -n ${NS} 2>/dev/null || echo 'None'"

printf "\n${GREEN}Fix workflow complete.${RESET}\n\n"
