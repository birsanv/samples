#!/usr/bin/env bash
# ACM VM Backup Helper
# Interactive script that discovers VMs, lets the user select which to back up,
# and ensures the virt DR policies are configured on the cluster.
#
# Usage:
#   backup-vm.sh [--context <name>]   Interactive mode
#   backup-vm.sh --list               List all VMs and their backup status
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
DIM="\033[2m"
RESET="\033[0m"

NS="open-cluster-management-backup"
BACKUP_LABEL="cluster.open-cluster-management.io/backup-vm"
POLICY_REPO="https://github.com/birsanv/samples/tree/main/virt"

# --- Parse arguments ---
CTX=""
LIST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)    CTX="$2"; shift 2 ;;
    --context=*)  CTX="${1#--context=}"; shift ;;
    --list)       LIST_ONLY=true; shift ;;
    -h|--help)
      printf "Usage: %s [--context <name>] [--list]\n\n" "$(basename "$0")"
      printf "  --context <name>   kubeconfig context to use\n"
      printf "  --list             list all VMs and their backup status, then exit\n"
      printf "  (no argument)      interactive mode\n"
      exit 0 ;;
    *)  CTX="$1"; shift ;;
  esac
done

OC_CTX=()
if [[ -n "$CTX" ]]; then
  OC_CTX=(--context "$CTX")
fi
run_oc() { oc "${OC_CTX[@]}" "$@"; }

