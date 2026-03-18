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

# Run oc on the cluster that owns a VM (uses saved context for managed clusters)
run_oc_on_cluster() {
  local cluster="$1"; shift
  local ctx="${MC_CONTEXT_MAP[$cluster]:-}"
  if [[ -n "$ctx" ]]; then
    oc --context "$ctx" "$@"
  else
    run_oc "$@"
  fi
}

# Label a VM on a managed cluster via ManifestWork (ServerSideApply).
# Usage: label_vm_via_hub <cluster> <namespace> <vm-name> <label-key> <label-value>
# To remove a label, pass "" as label-value.
label_vm_via_hub() {
  local cluster="$1" ns="$2" vm="$3" lkey="$4" lval="$5"
  local mw_name="backup-label-$(echo "${vm}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | head -c 40)-$(date +%s)"

  local label_yaml
  if [[ -n "$lval" ]]; then
    label_yaml="          ${lkey}: \"${lval}\""
  else
    label_yaml="          ${lkey}: null"
  fi

  cat <<MW_EOF | run_oc apply -f - 2>/dev/null || return 1
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${mw_name}
  namespace: ${cluster}
spec:
  workload:
    manifests:
    - apiVersion: kubevirt.io/v1
      kind: VirtualMachine
      metadata:
        name: ${vm}
        namespace: ${ns}
        labels:
${label_yaml}
  manifestConfigs:
  - resourceIdentifier:
      group: kubevirt.io
      resource: virtualmachines
      namespace: ${ns}
      name: ${vm}
    updateStrategy:
      type: ServerSideApply
MW_EOF

  # Wait for ManifestWork to be applied
  local applied=false
  for _w in 1 2 3 4 5; do
    sleep 2
    local status
    status=$(run_oc get manifestwork "$mw_name" -n "$cluster" -o jsonpath='{.status.conditions[?(@.type=="Applied")].status}' 2>/dev/null || echo "")
    if [[ "$status" == "True" ]]; then
      applied=true
      break
    fi
  done

  # Cleanup the ManifestWork (set deleteOption to Orphan so the label stays)
  run_oc patch manifestwork "$mw_name" -n "$cluster" --type merge \
    -p '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}' 2>/dev/null || true
  run_oc delete manifestwork "$mw_name" -n "$cluster" 2>/dev/null || true

  if [[ "$applied" == true ]]; then
    return 0
  else
    return 1
  fi
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

if [[ -n "$CTX" ]]; then
  printf "Context: ${BOLD}%s${RESET}\n" "$CTX"
else
  CURRENT_CTX=$(oc config current-context 2>/dev/null || echo "unknown")
  printf "Context: ${BOLD}%s${RESET} (current login)\n" "$CURRENT_CTX"
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

POLICY_COUNT=0
for pname in acm-dr-virt-install acm-dr-virt-backup acm-dr-virt-restore; do
  if run_oc get policy.policy.open-cluster-management.io "$pname" -n "$NS" &>/dev/null; then
    POLICY_COUNT=$((POLICY_COUNT + 1))
  fi
done
if [[ "$POLICY_COUNT" -eq 3 ]]; then
  info "All 3 virt DR policies found on hub"
else
  warn "Only $POLICY_COUNT/3 virt DR policies found in $NS"
  printf "  The virt DR policies are auto-created when cluster-backup is enabled on MCH.\n"
  printf "  Check: oc get multiclusterhub -A -o jsonpath='{range .items[*]}{.metadata.name}: cluster-backup={.spec.overrides.components[?(%%40.name==\"cluster-backup\")].enabled}{\"\\\\n\"}{end}'\n"
fi

# ============================================================
# 1. Discover VMs
# ============================================================
header "1. Discover VirtualMachines"

# Try ACM search API on hub to discover VMs across all clusters
VM_TABLE=""
SEARCH_USED=false
SEARCH_RESULT=""
declare -A MC_CONTEXT_MAP=()  # managed-cluster -> kubeconfig context