header()  { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n" "$1"; }
info()    { printf "${GREEN}[OK]${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}[WARN]${RESET} %s\n" "$1"; }
err()     { printf "${RED}[ERROR]${RESET} %s\n" "$1"; }
step()    { printf "\n${BOLD}--- Step %s ---${RESET}\n" "$1"; }

confirm() {
  local msg="$1"
  printf "${BOLD}%s${RESET} [y/N] " "$msg"
  read -r ans </dev/tty
  [[ "$ans" =~ ^[Yy] ]]
}

# ============================================================
# Pre-flight
# ============================================================
header "Pre-flight"

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

CLUSTER_ID=$(run_oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "unknown")
printf "Cluster ID: ${BOLD}%s${RESET}\n" "$CLUSTER_ID"

IS_HUB=false
if run_oc get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null; then
  IS_HUB=true
  info "This is an ACM hub cluster"
else
  printf "This is a managed cluster\n"
fi

# ============================================================
# 1. Discover VMs
# ============================================================
header "1. Discover VirtualMachines"

if ! run_oc get crd virtualmachines.kubevirt.io &>/dev/null; then
  err "VirtualMachine CRD (kubevirt.io) not found on this cluster."
  printf "OpenShift Virtualization must be installed to back up VMs.\n"
  exit 1
fi

VM_JSON=$(run_oc get virtualmachines.kubevirt.io --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

VM_TABLE=$(echo "$VM_JSON" | python3 -c "
import sys, json

items = json.load(sys.stdin).get('items', [])
if not items:
    print('EMPTY')
    sys.exit(0)

for i, vm in enumerate(items):
    name = vm['metadata']['name']
    ns = vm['metadata']['namespace']
    uid = vm['metadata'].get('uid', '?')
    labels = vm['metadata'].get('labels', {})
    cron = labels.get('cluster.open-cluster-management.io/backup-vm', '')
    ready = 'Unknown'
    conds = vm.get('status', {}).get('conditions', [])
    for c in conds:
        if c.get('type') == 'Ready':
            ready = 'Ready' if c.get('status') == 'True' else 'NotReady'
    running = vm.get('status', {}).get('printableStatus', ready)
    backup_status = cron if cron else '-'
    print(f'{i+1}|{ns}|{name}|{running}|{backup_status}|{uid}')
" 2>/dev/null)

if [[ "$VM_TABLE" == "EMPTY" || -z "$VM_TABLE" ]]; then
  warn "No VirtualMachines found on this cluster."
  exit 0
fi

VM_COUNT=$(echo "$VM_TABLE" | wc -l | tr -d ' ')
printf "Found ${BOLD}%d${RESET} VirtualMachine(s):\n\n" "$VM_COUNT"

printf "  ${BOLD}%-4s %-25s %-20s %-12s %-20s${RESET}\n" "#" "NAMESPACE/NAME" "STATUS" "BACKUP" "UID"
echo "$VM_TABLE" | while IFS='|' read -r idx ns name status backup uid; do
  if [[ "$backup" != "-" ]]; then
    backup_display="${GREEN}${backup}${RESET}"
  else
    backup_display="${DIM}-${RESET}"
  fi
  printf "  %-4s %-25s %-20s " "$idx" "${ns}/${name}" "$status"
  printf "$backup_display"
  printf "%*s" $((20 - ${#backup})) ""
  printf " ${DIM}%.12s${RESET}\n" "$uid"
done

if [[ "$LIST_ONLY" == true ]]; then
  printf "\nLegend: BACKUP column shows the cron schedule name, '-' = not backed up.\n"
  exit 0
fi

# ============================================================
# 2. Select VMs to back up
# ============================================================
header "2. Select VMs to back up"

printf "Enter VM numbers to back up (comma-separated, e.g. 1,2,3) or 'all'.\n"
printf "VMs already backed up will be skipped unless you want to change their schedule.\n\n"
printf "${BOLD}Selection:${RESET} "
read -r SELECTION </dev/tty

SELECTED_INDICES=()
if [[ "$SELECTION" == "all" ]]; then
  for i in $(seq 1 "$VM_COUNT"); do
    SELECTED_INDICES+=("$i")
  done
else
  IFS=',' read -ra SELECTED_INDICES <<< "$SELECTION"
fi

declare -a SEL_NS=()
declare -a SEL_NAME=()
declare -a SEL_CURRENT=()
declare -a SEL_UID=()

for idx in "${SELECTED_INDICES[@]}"; do
  idx=$(echo "$idx" | tr -d ' ')
  LINE=$(echo "$VM_TABLE" | sed -n "${idx}p")
  if [[ -z "$LINE" ]]; then
    warn "Invalid index: $idx (skipping)"
    continue
  fi
  IFS='|' read -r _ ns name _ backup uid <<< "$LINE"
  SEL_NS+=("$ns")
  SEL_NAME+=("$name")
  SEL_CURRENT+=("$backup")
  SEL_UID+=("$uid")
done

if [[ ${#SEL_NAME[@]} -eq 0 ]]; then
  warn "No VMs selected. Exiting."
  exit 0
fi

printf "\nSelected %d VM(s):\n" "${#SEL_NAME[@]}"
for i in "${!SEL_NAME[@]}"; do
  printf "  - ${BOLD}%s/%s${RESET}" "${SEL_NS[$i]}" "${SEL_NAME[$i]}"
  if [[ "${SEL_CURRENT[$i]}" != "-" ]]; then
    printf "  (currently: ${GREEN}%s${RESET})" "${SEL_CURRENT[$i]}"
  fi
  printf "\n"
done

# ============================================================
# 3. Choose backup schedule
# ============================================================
header "3. Choose backup schedule"

OADP_NS="$NS"
if [[ "$IS_HUB" != true ]]; then
  BACKUP_NS_VALUE=$(run_oc get configmap "acm-dr-virt-config--cls" -n "$NS" -o jsonpath='{.data.backupNS}' 2>/dev/null || echo "")
  if [[ -n "$BACKUP_NS_VALUE" ]]; then
    OADP_NS="$BACKUP_NS_VALUE"
  fi
fi

CRON_CM_JSON=""
if [[ "$IS_HUB" == true ]]; then
  CRON_CM_JSON=$(run_oc get configmap "acm-dr-virt-schedule-cron" -n "$NS" -o json 2>/dev/null || echo "")
fi
if [[ -z "$CRON_CM_JSON" ]]; then
  CRON_CM_JSON=$(run_oc get configmap "acm-dr-virt-schedule-cron--cls" -n "$OADP_NS" -o json 2>/dev/null || echo "")
fi
if [[ -z "$CRON_CM_JSON" ]]; then
  CRON_CM_JSON=$(run_oc get configmap "acm-dr-virt-schedule-cron--cls" -n "$NS" -o json 2>/dev/null || echo "")
fi

CRON_NAMES=()
CRON_EXPRS=()
CRON_FOUND=false

if [[ -n "$CRON_CM_JSON" ]]; then
  CRON_FOUND=true
  CRON_DATA=$(echo "$CRON_CM_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', {})
for k, v in sorted(data.items()):
    print(f'{k}|{v}')
" 2>/dev/null || echo "")

  if [[ -n "$CRON_DATA" ]]; then
    printf "Available schedules (from cron ConfigMap):\n\n"
    IDX=1
    while IFS='|' read -r cname cexpr; do
      CRON_NAMES+=("$cname")
      CRON_EXPRS+=("$cexpr")
      printf "  ${BOLD}%d${RESET}) %-25s %s\n" "$IDX" "$cname" "$cexpr"
      IDX=$((IDX + 1))
    done <<< "$CRON_DATA"

    printf "\nEnter schedule number or type a custom schedule name: "
    read -r SCHED_CHOICE </dev/tty

    if [[ "$SCHED_CHOICE" =~ ^[0-9]+$ ]] && [[ "$SCHED_CHOICE" -ge 1 ]] && [[ "$SCHED_CHOICE" -le ${#CRON_NAMES[@]} ]]; then
      CHOSEN_SCHEDULE="${CRON_NAMES[$((SCHED_CHOICE - 1))]}"
    else
      CHOSEN_SCHEDULE="$SCHED_CHOICE"
    fi
  else
    CRON_FOUND=false
  fi
fi

if [[ "$CRON_FOUND" != true ]]; then
  warn "No schedule cron ConfigMap found on this cluster."
  printf "The virt DR policies may not be configured yet.\n"
  printf "Enter a schedule name to use (e.g. daily_8am): "
  read -r CHOSEN_SCHEDULE </dev/tty
fi

if [[ -z "$CHOSEN_SCHEDULE" ]]; then
  err "No schedule selected. Exiting."
  exit 1
fi

printf "\nSchedule: ${BOLD}${GREEN}%s${RESET}\n" "$CHOSEN_SCHEDULE"

# Validate the chosen schedule exists in the cron CM
SCHEDULE_VALID=false
for cname in "${CRON_NAMES[@]:-}"; do
  if [[ "$cname" == "$CHOSEN_SCHEDULE" ]]; then
    SCHEDULE_VALID=true
    break
  fi
done

if [[ "$SCHEDULE_VALID" != true && "$CRON_FOUND" == true ]]; then
  warn "Schedule '$CHOSEN_SCHEDULE' is not defined in the cron ConfigMap."
  printf "The backup policy will report a violation until it is added.\n"
  if confirm "Add '$CHOSEN_SCHEDULE' to the cron ConfigMap now?"; then
    printf "Enter the cron expression (e.g. '0 8 * * *'): "
    read -r NEW_CRON_EXPR </dev/tty
    if [[ -n "$NEW_CRON_EXPR" ]]; then
      # Find the hub-side cron CM name from the config
      HUB_CRON_CM=""
      CONFIG_NAME=$(run_oc get managedcluster -l local-cluster=true -o jsonpath='{.items[0].metadata.labels.acm-virt-config}' 2>/dev/null || echo "")
      if [[ -n "$CONFIG_NAME" ]]; then
        HUB_CRON_CM=$(run_oc get configmap "$CONFIG_NAME" -n "$NS" -o jsonpath='{.data.schedule_hub_config_name}' 2>/dev/null || echo "")
      fi
      if [[ -n "$HUB_CRON_CM" ]]; then
        printf "Adding to hub ConfigMap '%s'...\n" "$HUB_CRON_CM"
        run_oc patch configmap "$HUB_CRON_CM" -n "$NS" --type merge \
          -p "{\"data\":{\"$CHOSEN_SCHEDULE\":\"$NEW_CRON_EXPR\"}}" 2>/dev/null && \
          info "Added '$CHOSEN_SCHEDULE: $NEW_CRON_EXPR' to '$HUB_CRON_CM'" || \
          warn "Failed to patch ConfigMap. You may need to add it manually."
      else
        warn "Could not determine the hub cron ConfigMap name. Add it manually:"
        printf "  oc patch configmap <cron-cm> -n %s --type merge -p '{\"data\":{\"%s\":\"%s\"}}'\n" "$NS" "$CHOSEN_SCHEDULE" "$NEW_CRON_EXPR"
      fi
    fi
  fi
fi

# ============================================================
# 4. Check policy infrastructure
# ============================================================
header "4. Verify policy infrastructure"

POLICIES_OK=true
NEEDS_POLICY_INSTALL=false
NEEDS_MC_LABEL=false

step "4a: Check policies exist on hub"

POLICY_COUNT=0
for pname in acm-dr-virt-install acm-dr-virt-backup acm-dr-virt-restore; do
  if run_oc get policy.policy.open-cluster-management.io "$pname" -n "$NS" &>/dev/null; then
    POLICY_COUNT=$((POLICY_COUNT + 1))
  fi
done

if [[ "$POLICY_COUNT" -eq 3 ]]; then
  info "All 3 virt DR policies found"
else
  warn "Only $POLICY_COUNT/3 virt DR policies found in $NS"
  NEEDS_POLICY_INSTALL=true
  POLICIES_OK=false

  printf "\nThe virt DR policies are automatically created when cluster-backup\n"
  printf "is enabled on MultiClusterHub. Check if cluster-backup is enabled:\n\n"
  printf "  oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(%%40.name==\"cluster-backup\")].enabled}{\"\\\\n\"}{end}'\n\n"
  printf "If not enabled, the admin must enable cluster-backup on MCH.\n"
  printf "Reference implementation: %s\n" "$POLICY_REPO"
fi

step "4b: Check ManagedCluster label"

MC_NAME=""
VIRT_CONFIG_LABEL=""
if [[ "$IS_HUB" == true ]]; then
  MC_NAME=$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "local-cluster")
else
  MC_NAME=$(run_oc get managedclusters --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "")
fi

if [[ -n "$MC_NAME" ]]; then
  VIRT_CONFIG_LABEL=$(run_oc get managedcluster "$MC_NAME" -o jsonpath='{.metadata.labels.acm-virt-config}' 2>/dev/null || echo "")
fi

if [[ -n "$VIRT_CONFIG_LABEL" ]]; then
  info "ManagedCluster '$MC_NAME' has acm-virt-config=$VIRT_CONFIG_LABEL"
else
  warn "ManagedCluster '$MC_NAME' does not have the acm-virt-config label."
  NEEDS_MC_LABEL=true
  POLICIES_OK=false
fi

step "4c: Check configuration ConfigMap"

CONFIG_EXISTS=false
if [[ -n "$VIRT_CONFIG_LABEL" ]]; then
  if run_oc get configmap "$VIRT_CONFIG_LABEL" -n "$NS" &>/dev/null; then
    CONFIG_EXISTS=true
    info "ConfigMap '$VIRT_CONFIG_LABEL' exists"
  else
    err "ConfigMap '$VIRT_CONFIG_LABEL' not found in $NS"
    POLICIES_OK=false
  fi
fi

if [[ "$CONFIG_EXISTS" != true && "$NEEDS_MC_LABEL" == true ]]; then
  printf "\n${BOLD}The virt DR policies need a configuration ConfigMap.${RESET}\n"
  printf "When cluster-backup is enabled on MCH, the ConfigMaps are auto-created:\n"
  printf "  - acm-dr-virt-config\n"
  printf "  - acm-dr-virt-schedule-cron (9 predefined schedules)\n"
  printf "  - acm-dr-virt-restore-config\n\n"

  DEFAULT_CM_NAME="acm-dr-virt-config"
  if run_oc get configmap "$DEFAULT_CM_NAME" -n "$NS" &>/dev/null; then
    info "Default ConfigMap '$DEFAULT_CM_NAME' already exists"
    VIRT_CONFIG_LABEL="$DEFAULT_CM_NAME"
    CONFIG_EXISTS=true
  else
    printf "${YELLOW}[WARN]${RESET} Default ConfigMap '%s' not found.\n" "$DEFAULT_CM_NAME"
    printf "Ensure cluster-backup is enabled on MCH to auto-create it.\n\n"

    if confirm "Create a basic configuration ConfigMap as a fallback?"; then
      printf "Enter a name for the ConfigMap [acm-dr-virt-config]: "
      read -r NEW_CM_NAME </dev/tty
      [[ -z "$NEW_CM_NAME" ]] && NEW_CM_NAME="acm-dr-virt-config"

      printf "Enter the OADP namespace for this cluster [open-cluster-management-backup]: "
      read -r NEW_OADP_NS </dev/tty
      [[ -z "$NEW_OADP_NS" ]] && NEW_OADP_NS="open-cluster-management-backup"

      SCHED_CM_NAME="acm-dr-virt-schedule-cron"
      RESTORE_CM_NAME="acm-dr-virt-restore-config"
      CRED_SECRET_NAME="cloud-credentials"

      printf "\nCreating ConfigMap '%s'...\n" "$NEW_CM_NAME"
      run_oc create configmap "$NEW_CM_NAME" -n "$NS" \
        --from-literal=backupNS="$NEW_OADP_NS" \
        --from-literal=channel="" \
        --from-literal=dpa_name="" \
        --from-literal=dpa_spec="" \
        --from-literal=credentials_hub_secret_name="$CRED_SECRET_NAME" \
        --from-literal=credentials_name="$CRED_SECRET_NAME" \
        --from-literal=schedule_hub_config_name="$SCHED_CM_NAME" \
        --from-literal=restore_hub_config_name="$RESTORE_CM_NAME" \
        --from-literal=scheduleTTL="120h" \
        2>/dev/null && info "Created ConfigMap '$NEW_CM_NAME'" || \
        warn "Failed to create ConfigMap. Create it manually."

      if ! run_oc get configmap "$SCHED_CM_NAME" -n "$NS" &>/dev/null; then
        printf "Creating schedule cron ConfigMap '%s'...\n" "$SCHED_CM_NAME"
        CRON_CREATE_ARGS=(
          --from-literal=hourly="0 */1 * * *"
          --from-literal=every_2_hours="0 */2 * * *"
          --from-literal=every_3_hours="0 */3 * * *"
          --from-literal=every_4_hours="0 */4 * * *"
          --from-literal=every_5_hours="0 */5 * * *"
          --from-literal=every_6_hours="0 */6 * * *"
          --from-literal=twice_a_day="0 0,12 * * *"
          --from-literal=daily_8am="0 8 * * *"
          --from-literal=every_sunday="0 0 * * 0"
        )
        if [[ "$SCHEDULE_VALID" != true && -n "$CHOSEN_SCHEDULE" && -n "${NEW_CRON_EXPR:-}" ]]; then
          CRON_CREATE_ARGS+=(--from-literal="$CHOSEN_SCHEDULE"="$NEW_CRON_EXPR")
        fi
        run_oc create configmap "$SCHED_CM_NAME" -n "$NS" "${CRON_CREATE_ARGS[@]}" \
          2>/dev/null && info "Created '$SCHED_CM_NAME' with predefined schedules" || \
          warn "Failed to create cron ConfigMap."
      fi

      if ! run_oc get configmap "$RESTORE_CM_NAME" -n "$NS" &>/dev/null; then
        printf "Creating restore ConfigMap '%s' (empty)...\n" "$RESTORE_CM_NAME"
        run_oc create configmap "$RESTORE_CM_NAME" -n "$NS" \
          2>/dev/null && info "Created '$RESTORE_CM_NAME'" || \
          warn "Failed to create restore ConfigMap."
      fi

      VIRT_CONFIG_LABEL="$NEW_CM_NAME"
      CONFIG_EXISTS=true

      printf "\n${YELLOW}[IMPORTANT]${RESET} You still need to configure these in '%s':\n" "$NEW_CM_NAME"
      printf "  - dpa_name:  name of the DataProtectionApplication\n"
      printf "  - dpa_spec:  DPA spec JSON (backup locations, plugins, credentials)\n"
      printf "  - channel:   OADP channel (e.g. stable-1.4)\n"
      printf "  - credentials secret: create '%s' in %s\n\n" "$CRED_SECRET_NAME" "$NS"
      printf "Edit with: oc edit configmap %s -n %s\n" "$NEW_CM_NAME" "$NS"
    fi
  fi
fi

if [[ "$NEEDS_MC_LABEL" == true && -n "$MC_NAME" ]]; then
  [[ -z "$VIRT_CONFIG_LABEL" ]] && VIRT_CONFIG_LABEL="acm-dr-virt-config"
  if confirm "Label ManagedCluster '$MC_NAME' with acm-virt-config=$VIRT_CONFIG_LABEL?"; then
    run_oc label managedcluster "$MC_NAME" "acm-virt-config=$VIRT_CONFIG_LABEL" --overwrite 2>/dev/null && \
      info "Labeled '$MC_NAME' with acm-virt-config=$VIRT_CONFIG_LABEL" || \
      warn "Failed to label. Run: oc label managedcluster $MC_NAME acm-virt-config=$VIRT_CONFIG_LABEL"
  else
    printf "Skipping. Label manually:\n  oc label managedcluster %s acm-virt-config=%s\n" "$MC_NAME" "$VIRT_CONFIG_LABEL"
  fi
fi

step "4d: Check OADP and DPA"

DPA_OK=false
DPA_COUNT=$(run_oc get dataprotectionapplications.oadp.openshift.io -n "$OADP_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DPA_COUNT" -gt 0 ]]; then
  DPA_OK=true
  info "DataProtectionApplication found in $OADP_NS"
else
  warn "No DataProtectionApplication in $OADP_NS"
  if [[ "$IS_HUB" == true ]]; then
    printf "  On hub, OADP is installed via MCH backup option. Enable it first.\n"
  else
    printf "  The acm-dr-virt-install policy will create DPA once policies are placed and config is set.\n"
  fi
fi

BSL_AVAIL=$(run_oc get backupstoragelocations.velero.io -n "$OADP_NS" --no-headers 2>/dev/null | grep -c "Available" || echo "0")
if [[ "$BSL_AVAIL" -gt 0 ]]; then
  info "$BSL_AVAIL BSL(s) Available"
else
  warn "No BackupStorageLocation in Available phase in $OADP_NS"
fi

step "4e: Check acm-dr-virt-install policy compliance"

INSTALL_POLICY_OK=true
if run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
  LOCAL_CLUSTER_NS=$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "")
  [[ -z "$LOCAL_CLUSTER_NS" ]] && LOCAL_CLUSTER_NS="local-cluster"

  ROOT_POLICY=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-install -n "$NS" -o json 2>/dev/null || echo "")
  if [[ -z "$ROOT_POLICY" ]]; then
    warn "acm-dr-virt-install policy not found in $NS"
    INSTALL_POLICY_OK=false
  else
    ROOT_COMPLIANCE=$(echo "$ROOT_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(p.get('status', {}).get('compliant', 'Unknown'))
" 2>/dev/null || echo "Unknown")

    if [[ "$ROOT_COMPLIANCE" == "Compliant" ]]; then
      info "acm-dr-virt-install is Compliant"
    else
      INSTALL_POLICY_OK=false
      err "acm-dr-virt-install is ${ROOT_COMPLIANCE}"

      REPL_POLICY=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$LOCAL_CLUSTER_NS" -o json 2>/dev/null || echo "")
      if [[ -n "$REPL_POLICY" ]]; then
        printf "\n  ${BOLD}Per-template status:${RESET}\n"
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
        msg = conds[0].get('message', '')[:150]
    status_icon = 'OK' if comp == 'Compliant' else 'ISSUE'
    print(f'    [{status_icon}] {tname}: {comp}')
    if comp != 'Compliant' and msg:
        print(f'           {msg}')
" 2>/dev/null || true

        VIOLATED=$(echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
violated = [d.get('templateMeta', {}).get('name', '?') for d in details if d.get('compliant') != 'Compliant']
for v in violated:
    print(v)
" 2>/dev/null || echo "")

        printf "\n  ${BOLD}Suggested fixes:${RESET}\n"
        echo "$VIOLATED" | while IFS= read -r tmpl; do
          case "$tmpl" in
            *check-config-file*)
              printf "    - ${YELLOW}%s${RESET}: ConfigMap, cron CM, restore CM, or credentials secret missing on hub.\n" "$tmpl"
              printf "      Check: oc get configmap acm-dr-virt-config -n %s\n" "$NS"
              printf "             oc get secret <credentials> -n %s\n" "$NS"
              ;;
            *check-oadp-channel*)
              printf "    - ${YELLOW}%s${RESET}: OADP subscription channel mismatch or unhealthy catalog source.\n" "$tmpl"
              printf "      Check: oc get subscription -n %s -o yaml\n" "$OADP_NS"
              ;;
            *check-dpa-config*)
              printf "    - ${YELLOW}%s${RESET}: DPA missing kubevirt/csi plugins, nodeAgent not enabled, or BSL not Available.\n" "$tmpl"
              printf "      Check: oc get dataprotectionapplication -n %s -o yaml\n" "$OADP_NS"

              if [[ "$IS_HUB" == true ]]; then
                printf "\n      ${BOLD}On the hub${RESET}, OADP is managed by MCH. The DPA needs to be patched directly.\n"

                DPA_NAME_FOUND=$(run_oc get dataprotectionapplication -n "$OADP_NS" --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "")
                if [[ -n "$DPA_NAME_FOUND" ]]; then
                  DPA_JSON=$(run_oc get dataprotectionapplication "$DPA_NAME_FOUND" -n "$OADP_NS" -o json 2>/dev/null || echo "")
                  MISSING_ITEMS=()

                  HAS_KUBEVIRT=$(echo "$DPA_JSON" | python3 -c "
import sys, json
dpa = json.load(sys.stdin)
plugins = dpa.get('spec',{}).get('configuration',{}).get('velero',{}).get('defaultPlugins',[])
print('yes' if 'kubevirt' in plugins else 'no')
" 2>/dev/null || echo "no")

                  HAS_CSI=$(echo "$DPA_JSON" | python3 -c "
import sys, json
dpa = json.load(sys.stdin)
plugins = dpa.get('spec',{}).get('configuration',{}).get('velero',{}).get('defaultPlugins',[])
print('yes' if 'csi' in plugins else 'no')
" 2>/dev/null || echo "no")

                  NODE_AGENT_OK=$(echo "$DPA_JSON" | python3 -c "
import sys, json
dpa = json.load(sys.stdin)
na = dpa.get('spec',{}).get('configuration',{}).get('nodeAgent',{})
enabled = na.get('enable', False)
uploader = na.get('uploaderType', '')
print('yes' if enabled and uploader == 'kopia' else 'no')
" 2>/dev/null || echo "no")

                  SNAPSHOT_MOVE=$(echo "$DPA_JSON" | python3 -c "
import sys, json
dpa = json.load(sys.stdin)
locs = dpa.get('spec',{}).get('backupLocations',[])
has_smd = any(loc.get('velero',{}).get('config',{}).get('snapshotMoveData','') == 'true' for loc in locs)
print('yes' if has_smd else 'no')
" 2>/dev/null || echo "no")

                  [[ "$HAS_KUBEVIRT" != "yes" ]] && MISSING_ITEMS+=("kubevirt plugin")
                  [[ "$HAS_CSI" != "yes" ]] && MISSING_ITEMS+=("csi plugin")
                  [[ "$NODE_AGENT_OK" != "yes" ]] && MISSING_ITEMS+=("nodeAgent (enable+kopia)")
                  [[ "$SNAPSHOT_MOVE" != "yes" ]] && MISSING_ITEMS+=("snapshotMoveData")

                  if [[ ${#MISSING_ITEMS[@]} -gt 0 ]]; then
                    printf "\n      DPA '%s' is missing: %s\n" "$DPA_NAME_FOUND" "$(IFS=', '; echo "${MISSING_ITEMS[*]}")"

                    if confirm "      Fix the DPA now by patching '$DPA_NAME_FOUND'?"; then
                      CURRENT_PLUGINS=$(echo "$DPA_JSON" | python3 -c "
import sys, json
dpa = json.load(sys.stdin)
plugins = dpa.get('spec',{}).get('configuration',{}).get('velero',{}).get('defaultPlugins',[])
if 'kubevirt' not in plugins: plugins.append('kubevirt')
if 'csi' not in plugins: plugins.append('csi')
print(json.dumps(plugins))
" 2>/dev/null || echo '["openshift","csi","kubevirt"]')

                      PATCH_JSON=$(python3 -c "
import json
patch = {'spec': {'configuration': {
    'velero': {'defaultPlugins': json.loads('${CURRENT_PLUGINS}')},
    'nodeAgent': {'enable': True, 'uploaderType': 'kopia'}
}}}
print(json.dumps(patch))
" 2>/dev/null)

                      if [[ -n "$PATCH_JSON" ]]; then
                        printf "      Patching DPA plugins and nodeAgent...\n"
                        run_oc patch dataprotectionapplication "$DPA_NAME_FOUND" -n "$OADP_NS" \
                          --type merge -p "$PATCH_JSON" 2>/dev/null && \
                          info "    Patched DPA '$DPA_NAME_FOUND' with kubevirt, csi plugins and nodeAgent" || \
                          warn "    Failed to patch DPA. Patch manually: oc edit dataprotectionapplication $DPA_NAME_FOUND -n $OADP_NS"
                      fi

                      if [[ "$SNAPSHOT_MOVE" != "yes" ]]; then
                        printf "      ${YELLOW}Note:${RESET} snapshotMoveData must be set in backupLocations.\n"
                        printf "      This requires editing the BSL config; run:\n"
                        printf "        oc edit dataprotectionapplication %s -n %s\n" "$DPA_NAME_FOUND" "$OADP_NS"
                        printf "      Add under spec.backupLocations[].velero.config:\n"
                        printf "        snapshotMoveData: \"true\"\n"
                      fi
                    fi
                  fi
                else
                  printf "      No DPA found in %s. OADP may not be installed.\n" "$OADP_NS"
                  printf "      Ensure cluster-backup is enabled on MCH.\n"
                fi

              else
                printf "\n      ${BOLD}On a managed cluster${RESET}, the DPA is created by the policy from the hub ConfigMap.\n"
                CM_NAME="${VIRT_CONFIG_LABEL:-acm-dr-virt-config}"

                CM_JSON=$(run_oc get configmap "$CM_NAME" -n "$NS" -o json 2>/dev/null || echo "")
                HAS_DPA_SPEC=false
                if [[ -n "$CM_JSON" ]]; then
                  DPA_SPEC_VAL=$(echo "$CM_JSON" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('data',{}).get('dpa_spec',''))
" 2>/dev/null || echo "")
                  [[ -n "$DPA_SPEC_VAL" ]] && HAS_DPA_SPEC=true
                fi

                if [[ "$HAS_DPA_SPEC" == true ]]; then
                  printf "      Current dpa_spec in '%s':\n" "$CM_NAME"
                  printf "      %s\n" "$DPA_SPEC_VAL"
                  printf "\n      Verify it includes kubevirt + csi plugins and nodeAgent with kopia.\n"
                  printf "      Edit: oc edit configmap %s -n %s\n" "$CM_NAME" "$NS"
                else
                  printf "      dpa_spec is empty or missing in ConfigMap '%s'.\n" "$CM_NAME"
                fi

                if confirm "      Open the ConfigMap for editing now?"; then
                  printf "\n      Running: oc edit configmap %s -n %s\n" "$CM_NAME" "$NS"
                  printf "      ${YELLOW}The dpa_spec field must include (as a JSON string):${RESET}\n"
                  printf '        {"backupLocations":[{"velero":{"config":{"region":"<region>","s3Url":"<url>","snapshotMoveData":"true"},"credential":{"key":"cloud","name":"<secret>"},"default":true,"objectStorage":{"bucket":"<bucket>","prefix":"velero"},"provider":"aws"}}],"configuration":{"nodeAgent":{"enable":true,"uploaderType":"kopia"},"velero":{"defaultPlugins":["openshift","csi","kubevirt"]}}}\n'
                  printf "\n"
                  run_oc edit configmap "$CM_NAME" -n "$NS" </dev/tty || \
                    warn "    Edit cancelled or failed. Edit manually: oc edit configmap $CM_NAME -n $NS"
                  printf "      After saving, the policy will reconcile the DPA on this cluster.\n"
                fi
              fi
              ;;
            *install-oadp-copy-config*)
              printf "    - ${YELLOW}%s${RESET}: Enforce template failed to create resources.\n" "$tmpl"
              printf "      Check operator logs and namespace permissions.\n"
              ;;
            *)
              if [[ -n "$tmpl" ]]; then
                printf "    - ${YELLOW}%s${RESET}: Check template details above.\n" "$tmpl"
              fi
              ;;
          esac
        done
      fi

      printf "\n      Waiting for policy to reconcile"
      RECHECK_ATTEMPTS=6
      RECHECK_OK=false
      for attempt in $(seq 1 "$RECHECK_ATTEMPTS"); do
        printf "."
        sleep 10
        RECHECK_COMPLIANCE=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-install -n "$NS" \
          -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
        if [[ "$RECHECK_COMPLIANCE" == "Compliant" ]]; then
          RECHECK_OK=true
          break
        fi
      done
      printf "\n"

      if [[ "$RECHECK_OK" == true ]]; then
        info "acm-dr-virt-install is now Compliant"
        INSTALL_POLICY_OK=true
      else
        RECHECK_COMPLIANCE=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-install -n "$NS" \
          -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
        warn "acm-dr-virt-install is still ${RECHECK_COMPLIANCE} after waiting"

        REPL_RECHECK=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$LOCAL_CLUSTER_NS" -o json 2>/dev/null || echo "")
        if [[ -n "$REPL_RECHECK" ]]; then
          printf "\n  ${BOLD}Current per-template status:${RESET}\n"
          echo "$REPL_RECHECK" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
for d in details:
    tname = d.get('templateMeta', {}).get('name', '?')
    comp = d.get('compliant', '?')
    conds = d.get('conditions', [])
    msg = ''
    if conds:
        msg = conds[0].get('message', '')[:150]
    status_icon = 'OK' if comp == 'Compliant' else 'ISSUE'
    print(f'    [{status_icon}] {tname}: {comp}')
    if comp != 'Compliant' and msg:
        print(f'           {msg}')
" 2>/dev/null || true
        fi

        printf "\n${YELLOW}[WARNING]${RESET} The install policy is not Compliant. Backups will NOT work until this is resolved.\n"
        if ! confirm "Continue labeling VMs anyway?"; then
          printf "Exiting. Fix the install policy issues first, then re-run.\n"
          exit 1
        fi
      fi
    fi
  fi
else
  warn "Policy CRD not found -- cannot verify install policy compliance."
fi

# ============================================================
# 5. Apply backup labels
# ============================================================
header "5. Apply backup labels"

printf "Will apply label: ${BOLD}%s=%s${RESET}\n\n" "$BACKUP_LABEL" "$CHOSEN_SCHEDULE"

LABELED_COUNT=0
SKIPPED_COUNT=0

for i in "${!SEL_NAME[@]}"; do
  vm_ns="${SEL_NS[$i]}"
  vm_name="${SEL_NAME[$i]}"
  current="${SEL_CURRENT[$i]}"

  if [[ "$current" == "$CHOSEN_SCHEDULE" ]]; then
    printf "  ${DIM}%-25s already has schedule '%s' -- skipped${RESET}\n" "${vm_ns}/${vm_name}" "$current"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if [[ "$current" != "-" ]]; then
    printf "  ${YELLOW}%-25s currently: %s -> %s${RESET}" "${vm_ns}/${vm_name}" "$current" "$CHOSEN_SCHEDULE"
  else
    printf "  %-25s -> %s" "${vm_ns}/${vm_name}" "$CHOSEN_SCHEDULE"
  fi

  if run_oc label virtualmachine.kubevirt.io "$vm_name" -n "$vm_ns" \
    "${BACKUP_LABEL}=${CHOSEN_SCHEDULE}" --overwrite 2>/dev/null; then
    printf "  ${GREEN}OK${RESET}\n"
    LABELED_COUNT=$((LABELED_COUNT + 1))
  else
    printf "  ${RED}FAILED${RESET}\n"
  fi
done

printf "\n${BOLD}Results:${RESET} %d labeled, %d skipped\n" "$LABELED_COUNT" "$SKIPPED_COUNT"

# ============================================================
# 6. Check backup policy after labeling
# ============================================================
if [[ "$LABELED_COUNT" -gt 0 ]]; then
  header "6. Verify acm-dr-virt-backup policy"

  if run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
    LOCAL_CLUSTER_NS="${LOCAL_CLUSTER_NS:-$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "local-cluster")}"

    printf "Waiting for backup policy to reconcile after labeling"
    BACKUP_POLICY_OK=false
    for attempt in $(seq 1 6); do
      printf "."
      sleep 10
      BP_COMPLIANCE=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-backup -n "$NS" \
        -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
      if [[ "$BP_COMPLIANCE" == "Compliant" ]]; then
        BACKUP_POLICY_OK=true
        break
      fi
    done
    printf "\n"

    if [[ "$BACKUP_POLICY_OK" == true ]]; then
      info "acm-dr-virt-backup is Compliant"

      SCHED_NAME="acm-rho-virt-schedule-$(echo "$CHOSEN_SCHEDULE" | tr '_' '-')"
      SCHED_EXISTS=$(run_oc get schedule.velero.io "$SCHED_NAME" -n "$OADP_NS" --no-headers 2>/dev/null || echo "")
      if [[ -n "$SCHED_EXISTS" ]]; then
        info "Velero Schedule '$SCHED_NAME' created"
      fi
    else
      BP_COMPLIANCE=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-backup -n "$NS" \
        -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")

      if [[ "$BP_COMPLIANCE" == "Unknown" || -z "$BP_COMPLIANCE" ]]; then
        warn "acm-dr-virt-backup policy not found or has no status yet"
      else
        err "acm-dr-virt-backup is ${BP_COMPLIANCE}"

        BP_REPL=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-backup" -n "$LOCAL_CLUSTER_NS" -o json 2>/dev/null || echo "")
        if [[ -n "$BP_REPL" ]]; then
          printf "\n  ${BOLD}Per-template status:${RESET}\n"
          echo "$BP_REPL" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
for d in details:
    tname = d.get('templateMeta', {}).get('name', '?')
    comp = d.get('compliant', '?')
    conds = d.get('conditions', [])
    msg = ''
    if conds:
        msg = conds[0].get('message', '')[:150]
    status_icon = 'OK' if comp == 'Compliant' else 'ISSUE'
    print(f'    [{status_icon}] {tname}: {comp}')
    if comp != 'Compliant' and msg:
        print(f'           {msg}')
" 2>/dev/null || true

          BP_VIOLATED=$(echo "$BP_REPL" | python3 -c "
import sys, json
p = json.load(sys.stdin)
details = p.get('status', {}).get('details', [])
violated = [d.get('templateMeta', {}).get('name', '?') for d in details if d.get('compliant') != 'Compliant']
for v in violated:
    print(v)
" 2>/dev/null || echo "")

          printf "\n  ${BOLD}Suggested fixes:${RESET}\n"
          echo "$BP_VIOLATED" | while IFS= read -r btmpl; do
            case "$btmpl" in
              *create-virt-backup*)
                printf "    - ${YELLOW}%s${RESET}: Velero CRD not installed or config not propagated yet.\n" "$btmpl"
                printf "      Ensure acm-dr-virt-install is Compliant first.\n"
                printf "      Check: oc get policy acm-dr-virt-install -n %s\n" "$NS"
                ;;
              *check-backup-status-completed*)
                printf "    - ${YELLOW}%s${RESET}: Latest backup or DataUpload not in Completed phase.\n" "$btmpl"
                printf "      This is expected if the first backup hasn't run yet (wait for the cron schedule).\n"
                printf "      Check: oc get backups.velero.io -n %s -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt\n" "$OADP_NS"
                printf "             oc get dataupload -n %s\n" "$OADP_NS"
                ;;
              *check-cron-schedule-valid*)
                printf "    - ${YELLOW}%s${RESET}: A VM uses a backup-vm label value not in the cron ConfigMap.\n" "$btmpl"
                printf "      The schedule '%s' may not exist in acm-dr-virt-schedule-cron.\n" "$CHOSEN_SCHEDULE"
                printf "      Check: oc get configmap acm-dr-virt-schedule-cron -n %s -o yaml\n" "$NS"
                if confirm "      Add '$CHOSEN_SCHEDULE' to the cron ConfigMap now?"; then
                  printf "      Enter the cron expression (e.g. '0 8 * * *'): "
                  read -r FIX_CRON_EXPR </dev/tty
                  if [[ -n "$FIX_CRON_EXPR" ]]; then
                    HUB_CRON_CM_FIX=$(run_oc get configmap "${VIRT_CONFIG_LABEL:-acm-dr-virt-config}" -n "$NS" \
                      -o jsonpath='{.data.schedule_hub_config_name}' 2>/dev/null || echo "acm-dr-virt-schedule-cron")
                    run_oc patch configmap "$HUB_CRON_CM_FIX" -n "$NS" --type merge \
                      -p "{\"data\":{\"$CHOSEN_SCHEDULE\":\"$FIX_CRON_EXPR\"}}" 2>/dev/null && \
                      info "    Added '$CHOSEN_SCHEDULE: $FIX_CRON_EXPR' to '$HUB_CRON_CM_FIX'" || \
                      warn "    Failed to patch. Add manually: oc patch configmap $HUB_CRON_CM_FIX -n $NS --type merge -p '{\"data\":{\"$CHOSEN_SCHEDULE\":\"$FIX_CRON_EXPR\"}}'"
                  fi
                fi
                ;;
              *)
                if [[ -n "$btmpl" ]]; then
                  printf "    - ${YELLOW}%s${RESET}: Check template details above.\n" "$btmpl"
                fi
                ;;
            esac
          done
        fi
      fi
    fi
  else
    warn "Policy CRD not found -- cannot verify backup policy compliance."
  fi
fi

# ============================================================
# 7. Summary and next steps
# ============================================================
header "Summary"

if [[ "$LABELED_COUNT" -gt 0 ]]; then
  info "$LABELED_COUNT VM(s) labeled for backup with schedule '$CHOSEN_SCHEDULE'"
fi

printf "\n${BOLD}What happens next:${RESET}\n"
printf "  1. The acm-dr-virt-backup policy detects the labeled VMs\n"
printf "  2. A velero Schedule 'acm-rho-virt-schedule-%s' is created\n" "$(echo "$CHOSEN_SCHEDULE" | tr '_' '-')"
printf "  3. Backups start according to the cron schedule\n"

if [[ "$DPA_OK" != true ]]; then
  printf "\n${YELLOW}[ACTION NEEDED]${RESET} DPA is not configured yet. Backups won't start until:\n"
  printf "  - OADP is installed and DPA is created with kubevirt, csi plugins\n"
  printf "  - BackupStorageLocation is Available\n"
  if [[ "$IS_HUB" == true ]]; then
    printf "  - On hub: ensure cluster-backup is enabled on MCH (auto-installs OADP)\n"
  else
    printf "  - Configure dpa_spec in acm-dr-virt-config ConfigMap on the hub\n"
  fi
fi

printf "\n${BOLD}Useful commands:${RESET}\n"
printf "  # Check velero schedules\n"
printf "  oc get schedules.velero.io -n %s -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt\n\n" "$OADP_NS"
printf "  # Check backup status\n"
printf "  oc get backups.velero.io -n %s -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt\n\n" "$OADP_NS"
printf "  # Check policy compliance\n"
printf "  oc get policy -n %s | grep acm-dr-virt\n\n" "$NS"