if [[ "$IS_HUB" == true ]]; then
  printf "Looking for ACM search API...\n"

  # Find the MCH namespace and search service
  MCH_NS=$(run_oc get multiclusterhub --all-namespaces --no-headers 2>/dev/null | awk '{print $1; exit}' || echo "")
  SEARCH_SVC=""
  SEARCH_RESULT=""

  if [[ -n "$MCH_NS" ]]; then
    for SVC_NAME in search-search-api search-api; do
      if run_oc get service "$SVC_NAME" -n "$MCH_NS" &>/dev/null; then
        SEARCH_SVC="$SVC_NAME"
        break
      fi
    done
  fi

  if [[ -n "$SEARCH_SVC" ]]; then
    printf "  Search service: ${BOLD}%s/%s${RESET}\n" "$MCH_NS" "$SEARCH_SVC"

    SEARCH_QUERY='{"query":"query { search(input: [{filters: [{property: \"kind\", values: [\"VirtualMachine\"]}, {property: \"apigroup\", values: [\"kubevirt.io\"]}]}]) { items } }"}'

    # Port-forward to the search service (handles auth via oc)
    LOCAL_PORT=$((RANDOM % 10000 + 40000))
    PF_PID=""
    PF_LOG=$(mktemp /tmp/oc-pf-XXXXXX)
    oc "${OC_CTX[@]}" port-forward "svc/${SEARCH_SVC}" "${LOCAL_PORT}:4010" -n "$MCH_NS" >"$PF_LOG" 2>&1 &
    PF_PID=$!
    sleep 3

    if kill -0 "$PF_PID" 2>/dev/null; then
      # Get a bearer token with cluster-wide read access for the search API
      TOKEN=""
      # First try oc whoami -t (works for token-based logins)
      TOKEN=$(run_oc whoami -t 2>/dev/null) || true
      if [[ -n "$TOKEN" ]] && ! [[ "$TOKEN" =~ ^ey|^sha256~ ]]; then
        TOKEN=""
      fi
      # Find an SA with cluster-admin binding
      if [[ -z "$TOKEN" ]]; then
        ADMIN_SA=$(run_oc get clusterrolebindings -o json 2>/dev/null | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for b in items:
    role = b.get('roleRef', {}).get('name', '')
    if role != 'cluster-admin':
        continue
    for s in b.get('subjects', []):
        if s.get('kind') == 'ServiceAccount':
            print(f'{s.get(\"namespace\",\"?\")}/{s[\"name\"]}')
" 2>/dev/null | head -1) || true
        if [[ -n "$ADMIN_SA" ]]; then
          SA_NS="${ADMIN_SA%%/*}"
          SA_NAME="${ADMIN_SA##*/}"
          TOKEN=$(run_oc create token "$SA_NAME" -n "$SA_NS" --duration=10m 2>/dev/null) || true
        fi
      fi
      # Last resort: try well-known SAs
      if [[ -z "$TOKEN" ]]; then
        for SA_NS_NAME in "$MCH_NS/multiclusterhub-operator" "kube-system/default" "$MCH_NS/default"; do
          SA_NS="${SA_NS_NAME%%/*}"
          SA_NAME="${SA_NS_NAME##*/}"
          TOKEN=$(run_oc create token "$SA_NAME" -n "$SA_NS" --duration=10m 2>/dev/null) || true
          if [[ -n "$TOKEN" ]]; then break; fi
        done
      fi

      for SEARCH_PATH in "/searchapi/graphql" "/graphql"; do
        SEARCH_RESULT=$(curl -sk --max-time 10 \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d "$SEARCH_QUERY" \
          "https://127.0.0.1:${LOCAL_PORT}${SEARCH_PATH}" 2>/dev/null) || true

        if echo "$SEARCH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'data' in d" 2>/dev/null; then
          ITEM_COUNT=$(echo "$SEARCH_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = []
for sr in d.get('data', {}).get('search', []):
    items.extend(sr.get('items', []))
print(len(items))
" 2>/dev/null) || true
          printf "  ${GREEN}Search OK${RESET} via port-forward -> %s (%s items)\n" "$SEARCH_PATH" "${ITEM_COUNT:-0}"
          if [[ "${ITEM_COUNT:-0}" == "0" ]]; then
            printf "  ${DIM}Raw response: %.300s${RESET}\n" "$SEARCH_RESULT"
            # Try a broader query to check if search index has anything
            BROAD_RESULT=$(curl -sk --max-time 10 \
              -H "Authorization: Bearer $TOKEN" \
              -H "Content-Type: application/json" \
              -d '{"query":"query { search(input: [{filters: [{property: \"kind\", values: [\"VirtualMachine\"]}]}]) { count items } }"}' \
              "https://127.0.0.1:${LOCAL_PORT}${SEARCH_PATH}" 2>/dev/null) || true
            printf "  ${DIM}Broad query (no apigroup filter): %.300s${RESET}\n" "$BROAD_RESULT"
          fi
          break
        fi
        SEARCH_RESULT=""
      done
    else
      warn "Port-forward failed to start"
      printf "  Log: %s\n" "$(cat "$PF_LOG" 2>/dev/null || echo '(empty)')"
    fi
    rm -f "$PF_LOG" || true
    if [[ -n "$PF_PID" ]]; then
      kill "$PF_PID" 2>/dev/null || true
      wait "$PF_PID" 2>/dev/null || true
    fi

    if [[ -n "$SEARCH_RESULT" ]]; then
        VM_TABLE=$(echo "$SEARCH_RESULT" | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = []
for sr in data.get('data', {}).get('search', []):
    items.extend(sr.get('items', []))
if not items:
    sys.exit(0)

for i, vm in enumerate(items):
    cluster = vm.get('cluster', 'unknown')
    ns = vm.get('namespace', '?')
    name = vm.get('name', '?')
    uid = vm.get('_uid', '?').split('/')[-1] if '/' in vm.get('_uid', '') else vm.get('_uid', '?')
    status = vm.get('status', vm.get('printableStatus', 'Unknown'))
    label_str = vm.get('label', '')
    labels = {}
    if label_str:
        for pair in label_str.split('; '):
            if '=' in pair:
                k, v = pair.split('=', 1)
                labels[k] = v
    cron = labels.get('cluster.open-cluster-management.io/backup-vm', '')
    backup = cron if cron else '-'
    os_type = '-'
    for k in labels:
        if k.startswith('os.template.kubevirt.io/'):
            os_type = k.split('/')[-1]
            break
    if os_type == '-':
        os_type = labels.get('kubevirt.io/os', labels.get('vm.kubevirt.io/os', '-'))
    if os_type == '-':
        name_lower = name.lower()
        for osn in ('fedora', 'centos', 'rhel', 'windows', 'ubuntu', 'debian', 'sles', 'cirros'):
            if osn in name_lower:
                os_type = osn
                break
    print(f'{i+1}|{cluster}|{ns}|{name}|{status}|{backup}|{os_type}|{uid}')
" 2>/dev/null || echo "")

        if [[ -n "$VM_TABLE" ]]; then
          SEARCH_USED=true
          SEARCH_VM_COUNT=$(echo "$VM_TABLE" | wc -l | tr -d ' ')
          info "Found $SEARCH_VM_COUNT VM(s) via ACM search across all clusters"

          ALL_CONTEXTS=$(oc config get-contexts -o name 2>/dev/null || echo "")
          LOCAL_MC=$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "local-cluster")
          REMOTE_CLUSTERS=$(echo "$VM_TABLE" | awk -F'|' '{print $2}' | sort -u)
          for RC in $REMOTE_CLUSTERS; do
            [[ "$RC" == "$LOCAL_MC" ]] && continue
            for ctx in $ALL_CONTEXTS; do
              if [[ "$ctx" == "$RC" ]]; then MC_CONTEXT_MAP["$RC"]="$ctx"; break; fi
            done
            if [[ -z "${MC_CONTEXT_MAP[$RC]:-}" ]]; then
              for ctx in $ALL_CONTEXTS; do
                if echo "$ctx" | grep -qi "$RC"; then MC_CONTEXT_MAP["$RC"]="$ctx"; break; fi
              done
            fi
          done
        else
          warn "Search API returned no VMs"
        fi
      else
        warn "Search API query failed"
      fi
  else
    warn "No search service found in MCH namespace '${MCH_NS:-?}'"
  fi
fi

if [[ -z "$VM_TABLE" ]]; then
  warn "No VirtualMachines found. Search API must be working to discover VMs."
  exit 0
fi

VM_COUNT=$(echo "$VM_TABLE" | wc -l | tr -d ' ')
printf "Found ${BOLD}%d${RESET} VirtualMachine(s):\n\n" "$VM_COUNT"

CLUSTERS_LIST=$(echo "$VM_TABLE" | while IFS='|' read -r _ cl _ _ _ _ _ _; do echo "$cl"; done | sort -u)

# Sort VM_TABLE by cluster then namespace for display
SORTED_VM_TABLE=$(echo "$VM_TABLE" | sort -t'|' -k2,2 -k3,3)

printf "  ${BOLD}%-4s %-18s %-14s %-25s %-8s %-18s${RESET}\n" "#" "CLUSTER" "BACKUP" "NAMESPACE/NAME" "OS" "STATUS"
echo "$SORTED_VM_TABLE" | while IFS='|' read -r idx cl ns name status backup os uid; do
  if [[ "$backup" != "-" ]]; then
    backup_display="${GREEN}${backup}${RESET}"
  else
    backup_display="${DIM}-${RESET}"
  fi
  os_display="${os}"
  [[ "$os" == "-" ]] && os_display="${DIM}-${RESET}"
  printf "  %-4s ${CYAN}%-18s${RESET} " "$idx" "$cl"
  printf "$backup_display"
  printf "%*s" $((14 - ${#backup})) ""
  printf "%-25s " "${ns}/${name}"
  printf "$os_display"
  printf "%*s" $((8 - ${#os})) ""
  printf "${DIM}%s${RESET}\n" "$status"
done
printf "\n"

if [[ "$LIST_ONLY" == true ]]; then
  printf "Legend: BACKUP = cron schedule name ('-' = not backed up), OS = detected OS type\n"
  exit 0
fi

# --- Selection helper: resolve filter expression to matching line numbers ---
# Supports: numbers (1,2,3), all, cluster=<name>, ns=<namespace>, os=<type>, label=<key>=<value>
resolve_selection() {
  local sel_input="$1"
  local table="$2"
  local count="$3"
  local result=()

  for token in $sel_input; do
    token=$(echo "$token" | tr -d ' ')
    if [[ "$token" == "all" ]]; then
      for i in $(seq 1 "$count"); do result+=("$i"); done
    elif [[ "$token" =~ ^[0-9,]+$ ]]; then
      IFS=',' read -ra nums <<< "$token"
      for n in "${nums[@]}"; do
        if [[ "$n" -ge 1 && "$n" -le "$count" ]]; then
          result+=("$n")
        else
          printf "${YELLOW}[WARN]${RESET} Invalid number: %s (valid range: 1-%s)\n" "$n" "$count" >&2
        fi
      done
    elif [[ "$token" == cluster=* ]]; then
      local cval="${token#cluster=}"
      while IFS='|' read -r lidx lcl _ _ _ _ _ _; do
        [[ "$lcl" == "$cval" ]] && result+=("$lidx")
      done <<< "$table"
    elif [[ "$token" == ns=* ]]; then
      local nsval="${token#ns=}"
      while IFS='|' read -r lidx _ lns _ _ _ _ _; do
        [[ "$lns" == "$nsval" ]] && result+=("$lidx")
      done <<< "$table"
    elif [[ "$token" == os=* ]]; then
      local osval="${token#os=}"
      while IFS='|' read -r lidx _ _ _ _ _ los _; do
        [[ "$los" == "$osval" ]] && result+=("$lidx")
      done <<< "$table"
    elif [[ "$token" == label=* ]]; then
      local lval="${token#label=}"
      local lkey="${lval%%=*}"
      local lkval="${lval#*=}"
      while IFS='|' read -r lidx lcl lns lname _ _ _ _; do
        local vm_labels
        if [[ "$SEARCH_USED" == true ]]; then
          vm_labels=$(echo "$SEARCH_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = []
for sr in data.get('data', {}).get('search', []):
    items.extend(sr.get('items', []))
for vm in items:
    if vm.get('cluster','') == '${lcl}' and vm.get('namespace','') == '${lns}' and vm.get('name','') == '${lname}':
        print(vm.get('label', ''))
        break
" 2>/dev/null || echo "")
          if echo "$vm_labels" | grep -q "${lkey}=${lkval}"; then
            result+=("$lidx")
          fi
        else
          vm_labels=$(run_oc get virtualmachine.kubevirt.io "$lname" -n "$lns" -o jsonpath="{.metadata.labels.${lkey}}" 2>/dev/null || echo "")
          if [[ "$vm_labels" == "$lkval" ]]; then
            result+=("$lidx")
          fi
        fi
      done <<< "$table"
    else
      printf "${YELLOW}[WARN]${RESET} Unknown filter: %s\n" "$token" >&2
    fi
  done

  printf '%s\n' "${result[@]}" | sort -un
}

# ============================================================
# 2. Remove VMs from backup
# ============================================================

BACKED_UP_TABLE=""
BACKED_UP_IDX=1
while IFS='|' read -r idx cl ns name status backup os uid; do
  [[ "$backup" != "-" ]] && {
    if [[ -z "$BACKED_UP_TABLE" ]]; then
      BACKED_UP_TABLE="${BACKED_UP_IDX}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
    else
      BACKED_UP_TABLE="${BACKED_UP_TABLE}"$'\n'"${BACKED_UP_IDX}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
    fi
    BACKED_UP_IDX=$((BACKED_UP_IDX + 1))
  }
done <<< "$VM_TABLE"

declare -a REMOVED_KEYS=()

if [[ -n "$BACKED_UP_TABLE" ]]; then
  BACKED_UP_COUNT=$(echo "$BACKED_UP_TABLE" | wc -l | tr -d ' ')
  header "2. VMs currently backed up"

  printf "These VMs already have a backup schedule:\n\n"
  SORTED_BACKED=$(echo "$BACKED_UP_TABLE" | sort -t'|' -k2,2 -k3,3)
  printf "  ${BOLD}%-4s %-18s %-14s %-25s %-8s %-18s${RESET}\n" "#" "CLUSTER" "SCHEDULE" "NAMESPACE/NAME" "OS" "STATUS"
  echo "$SORTED_BACKED" | while IFS='|' read -r bidx bcl bns bname bstatus bbackup bos buid; do
    printf "  %-4s ${CYAN}%-18s${RESET} ${GREEN}%-14s${RESET} %-25s %-8s ${DIM}%s${RESET}\n" "$bidx" "$bcl" "$bbackup" "${bns}/${bname}" "$bos" "$bstatus"
  done
  printf "\n"

  printf "Select VMs to ${RED}remove from backup${RESET}:\n"
  printf "  Numbers (e.g. 1,2,3), or filters: cluster=<name> ns=<ns> os=<type> label=<k>=<v>\n"
  printf "  Press Enter to skip.\n"

  REMOVE_RESOLVED=""
  while true; do
    printf "${BOLD}Remove:${RESET} "
    read -r REMOVE_SELECTION </dev/tty
    [[ -z "$REMOVE_SELECTION" ]] && break
    REMOVE_RESOLVED=$(resolve_selection "$REMOVE_SELECTION" "$BACKED_UP_TABLE" "$BACKED_UP_COUNT")
    if [[ -n "$REMOVE_RESOLVED" ]]; then
      break
    fi
    printf "  ${YELLOW}No matching VMs. Try again or press Enter to skip.${RESET}\n"
  done

  if [[ -n "$REMOVE_RESOLVED" ]]; then
    REMOVE_COUNT=0

    for ridx in $REMOVE_RESOLVED; do
      RLINE=$(echo "$BACKED_UP_TABLE" | awk -F'|' -v idx="$ridx" '$1==idx')
      if [[ -z "$RLINE" ]]; then
        warn "Invalid index: $ridx (skipping)"
        continue
      fi
      IFS='|' read -r _ rcl rns rname _ rbackup _ _ <<< "$RLINE"

      printf "  Removing backup label from %s/%s (%s)..." "$rns" "$rname" "$rcl"
      REMOVE_OK=false
      if [[ -n "${MC_CONTEXT_MAP[$rcl]:-}" || "$rcl" == "${LOCAL_MC:-local-cluster}" ]]; then
        if run_oc_on_cluster "$rcl" label virtualmachine.kubevirt.io "$rname" -n "$rns" \
          "${BACKUP_LABEL}-" 2>/dev/null; then
          REMOVE_OK=true
        fi
      else
        if label_vm_via_hub "$rcl" "$rns" "$rname" "$BACKUP_LABEL" ""; then
          REMOVE_OK=true
        fi
      fi

      if [[ "$REMOVE_OK" == true ]]; then
        printf " ${GREEN}OK${RESET}\n"
        REMOVE_COUNT=$((REMOVE_COUNT + 1))
        REMOVED_KEYS+=("${rcl}|${rns}/${rname}")
      else
        printf " ${RED}FAILED${RESET}\n"
        printf "    ${YELLOW}Remove manually on cluster '%s':${RESET}\n" "$rcl"
        printf "    oc label virtualmachine.kubevirt.io %s -n %s %s-\n" "$rname" "$rns" "$BACKUP_LABEL"
      fi
    done

    if [[ "$REMOVE_COUNT" -gt 0 ]]; then
      info "Removed backup label from $REMOVE_COUNT VM(s)"
    fi
  else
    printf "  No VMs removed from backup.\n"
  fi
else
  printf "\nNo VMs are currently backed up.\n"
fi

# ============================================================
# 3. Select VMs to back up
# ============================================================
header "3. Select VMs to back up"

AVAIL_TABLE=""
AVAIL_IDX=1
while IFS='|' read -r idx cl ns name status backup os uid; do
  key="${cl}|${ns}/${name}"
  SKIP=false
  for rk in "${REMOVED_KEYS[@]+"${REMOVED_KEYS[@]}"}"; do
    if [[ "$rk" == "$key" ]]; then
      SKIP=true
      break
    fi
  done
  if [[ "$SKIP" == true ]]; then
    continue
  fi
  if [[ -z "$AVAIL_TABLE" ]]; then
    AVAIL_TABLE="${AVAIL_IDX}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
  else
    AVAIL_TABLE="${AVAIL_TABLE}"$'\n'"${AVAIL_IDX}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
  fi
  AVAIL_IDX=$((AVAIL_IDX + 1))
done <<< "$VM_TABLE"

if [[ -z "$AVAIL_TABLE" ]]; then
  if [[ ${#REMOVED_KEYS[@]} -gt 0 ]]; then
    printf "\nNo more VMs to work on. Only removal was performed.\n"
  else
    warn "No VMs to work on."
  fi
  SKIP_TO_STATUS=true
fi

if [[ "${SKIP_TO_STATUS:-false}" != true ]]; then

AVAIL_COUNT=$(echo "$AVAIL_TABLE" | wc -l | tr -d ' ')
AVAIL_CLUSTERS=$(echo "$AVAIL_TABLE" | while IFS='|' read -r _ acl _ _ _ _ _ _; do echo "$acl"; done | sort -u)

printf "Available VMs (excluding removed):\n\n"
SORTED_AVAIL=$(echo "$AVAIL_TABLE" | sort -t'|' -k2,2 -k3,3)
printf "  ${BOLD}%-4s %-18s %-14s %-25s %-8s %-18s${RESET}\n" "#" "CLUSTER" "BACKUP" "NAMESPACE/NAME" "OS" "STATUS"
echo "$SORTED_AVAIL" | while IFS='|' read -r aidx acl ans aname astatus abackup aos auid; do
  if [[ "$abackup" != "-" ]]; then
    backup_display="${GREEN}${abackup}${RESET}"
  else
    backup_display="${DIM}-${RESET}"
  fi
  os_display="${aos}"
  [[ "$aos" == "-" ]] && os_display="${DIM}-${RESET}"
  printf "  %-4s ${CYAN}%-18s${RESET} " "$aidx" "$acl"
  printf "$backup_display"
  printf "%*s" $((14 - ${#abackup})) ""
  printf "%-25s " "${ans}/${aname}"
  printf "$os_display"
  printf "%*s" $((8 - ${#aos})) ""
  printf "${DIM}%s${RESET}\n" "$astatus"
done
printf "\n"

printf "Select VMs to back up:\n"
printf "  Numbers (e.g. 1,2,3), 'all', or filters: cluster=<name> ns=<ns> os=<type> label=<k>=<v>\n"
printf "  Combine filters with spaces (e.g. 'ns=default os=fedora'). Press Enter to skip.\n"

SELECTION=""
SEL_RESOLVED=""
while true; do
  printf "${BOLD}Selection:${RESET} "
  read -r SELECTION </dev/tty
  [[ -z "$SELECTION" ]] && break
  SEL_RESOLVED=$(resolve_selection "$SELECTION" "$AVAIL_TABLE" "$AVAIL_COUNT")
  if [[ -n "$SEL_RESOLVED" ]]; then
    break
  fi
  printf "  ${YELLOW}No matching VMs. Try again or press Enter to skip.${RESET}\n"
done

if [[ -z "$SELECTION" ]]; then
  if [[ ${#REMOVED_KEYS[@]} -gt 0 ]]; then
    printf "\nNo VMs selected for backup. Only removal was performed.\n"
  else
    warn "No VMs selected."
  fi
  SKIP_TO_STATUS=true
fi

if [[ "${SKIP_TO_STATUS:-false}" != true ]]; then

declare -a SEL_NS=()
declare -a SEL_NAME=()
declare -a SEL_CURRENT=()
declare -a SEL_UID=()
declare -a SEL_CLUSTER=()

for idx in $SEL_RESOLVED; do
  LINE=$(echo "$AVAIL_TABLE" | sed -n "${idx}p")
  if [[ -z "$LINE" ]]; then
    warn "Invalid index: $idx (skipping)"
    continue
  fi
  IFS='|' read -r _ cl ns name _ backup _ uid <<< "$LINE"
  SEL_CLUSTER+=("$cl")
  SEL_NS+=("$ns")
  SEL_NAME+=("$name")
  SEL_CURRENT+=("$backup")
  SEL_UID+=("$uid")
done

if [[ ${#SEL_NAME[@]} -eq 0 ]]; then
  warn "No VMs matched the selection. Exiting."
  exit 0
fi

printf "\nSelected %d VM(s) for backup:\n" "${#SEL_NAME[@]}"
for i in "${!SEL_NAME[@]}"; do
  printf "  - ${BOLD}%s/%s${RESET} (%s)" "${SEL_NS[$i]}" "${SEL_NAME[$i]}" "${SEL_CLUSTER[$i]}"
  if [[ "${SEL_CURRENT[$i]}" != "-" ]]; then
    printf "  (currently: ${GREEN}%s${RESET}, will update)" "${SEL_CURRENT[$i]}"
  fi
  printf "\n"
done

# ============================================================
# 4. Verify policy infrastructure
# ============================================================
header "4. Verify backup prerequisites"

POLICIES_OK=true
NEEDS_MC_LABEL=false

step "4a: Check ManagedCluster backup configuration"

# Target clusters: only the ones that own selected VMs
SEL_ONLY_CLUSTERS=$(printf '%s\n' "${SEL_CLUSTER[@]}" | sort -u)
TARGET_CLUSTERS="$SEL_ONLY_CLUSTERS"
declare -A MC_LABEL_STATUS=()
NEEDS_MC_LABEL=false
VIRT_CONFIG_LABEL=""

for TC in $TARGET_CLUSTERS; do
  MC_NAME="$TC"
  TC_LABEL=$(run_oc get managedcluster "$MC_NAME" -o jsonpath='{.metadata.labels.acm-virt-config}' 2>/dev/null || echo "")

  if [[ -n "$TC_LABEL" ]]; then
    info "ManagedCluster '$MC_NAME' uses backup config '$TC_LABEL'"
    MC_LABEL_STATUS["$MC_NAME"]="$TC_LABEL"
    [[ -z "$VIRT_CONFIG_LABEL" ]] && VIRT_CONFIG_LABEL="$TC_LABEL"
  else
    warn "ManagedCluster '$MC_NAME' has no backup configuration assigned (missing acm-virt-config label)."
    printf "The acm-virt-config label is used to point to the file used to configure the OADP backup for this cluster.\n"
    MC_LABEL_STATUS["$MC_NAME"]=""
    NEEDS_MC_LABEL=true
    POLICIES_OK=false
  fi
done

step "4b: Assign backup configuration to clusters"

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

# Discover all virt ConfigMaps and which clusters use them (needed for labeling)
EXISTING_CMS=""
declare -A CM_USERS=()
if [[ "$NEEDS_MC_LABEL" == true ]]; then
  EXISTING_CMS_RAW=$(run_oc get configmaps -n "$NS" -o json 2>/dev/null || echo '{"items":[]}')
  EXISTING_CMS=$(echo "$EXISTING_CMS_RAW" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
virt_cms = []
for cm in items:
    data = cm.get('data', {})
    if 'backupNS' in data and 'dpa_spec' in data and not name.endswith('--cls'):
        virt_cms.append(name)
for n in sorted(virt_cms):
    print(n)
" 2>/dev/null || echo "")

  ALL_MC_LABELS=$(run_oc get managedclusters -o json 2>/dev/null || echo '{"items":[]}')
  while IFS='|' read -r mc_name mc_cm; do
    [[ -z "$mc_name" || -z "$mc_cm" ]] && continue
    CM_USERS["$mc_cm"]="${CM_USERS[$mc_cm]:-}${CM_USERS[$mc_cm]:+, }$mc_name"
  done < <(echo "$ALL_MC_LABELS" | python3 -c "
import sys, json
for mc in json.load(sys.stdin).get('items', []):
    labels = mc.get('metadata', {}).get('labels', {})
    cm = labels.get('acm-virt-config', '')
    if cm:
        print(f\"{mc['metadata']['name']}|{cm}\")
" 2>/dev/null)
fi

# Helper: let user pick a ConfigMap (from list or create new), returns name via CHOSEN_CM
pick_configmap() {
  local chosen=""

  if [[ -n "$EXISTING_CMS" ]]; then
    local cm_count
    cm_count=$(echo "$EXISTING_CMS" | wc -l | tr -d ' ')
    printf "\n${BOLD}Available virt configuration ConfigMaps in %s:${RESET}\n\n" "$NS"
    local cidx=1
    while IFS= read -r cm_name; do
      local users="${CM_USERS[$cm_name]:-none}"
      printf "  ${CYAN}%d)${RESET} %-30s ${DIM}used by: %s${RESET}\n" "$cidx" "$cm_name" "$users"
      cidx=$((cidx + 1))
    done <<< "$EXISTING_CMS"
    printf "  ${CYAN}%d)${RESET} %-30s ${DIM}(create a new ConfigMap)${RESET}\n" "$cidx" "[new]"
    printf "\n"

    local cm_choice
    while true; do
      printf "${BOLD}Select ConfigMap (1-%d):${RESET} " "$cidx"
      read -r cm_choice </dev/tty
      if [[ "$cm_choice" =~ ^[0-9]+$ && "$cm_choice" -ge 1 && "$cm_choice" -le "$cidx" ]]; then
        break
      fi
      printf "  ${YELLOW}Invalid choice. Enter a number from 1 to %d.${RESET}\n" "$cidx"
    done

    if [[ "$cm_choice" -lt "$cidx" ]]; then
      chosen=$(echo "$EXISTING_CMS" | sed -n "${cm_choice}p")
      info "Selected ConfigMap '$chosen'"
      local users="${CM_USERS[$chosen]:-}"
      if [[ -n "$users" ]]; then
        printf "  ${DIM}Also used by: %s${RESET}\n" "$users"
      fi
      CHOSEN_CM="$chosen"
      return 0
    fi
  fi

  # Create new ConfigMap by copying from existing acm-dr-virt-config
  printf "\n${BOLD}Create a new virt configuration ConfigMap${RESET}\n"
  printf "Use this when a managed cluster needs different DPA/BSL settings\n"
  printf "(e.g. different cloud provider, bucket, or credentials).\n"
  printf "The new ConfigMap will be pre-populated from the existing 'acm-dr-virt-config'.\n\n"

  if ! confirm "Create a new configuration ConfigMap?"; then
    CHOSEN_CM=""
    return 1
  fi

  printf "Enter a name for the new ConfigMap: "
  read -r NEW_CM_NAME </dev/tty
  if [[ -z "$NEW_CM_NAME" ]]; then
    warn "No name entered."
    CHOSEN_CM=""
    return 1
  fi

  if run_oc get configmap "$NEW_CM_NAME" -n "$NS" &>/dev/null; then
    info "ConfigMap '$NEW_CM_NAME' already exists"
    CHOSEN_CM="$NEW_CM_NAME"
    return 0
  fi

  # Discover all virt-like ConfigMaps to copy from (broader filter: any CM with backupNS key)
  local copy_cms=""
  copy_cms=$(run_oc get configmaps -n "$NS" -o json 2>/dev/null | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for cm in items:
    name = cm['metadata']['name']
    data = cm.get('data', {})
    if 'backupNS' in data and not name.endswith('--cls'):
        print(name)
" 2>/dev/null || echo "")

  local source_cm=""
  if [[ -n "$copy_cms" ]]; then
    local src_count
    src_count=$(echo "$copy_cms" | wc -l | tr -d ' ')
    printf "\nCopy settings from an existing ConfigMap:\n\n"
    local sidx=1
    while IFS= read -r scm; do
      local susers="${CM_USERS[$scm]:-none}"
      printf "  ${CYAN}%d)${RESET} %-30s ${DIM}used by: %s${RESET}\n" "$sidx" "$scm" "$susers"
      sidx=$((sidx + 1))
    done <<< "$copy_cms"
    printf "\n"

    while true; do
      printf "${BOLD}Copy from (1-%d):${RESET} " "$src_count"
      read -r src_choice </dev/tty
      if [[ "$src_choice" =~ ^[0-9]+$ && "$src_choice" -ge 1 && "$src_choice" -le "$src_count" ]]; then
        break
      fi
      printf "  ${YELLOW}Invalid choice. Enter a number from 1 to %d.${RESET}\n" "$src_count"
    done
    source_cm=$(echo "$copy_cms" | sed -n "${src_choice}p")
  else
    source_cm="acm-dr-virt-config"
  fi

  local source_json=""
  source_json=$(run_oc get configmap "$source_cm" -n "$NS" -o json 2>/dev/null || echo "")

  if [[ -n "$source_json" ]]; then
    printf "Copying from '%s'...\n" "$source_cm"
    local new_cm_json
    new_cm_json=$(echo "$source_json" | python3 -c "
import sys, json
cm = json.load(sys.stdin)
cm['metadata'] = {'name': '$NEW_CM_NAME', 'namespace': '$NS'}
if 'resourceVersion' in cm.get('metadata', {}):
    del cm['metadata']['resourceVersion']
json.dump(cm, sys.stdout)
" 2>/dev/null)

    if [[ -n "$new_cm_json" ]]; then
      echo "$new_cm_json" | run_oc create -f - 2>/dev/null && \
        info "Created ConfigMap '$NEW_CM_NAME' (copied from '$source_cm')" || \
        { warn "Failed to create ConfigMap."; CHOSEN_CM=""; return 1; }
    else
      warn "Failed to prepare ConfigMap data."
      CHOSEN_CM=""
      return 1
    fi

    printf "\n${YELLOW}[IMPORTANT]${RESET} Update the DPA and credential settings for the target cluster:\n"
    printf "  oc edit configmap %s -n %s\n\n" "$NEW_CM_NAME" "$NS"
    printf "Key fields to update:\n"
    printf "  - dpa_spec:  DPA spec JSON (backup location, provider, bucket, credentials)\n"
    printf "  - credentials_name:  name of the cloud credentials secret on the target cluster\n"
    if confirm "Open the new ConfigMap for editing now?"; then
      run_oc edit configmap "$NEW_CM_NAME" -n "$NS" </dev/tty || true
    fi
  else
    warn "Could not find '%s' to copy from. Creating with empty defaults." "$source_cm"
    local sched_cm="acm-dr-virt-schedule-cron"
    local restore_cm="acm-dr-virt-restore-config"
    local cred_secret="cloud-credentials"

    run_oc create configmap "$NEW_CM_NAME" -n "$NS" \
      --from-literal=backupNS="open-cluster-management-backup" \
      --from-literal=channel="" \
      --from-literal=dpa_name="" \
      --from-literal=dpa_spec="" \
      --from-literal=credentials_hub_secret_name="$cred_secret" \
      --from-literal=credentials_name="$cred_secret" \
      --from-literal=schedule_hub_config_name="$sched_cm" \
      --from-literal=restore_hub_config_name="$restore_cm" \
      --from-literal=scheduleTTL="120h" \
      2>/dev/null && info "Created ConfigMap '$NEW_CM_NAME'" || \
      { warn "Failed to create ConfigMap."; CHOSEN_CM=""; return 1; }

    printf "\n${YELLOW}[IMPORTANT]${RESET} You must configure these in '%s':\n" "$NEW_CM_NAME"
    printf "  - dpa_name:  name of the DataProtectionApplication\n"
    printf "  - dpa_spec:  DPA spec JSON (backup locations, plugins, credentials)\n"
    printf "  - channel:   OADP channel (e.g. stable-1.4)\n"
    printf "  - credentials secret: create '%s' in the target namespace\n\n" "$cred_secret"
    printf "Edit with: oc edit configmap %s -n %s\n" "$NEW_CM_NAME" "$NS"
  fi

  CHOSEN_CM="$NEW_CM_NAME"
  return 0
}

if [[ "$NEEDS_MC_LABEL" == true ]]; then
  UNLABELED_CLUSTERS=()
  for TC in $TARGET_CLUSTERS; do
    [[ -z "${MC_LABEL_STATUS[$TC]:-}" ]] && UNLABELED_CLUSTERS+=("$TC")
  done

  if [[ ${#UNLABELED_CLUSTERS[@]} -gt 0 ]]; then
    printf "\n${BOLD}Clusters needing acm-virt-config label:${RESET} %s\n" "${UNLABELED_CLUSTERS[*]}"
    printf "Each cluster must point to a virt configuration ConfigMap.\n"

    CHOSEN_CM=""
    pick_configmap
    CM_FOR_LABELING="${CHOSEN_CM:-acm-dr-virt-config}"

    for TC in "${UNLABELED_CLUSTERS[@]}"; do
      if confirm "Label ManagedCluster '$TC' with acm-virt-config=$CM_FOR_LABELING?"; then
        run_oc label managedcluster "$TC" "acm-virt-config=$CM_FOR_LABELING" --overwrite 2>/dev/null && \
          info "Labeled '$TC' with acm-virt-config=$CM_FOR_LABELING" || \
          warn "Failed to label. Run: oc label managedcluster $TC acm-virt-config=$CM_FOR_LABELING"
      else
        printf "Skipping. Label manually:\n  oc label managedcluster %s acm-virt-config=%s\n" "$TC" "$CM_FOR_LABELING"
      fi
    done

    [[ -z "$VIRT_CONFIG_LABEL" ]] && VIRT_CONFIG_LABEL="$CM_FOR_LABELING"
    CONFIG_EXISTS=true
  fi
fi

step "4c: Check OADP and DPA"

OADP_NS="${OADP_NS:-open-cluster-management-backup}"
DPA_OK=true
LOCAL_MC="${LOCAL_MC:-$(run_oc get managedclusters -l local-cluster=true --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "local-cluster")}"
for TC in $TARGET_CLUSTERS; do
  TC_OADP_NS="$OADP_NS"
  if [[ "$TC" != "$LOCAL_MC" ]]; then
    TC_OADP_NS="${TC_OADP_NS:-open-cluster-management-backup}"
  fi

  DPA_COUNT=$(run_oc_on_cluster "$TC" get dataprotectionapplications.oadp.openshift.io -n "$TC_OADP_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$DPA_COUNT" -gt 0 ]]; then
    info "DataProtectionApplication found on '$TC' in $TC_OADP_NS"
  else
    DPA_OK=false
    warn "No DataProtectionApplication on '$TC' in $TC_OADP_NS"
    TC_IS_ALSO_HUB=false
    if [[ "$TC" == "$LOCAL_MC" && "$IS_HUB" == true ]]; then
      TC_IS_ALSO_HUB=true
    elif [[ "$TC" != "$LOCAL_MC" ]]; then
      run_oc_on_cluster "$TC" get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null && TC_IS_ALSO_HUB=true
    fi
    if [[ "$TC_IS_ALSO_HUB" == true ]]; then
      printf "  '%s' is a hub. OADP is managed by MCH; the DPA must be created by the user.\n" "$TC"
    else
      printf "  The acm-dr-virt-install policy will create DPA once policies are placed and config is set.\n"
    fi
  fi

  BSL_OUTPUT=$(run_oc_on_cluster "$TC" get backupstoragelocations.velero.io -n "$TC_OADP_NS" --no-headers 2>/dev/null || echo "")
  BSL_AVAIL=$(echo "$BSL_OUTPUT" | grep -c "Available" || true)
  if [[ "$BSL_AVAIL" -gt 0 ]]; then
    info "$BSL_AVAIL BSL(s) Available on '$TC'"
  else
    warn "No BackupStorageLocation in Available phase on '$TC' in $TC_OADP_NS"
  fi
done

step "4d: Check acm-dr-virt-install policy compliance"

INSTALL_POLICY_OK=true
if run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
  ROOT_POLICY=$(run_oc get policy.policy.open-cluster-management.io acm-dr-virt-install -n "$NS" -o json 2>/dev/null || echo "")
  if [[ -z "$ROOT_POLICY" ]]; then
    warn "acm-dr-virt-install policy not found in $NS"
    INSTALL_POLICY_OK=false
  else
    for TC in $TARGET_CLUSTERS; do
      printf "\n  ${BOLD}Checking install policy on cluster: %s${RESET}\n" "$TC"

      REPL_POLICY=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$TC" -o json 2>/dev/null || echo "")
      if [[ -z "$REPL_POLICY" ]]; then
        warn "No replicated install policy found for cluster '$TC' (namespace $TC)"
        printf "  The policy may not be placed on this cluster yet. Check the ManagedCluster label.\n"
        INSTALL_POLICY_OK=false
        continue
      fi

      TC_COMPLIANCE=$(echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(p.get('status', {}).get('compliant', 'Unknown'))
" 2>/dev/null || echo "Unknown")

      if [[ "$TC_COMPLIANCE" == "Compliant" ]]; then
        info "acm-dr-virt-install is Compliant on '$TC'"
        continue
      fi

      # Policy may still be reconciling; wait and retry
      printf "  ${DIM}Policy is %s, waiting for reconciliation...${RESET}" "$TC_COMPLIANCE"
      for _retry in 1 2 3; do
        sleep 5
        printf "."
        REPL_POLICY=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$TC" -o json 2>/dev/null || echo "")
        TC_COMPLIANCE=$(echo "$REPL_POLICY" | python3 -c "
import sys, json
p = json.load(sys.stdin)
print(p.get('status', {}).get('compliant', 'Unknown'))
" 2>/dev/null || echo "Unknown")
        if [[ "$TC_COMPLIANCE" == "Compliant" ]]; then break; fi
      done
      printf "\n"

      if [[ "$TC_COMPLIANCE" == "Compliant" ]]; then
        info "acm-dr-virt-install is Compliant on '$TC'"
        continue
      fi

      INSTALL_POLICY_OK=false
      err "acm-dr-virt-install is ${TC_COMPLIANCE} on '$TC'"

      printf "\n  ${BOLD}Per-template status (%s):${RESET}\n" "$TC"
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

      IS_LOCAL_TC=false
      [[ "$TC" == "$LOCAL_MC" ]] && IS_LOCAL_TC=true

      # Check if this managed cluster is itself a hub.
      # For local-cluster, use the known IS_HUB flag.
      # For remote clusters, check if the ManagedCluster has the product claim
      # indicating ACM is installed (visible from the hub without direct access).
      TC_IS_HUB=false
      if [[ "$IS_LOCAL_TC" == true ]]; then
        TC_IS_HUB="$IS_HUB"
      else
        MC_PRODUCT=$(run_oc get managedcluster "$TC" -o jsonpath='{.status.clusterClaims[?(@.name=="product.open-cluster-management.io")].value}' 2>/dev/null || echo "")
        if [[ -n "$MC_PRODUCT" ]]; then
          TC_IS_HUB=true
        fi
      fi

      printf "\n  ${BOLD}Suggested fixes (%s):${RESET}\n" "$TC"
      echo "$VIOLATED" | while IFS= read -r tmpl; do
        case "$tmpl" in
          *check-config-file*)
            printf "    - ${YELLOW}%s${RESET}: ConfigMap, cron CM, restore CM, or credentials secret missing on hub.\n" "$tmpl"
            printf "      Check: oc get configmap acm-dr-virt-config -n %s\n" "$NS"
            printf "             oc get secret <credentials> -n %s\n" "$NS"
            ;;
          *check-oadp-channel*)
            printf "    - ${YELLOW}%s${RESET}: OADP subscription channel mismatch or unhealthy catalog source.\n" "$tmpl"
            ;;
          *check-dpa-config*)
            printf "    - ${YELLOW}%s${RESET}: DPA missing kubevirt/csi plugins, nodeAgent not enabled, or BSL not Available.\n" "$tmpl"

            if [[ "$TC_IS_HUB" == true ]]; then
              if [[ "$IS_LOCAL_TC" == true ]]; then
                printf "\n      ${BOLD}On the hub (local-cluster)${RESET}, OADP is managed by MCH. The DPA needs to be patched directly.\n"
              else
                printf "\n      ${BOLD}Managed cluster '%s' is itself a hub${RESET}. The policy does NOT install OADP on hubs.\n" "$TC"
                printf "      OADP must be installed on '%s' via its own MCH cluster-backup component.\n" "$TC"
                printf "      Ensure cluster-backup is enabled on the MCH of '%s', then patch the DPA directly.\n" "$TC"
              fi

              DPA_NAME_FOUND=$(run_oc_on_cluster "$TC" get dataprotectionapplication -n "$OADP_NS" --no-headers 2>/dev/null | awk '{print $1;exit}' || echo "")
              if [[ -n "$DPA_NAME_FOUND" ]]; then
                DPA_JSON=$(run_oc_on_cluster "$TC" get dataprotectionapplication "$DPA_NAME_FOUND" -n "$OADP_NS" -o json 2>/dev/null || echo "")
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
                      run_oc_on_cluster "$TC" patch dataprotectionapplication "$DPA_NAME_FOUND" -n "$OADP_NS" \
                        --type merge -p "$PATCH_JSON" 2>/dev/null && \
                        info "    Patched DPA '$DPA_NAME_FOUND' on '$TC' with kubevirt, csi plugins and nodeAgent" || \
                        warn "    Failed to patch DPA. Patch manually on '$TC': oc edit dataprotectionapplication $DPA_NAME_FOUND -n $OADP_NS"
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
                OADP_CSV_FOUND=$(run_oc_on_cluster "$TC" get csv -n "$OADP_NS" --no-headers 2>/dev/null | grep -c "oadp" || true)
                if [[ "$OADP_CSV_FOUND" -gt 0 ]]; then
                  printf "      OADP operator is installed on '%s' but no DPA has been created.\n" "$TC"
                  printf "      Create a DataProtectionApplication in %s on '%s' with kubevirt, csi plugins and nodeAgent (kopia).\n" "$OADP_NS" "$TC"
                  printf "      The policy will become Compliant once the DPA exists and BSL is Available.\n"
                else
                  printf "      No OADP operator found on '%s' in %s.\n" "$TC" "$OADP_NS"
                  if [[ "$IS_LOCAL_TC" == true ]]; then
                    printf "      Ensure cluster-backup is enabled on MCH.\n"
                  else
                    printf "      '%s' is a hub -- enable cluster-backup on its MCH to install OADP.\n" "$TC"
                    printf "      Check: oc --context %s get multiclusterhub -A -o jsonpath='{.items[0].spec.overrides.components}'\n" "${MC_CONTEXT_MAP[$TC]:-$TC}"
                  fi
                fi
              fi

            else
              printf "\n      ${BOLD}Managed cluster '%s'${RESET}: DPA is created by the policy from the hub ConfigMap.\n" "$TC"
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
                printf "      After saving, the policy will reconcile the DPA on '%s'.\n" "$TC"
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
    done

    if [[ "$INSTALL_POLICY_OK" != true ]]; then
      printf "\n      Waiting for policy to reconcile"
      RECHECK_ATTEMPTS=6
      RECHECK_OK=false
      for attempt in $(seq 1 "$RECHECK_ATTEMPTS"); do
        printf "."
        sleep 10
        ALL_TC_OK=true
        for TC in $TARGET_CLUSTERS; do
          TC_COMP=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$TC" \
            -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
          [[ "$TC_COMP" != "Compliant" ]] && ALL_TC_OK=false
        done
        if [[ "$ALL_TC_OK" == true ]]; then
          RECHECK_OK=true
          break
        fi
      done
      printf "\n"

      if [[ "$RECHECK_OK" == true ]]; then
        info "acm-dr-virt-install is now Compliant on all target clusters"
        INSTALL_POLICY_OK=true
      else
        for TC in $TARGET_CLUSTERS; do
          TC_COMP=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$TC" \
            -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
          if [[ "$TC_COMP" != "Compliant" ]]; then
            warn "acm-dr-virt-install is still ${TC_COMP} on '$TC' after waiting"

            REPL_RECHECK=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-install" -n "$TC" -o json 2>/dev/null || echo "")
            if [[ -n "$REPL_RECHECK" ]]; then
              printf "\n  ${BOLD}Current per-template status (%s):${RESET}\n" "$TC"
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
          fi
        done

        printf "\n${YELLOW}[WARNING]${RESET} The install policy is not Compliant on all target clusters. Backups will NOT work until this is resolved.\n"
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
# 5. Choose backup schedule
# ============================================================
header "5. Choose backup schedule"

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
# 6. Apply backup labels
# ============================================================
header "6. Apply backup labels"

printf "Will apply label: ${BOLD}%s=%s${RESET}\n\n" "$BACKUP_LABEL" "$CHOSEN_SCHEDULE"

LABELED_COUNT=0
SKIPPED_COUNT=0

for i in "${!SEL_NAME[@]}"; do
  vm_ns="${SEL_NS[$i]}"
  vm_name="${SEL_NAME[$i]}"
  vm_cluster="${SEL_CLUSTER[$i]}"
  current="${SEL_CURRENT[$i]}"

  if [[ "$current" == "$CHOSEN_SCHEDULE" ]]; then
    printf "  ${DIM}%-25s (%s) already has schedule '%s' -- skipped${RESET}\n" "${vm_ns}/${vm_name}" "$vm_cluster" "$current"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  if [[ "$current" != "-" ]]; then
    printf "  ${YELLOW}%-25s (%s) currently: %s -> %s${RESET}" "${vm_ns}/${vm_name}" "$vm_cluster" "$current" "$CHOSEN_SCHEDULE"
  else
    printf "  %-25s (%s) -> %s" "${vm_ns}/${vm_name}" "$vm_cluster" "$CHOSEN_SCHEDULE"
  fi

  LABEL_OK=false
  if [[ -n "${MC_CONTEXT_MAP[$vm_cluster]:-}" || "$vm_cluster" == "$LOCAL_MC" ]]; then
    # Direct access available
    if run_oc_on_cluster "$vm_cluster" label virtualmachine.kubevirt.io "$vm_name" -n "$vm_ns" \
      "${BACKUP_LABEL}=${CHOSEN_SCHEDULE}" --overwrite 2>/dev/null; then
      LABEL_OK=true
    fi
  else
    # Use ManifestWork via the hub
    if label_vm_via_hub "$vm_cluster" "$vm_ns" "$vm_name" "$BACKUP_LABEL" "$CHOSEN_SCHEDULE"; then
      LABEL_OK=true
    fi
  fi

  if [[ "$LABEL_OK" == true ]]; then
    printf "  ${GREEN}OK${RESET}\n"
    LABELED_COUNT=$((LABELED_COUNT + 1))
  else
    printf "  ${RED}FAILED${RESET}\n"
    printf "    ${YELLOW}Label manually on cluster '%s':${RESET}\n" "$vm_cluster"
    printf "    oc label virtualmachine.kubevirt.io %s -n %s %s=%s --overwrite\n" "$vm_name" "$vm_ns" "$BACKUP_LABEL" "$CHOSEN_SCHEDULE"
  fi
done

printf "\n${BOLD}Results:${RESET} %d labeled, %d skipped\n" "$LABELED_COUNT" "$SKIPPED_COUNT"

# ============================================================
# 7. Check backup policy after labeling
# ============================================================
if [[ "$LABELED_COUNT" -gt 0 ]]; then
  header "7. Verify acm-dr-virt-backup policy"

  if run_oc get crd policies.policy.open-cluster-management.io &>/dev/null; then
    printf "Waiting for backup policy to reconcile after labeling"
    BACKUP_POLICY_OK=false
    for attempt in $(seq 1 6); do
      printf "."
      sleep 10
      ALL_BP_OK=true
      for TC in $TARGET_CLUSTERS; do
        TC_BP=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-backup" -n "$TC" \
          -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")
        [[ "$TC_BP" != "Compliant" ]] && ALL_BP_OK=false
      done
      if [[ "$ALL_BP_OK" == true ]]; then
        BACKUP_POLICY_OK=true
        break
      fi
    done
    printf "\n"

    if [[ "$BACKUP_POLICY_OK" == true ]]; then
      info "acm-dr-virt-backup is Compliant on all target clusters"

      SCHED_NAME="acm-rho-virt-schedule-$(echo "$CHOSEN_SCHEDULE" | tr '_' '-')"
      for TC in $TARGET_CLUSTERS; do
        SCHED_EXISTS=$(run_oc_on_cluster "$TC" get schedule.velero.io "$SCHED_NAME" -n "$OADP_NS" --no-headers 2>/dev/null || echo "")
        if [[ -n "$SCHED_EXISTS" ]]; then
          info "Velero Schedule '$SCHED_NAME' exists on '$TC'"
        fi
      done
    else
      for TC in $TARGET_CLUSTERS; do
        TC_BP=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-backup" -n "$TC" \
          -o jsonpath='{.status.compliant}' 2>/dev/null || echo "Unknown")

        if [[ "$TC_BP" == "Compliant" ]]; then
          info "acm-dr-virt-backup is Compliant on '$TC'"
          continue
        fi

        if [[ "$TC_BP" == "Unknown" || -z "$TC_BP" ]]; then
          warn "acm-dr-virt-backup policy not found or has no status yet on '$TC'"
          continue
        fi

        err "acm-dr-virt-backup is ${TC_BP} on '$TC'"

        BP_REPL=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-backup" -n "$TC" -o json 2>/dev/null || echo "")
        if [[ -n "$BP_REPL" ]]; then
          printf "\n  ${BOLD}Per-template status (%s):${RESET}\n" "$TC"
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

          printf "\n  ${BOLD}Suggested fixes (%s):${RESET}\n" "$TC"
          echo "$BP_VIOLATED" | while IFS= read -r btmpl; do
            case "$btmpl" in
              *create-virt-backup*)
                printf "    - ${YELLOW}%s${RESET}: Velero CRD not installed or config not propagated yet.\n" "$btmpl"
                printf "      Ensure acm-dr-virt-install is Compliant first on '%s'.\n" "$TC"
                printf "      Check: oc get policy acm-dr-virt-install -n %s\n" "$NS"
                ;;
              *check-backup-status-completed*)
                printf "    - ${YELLOW}%s${RESET}: Latest backup or DataUpload not in Completed phase.\n" "$btmpl"
                printf "      This is expected if the first backup hasn't run yet (wait for the cron schedule).\n"
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
      done
    fi
  else
    warn "Policy CRD not found -- cannot verify backup policy compliance."
  fi
fi

# ============================================================
# 8. Summary and next steps
# ============================================================
header "Summary"

if [[ ${#REMOVED_KEYS[@]} -gt 0 ]]; then
  info "${#REMOVED_KEYS[@]} VM(s) removed from backup"
fi

if [[ "$LABELED_COUNT" -gt 0 ]]; then
  info "$LABELED_COUNT VM(s) labeled for backup with schedule '$CHOSEN_SCHEDULE'"
fi

SCHED_NAME_SUMMARY="acm-rho-virt-schedule-$(echo "$CHOSEN_SCHEDULE" | tr '_' '-')"

if [[ "${BACKUP_POLICY_OK:-false}" == true ]]; then
  printf "\n${BOLD}Status:${RESET}\n"
  printf "  ${GREEN}[OK]${RESET} Backup policy is Compliant on all target clusters\n"
  printf "\n  Backups will run according to the cron schedule on each cluster.\n"
else
  printf "\n${BOLD}What happens next:${RESET}\n"
  if [[ "$DPA_OK" != true ]]; then
    printf "  ${YELLOW}[PENDING]${RESET} DPA is not configured on all target clusters. Backups won't start until:\n"
    printf "    - For hub (local-cluster): ensure cluster-backup is enabled on MCH\n"
    printf "    - For managed clusters: configure dpa_spec in the acm-dr-virt-config ConfigMap on the hub\n"
    printf "    - BackupStorageLocation must be Available\n"
  elif [[ "${INSTALL_POLICY_OK:-true}" != true ]]; then
    printf "  ${YELLOW}[PENDING]${RESET} Install policy is not Compliant. Fix the issues reported above.\n"
  else
    printf "  ${YELLOW}[PENDING]${RESET} Waiting for the backup policy to reconcile.\n"
    printf "    The velero Schedule '%s' will be created on each target cluster once Compliant.\n" "$SCHED_NAME_SUMMARY"
  fi
  printf "  Once the schedule is active, backups start according to the cron expression.\n"
fi

fi  # end SKIP_TO_STATUS guard (selection)
fi  # end SKIP_TO_STATUS guard (no available VMs)

# ============================================================
# 9. Backup & DataUpload status (from hub backups)
# ============================================================
header "Backup Status"

# Ensure variables are set even if we skipped selection
OADP_NS="${OADP_NS:-open-cluster-management-backup}"
if [[ -z "${TARGET_CLUSTERS:-}" ]]; then
  TARGET_CLUSTERS=$(run_oc get managedclusters -l acm-virt-config --no-headers 2>/dev/null | awk '{print $1}' || echo "")
fi

# For each virt-labeled cluster, read the backup policy to find active schedules and status.
printf "Checking backup policy status per cluster...\n\n"

STATUS_FOUND=false
for TC in $TARGET_CLUSTERS; do
  printf "  ${BOLD}%s${RESET}\n" "$TC"

  # Read the replicated acm-dr-virt-backup policy for this cluster
  BP_JSON=$(run_oc get policy.policy.open-cluster-management.io "${NS}.acm-dr-virt-backup" -n "$TC" -o json 2>/dev/null || echo "")
  if [[ -z "$BP_JSON" ]]; then
    printf "    ${DIM}No backup policy found for this cluster${RESET}\n\n"
    continue
  fi

  BP_STATUS=$(echo "$BP_JSON" | python3 -c "
import sys, json

BLUE = '\033[34m'; YELLOW = '\033[33m'; RED = '\033[31m'; GREEN = '\033[32m'
CYAN = '\033[36m'; BOLD = '\033[1m'; DIM = '\033[2m'; RESET = '\033[0m'

p = json.load(sys.stdin)
overall = p.get('status', {}).get('compliant', 'Unknown')

if overall == 'Compliant':
    bullet = f'{GREEN}\u25cf{RESET}'
elif overall == 'NonCompliant':
    bullet = f'{RED}\u25cf{RESET}'
else:
    bullet = f'{YELLOW}\u25cf{RESET}'

print(f'    Policy: {bullet} {overall}')

details = p.get('status', {}).get('details', [])
for d in details:
    tname = d.get('templateMeta', {}).get('name', '?')
    comp = d.get('compliant', '?')
    conds = d.get('conditions', [])
    msg = ''
    if conds:
        msg = conds[0].get('message', '')

    if comp == 'Compliant':
        ic = f'{GREEN}\u2713{RESET}'
    else:
        ic = f'{RED}\u2717{RESET}'

    # Collect messages from conditions and history
    all_msgs = []
    for c in d.get('conditions', []):
        m = c.get('message', '')
        if m and m not in all_msgs:
            all_msgs.append(m)
    for h in d.get('history', []):
        m = h.get('message', '')
        if m and m not in all_msgs:
            all_msgs.append(m)
    msg = all_msgs[0] if all_msgs else ''

    print(f'      {ic} {tname}: {comp}')

    if msg:
        short_msg = msg[:300]
        if len(msg) > 300:
            short_msg += '...'
        color = YELLOW if comp != 'Compliant' else DIM
        print(f'        {color}{short_msg}{RESET}')
" 2>/dev/null || echo "    ${DIM}Could not parse policy status${RESET}")

  echo "$BP_STATUS"

  # Also show the Velero schedules visible via the policy (from the hub side)
  SCHED_JSON=$(run_oc get schedules.velero.io -n "$OADP_NS" -l "cluster.open-cluster-management.io/backup-schedule-type=kubevirt" -o json 2>/dev/null || echo '{"items":[]}')
  SCHED_TABLE=$(echo "$SCHED_JSON" | python3 -c "
import sys, json

BLUE = '\033[34m'; GREEN = '\033[32m'; YELLOW = '\033[33m'; RED = '\033[31m'
DIM = '\033[2m'; RESET = '\033[0m'
tc = '$TC'
tc_id = ''  # we'll match by schedule name containing cluster info

items = json.load(sys.stdin).get('items', [])
if not items:
    sys.exit(0)

# Find schedules for this cluster by checking the backup-cluster label
found = []
for s in items:
    labels = s.get('metadata', {}).get('labels', {})
    cluster_label = labels.get('cluster.open-cluster-management.io/backup-cluster', '')
    name = s['metadata']['name']
    phase = s.get('status', {}).get('phase', 'Unknown')
    last_backup = s.get('status', {}).get('lastBackup', '')
    cron = s.get('spec', {}).get('schedule', '?')

    # Match this schedule to the target cluster
    # The backup-cluster label has the cluster UID; we also check for cluster name in schedule name
    # For a definitive match we'd need to map cluster name -> UID, but showing all is also helpful
    found.append((name, phase, cron, last_backup, cluster_label))

if found:
    print(f'    Velero Schedules:')
    for name, phase, cron, last_backup, cid in found:
        if phase == 'Enabled':
            bullet = f'{GREEN}\u25cf{RESET}'
        else:
            bullet = f'{YELLOW}\u25cf{RESET}'
        lb = last_backup if last_backup else 'never'
        print(f'      {bullet} {name}  ({cron})  last={lb}  {DIM}{cid[:12]}{RESET}')
" 2>/dev/null || true)

  if [[ -n "$SCHED_TABLE" ]]; then
    echo "$SCHED_TABLE"
  fi

  printf "\n"
  STATUS_FOUND=true
done

if [[ "$STATUS_FOUND" != true ]]; then
  printf "  No virt-labeled clusters found.\n"
fi

printf "\n${BOLD}Useful commands:${RESET}\n"
printf "  oc get policy -A | grep backup.acm-dr-virt\n"
printf "  oc get schedules.velero.io -n %s -l cluster.open-cluster-management.io/backup-schedule-type=kubevirt\n\n" "$OADP_NS"
