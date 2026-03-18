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

  # Find the MCH namespace (search API lives in the same namespace)
  SEARCH_HOST=""
  MCH_NS=$(run_oc get multiclusterhub --all-namespaces --no-headers 2>/dev/null | awk '{print $1; exit}' || echo "")
  if [[ -n "$MCH_NS" ]]; then
    SEARCH_HOST=$(run_oc get route search-api -n "$MCH_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  fi


  if [[ -n "$SEARCH_HOST" ]]; then
    printf "  Search API route: ${BOLD}%s${RESET}\n" "$SEARCH_HOST"
    TOKEN=$(run_oc whoami -t 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then
      # Try the /searchapi/graphql endpoint first, then /graphql
      for SEARCH_PATH in "/searchapi/graphql" "/graphql"; do
        SEARCH_RESULT=$(curl -sk -H "Authorization: Bearer $TOKEN" \
          "https://${SEARCH_HOST}${SEARCH_PATH}" \
          -H "Content-Type: application/json" \
          -d '{"query":"query { searchResult(input: [{filters: [{property: \"kind\", values: [\"VirtualMachine\"]}, {property: \"apigroup\", values: [\"kubevirt.io\"]}]}]) { items } }"}' 2>/dev/null || echo "")

        if echo "$SEARCH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'data' in d" 2>/dev/null; then
          break
        fi
        SEARCH_RESULT=""
      done

      if [[ -n "$SEARCH_RESULT" ]]; then
        VM_TABLE=$(echo "$SEARCH_RESULT" | python3 -c "
import sys, json

data = json.load(sys.stdin)
items = []
for sr in data.get('data', {}).get('searchResult', []):
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
        warn "Search API query failed (check token permissions)"
      fi
    else
      warn "Could not get auth token (oc whoami -t)"
    fi
  else
    warn "No search API route found"
    printf "  To create one: oc create route passthrough search-api --service=search-search-api --port=4010 -n open-cluster-management\n"
  fi

  # Fallback when search didn't work: query managed clusters via kubeconfig contexts
  if [[ "$SEARCH_USED" != true ]]; then
    printf "\nQuerying managed clusters via kubeconfig contexts...\n"

    ALL_CONTEXTS=$(oc config get-contexts -o name 2>/dev/null || echo "")
    MC_JSON_ALL=$(run_oc get managedclusters -o json 2>/dev/null || echo '{"items":[]}')
    VM_IDX=1

    # Parse managed clusters: name, local-cluster flag, available status
    LOCAL_MC_NAME=""
    declare -A MC_AVAILABLE=()
    while IFS='|' read -r mcname mclocal mcavail; do
      [[ -z "$mcname" ]] && continue
      if [[ "$mclocal" == "true" ]]; then
        LOCAL_MC_NAME="$mcname"
      fi
      MC_AVAILABLE["$mcname"]="$mcavail"
    done < <(echo "$MC_JSON_ALL" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for mc in items:
    name = mc['metadata']['name']
    labels = mc.get('metadata', {}).get('labels', {})
    is_local = labels.get('local-cluster', '')
    avail = 'Unknown'
    for c in mc.get('status', {}).get('conditions', []):
        if c.get('type') == 'ManagedClusterConditionAvailable':
            avail = c.get('status', 'Unknown')
            break
    print(f'{name}|{is_local}|{avail}')
" 2>/dev/null)

    MC_LIST=$(echo "$MC_JSON_ALL" | python3 -c "
import sys, json
for mc in json.load(sys.stdin).get('items', []):
    print(mc['metadata']['name'])
" 2>/dev/null)

    for MC in $MC_LIST; do
      IS_LOCAL_MC=false
      [[ "$MC" == "$LOCAL_MC_NAME" ]] && IS_LOCAL_MC=true

      # Skip non-Ready clusters (except local-cluster)
      if [[ "$IS_LOCAL_MC" != true ]]; then
        if [[ "${MC_AVAILABLE[$MC]:-Unknown}" != "True" ]]; then
          printf "  Checking %s... ${YELLOW}skipped${RESET} ${DIM}(not Ready: %s)${RESET}\n" "$MC" "${MC_AVAILABLE[$MC]:-Unknown}"
          continue
        fi
      fi

      printf "  Checking %s..." "$MC"

      MC_CTX=""
      MC_VM_JSON=""

      if [[ "$IS_LOCAL_MC" == true ]]; then
        # local-cluster is the hub itself; use the current context
        MC_VM_JSON=$(run_oc get virtualmachines.kubevirt.io --all-namespaces -o json 2>/dev/null || echo "")
      else
        # Find the best matching kubeconfig context for this managed cluster
        for ctx in $ALL_CONTEXTS; do
          if [[ "$ctx" == "$MC" ]]; then
            MC_CTX="$ctx"
            break
          fi
        done
        if [[ -z "$MC_CTX" ]]; then
          for ctx in $ALL_CONTEXTS; do
            if echo "$ctx" | grep -qi "$MC"; then
              MC_CTX="$ctx"
              break
            fi
          done
        fi

        if [[ -n "$MC_CTX" ]]; then
          MC_VM_JSON=$(oc --context "$MC_CTX" get virtualmachines.kubevirt.io --all-namespaces -o json 2>/dev/null || echo "")
        fi
      fi

      if [[ -z "$MC_VM_JSON" || "$MC_VM_JSON" == *'"items":[]'* ]]; then
        if [[ "$IS_LOCAL_MC" == true ]]; then
          printf " ${DIM}no VMs (hub/local-cluster)${RESET}\n"
        elif [[ -n "$MC_CTX" ]]; then
          printf " ${DIM}no VMs (context: %s)${RESET}\n" "$MC_CTX"
        else
          printf " ${DIM}no kubeconfig context found${RESET}\n"
        fi
        continue
      fi

      MC_VMS=$(echo "$MC_VM_JSON" | python3 -c "
import sys, json

cluster = '$MC'
items = json.load(sys.stdin).get('items', [])
for vm in items:
    name = vm['metadata']['name']
    ns = vm['metadata']['namespace']
    uid = vm['metadata'].get('uid', '?')
    labels = vm['metadata'].get('labels', {})
    tmpl_labels = vm.get('spec', {}).get('template', {}).get('metadata', {}).get('labels', {})
    cron = labels.get('cluster.open-cluster-management.io/backup-vm', '')
    ready = 'Unknown'
    conds = vm.get('status', {}).get('conditions', [])
    for c in conds:
        if c.get('type') == 'Ready':
            ready = 'Ready' if c.get('status') == 'True' else 'NotReady'
    running = vm.get('status', {}).get('printableStatus', ready)
    backup = cron if cron else '-'
    os_type = '-'
    all_labels = {**labels, **tmpl_labels}
    for k in all_labels:
        if k.startswith('os.template.kubevirt.io/'):
            os_type = k.split('/')[-1]
            break
    if os_type == '-':
        os_type = all_labels.get('kubevirt.io/os', all_labels.get('vm.kubevirt.io/os', '-'))
    if os_type == '-':
        name_lower = name.lower()
        for osn in ('fedora', 'centos', 'rhel', 'windows', 'ubuntu', 'debian', 'sles', 'cirros'):
            if osn in name_lower:
                os_type = osn
                break
    print(f'{ns}|{name}|{running}|{backup}|{os_type}|{uid}')
" 2>/dev/null || echo "")

      if [[ -n "$MC_VMS" ]]; then
        MC_VM_COUNT=$(echo "$MC_VMS" | wc -l | tr -d ' ')
        if [[ "$IS_LOCAL_MC" == true ]]; then
          printf " ${GREEN}%d VM(s)${RESET} (hub/local-cluster)\n" "$MC_VM_COUNT"
        else
          printf " ${GREEN}%d VM(s)${RESET} (context: %s)\n" "$MC_VM_COUNT" "$MC_CTX"
          MC_CONTEXT_MAP["$MC"]="$MC_CTX"
        fi
        while IFS='|' read -r vns vname vstatus vbackup vos vuid; do
          if [[ -z "$VM_TABLE" ]]; then
            VM_TABLE="${VM_IDX}|${MC}|${vns}|${vname}|${vstatus}|${vbackup}|${vos}|${vuid}"
          else
            VM_TABLE="${VM_TABLE}"$'\n'"${VM_IDX}|${MC}|${vns}|${vname}|${vstatus}|${vbackup}|${vos}|${vuid}"
          fi
          VM_IDX=$((VM_IDX + 1))
        done <<< "$MC_VMS"
      else
        printf " no VMs (context: %s)\n" "$MC_CTX"
      fi
    done

    if [[ -n "$VM_TABLE" ]]; then
      SEARCH_USED=true
      info "Found VMs via managed cluster contexts"
    fi
  fi
fi

# Fall back to local oc get
if [[ "$SEARCH_USED" != true ]]; then
  if ! run_oc get crd virtualmachines.kubevirt.io &>/dev/null; then
    err "VirtualMachine CRD (kubevirt.io) not found on this cluster."
    printf "OpenShift Virtualization must be installed to back up VMs.\n"
    exit 1
  fi

  LOCAL_CLUSTER_ID=$(run_oc get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "local")
  LOCAL_CLUSTER_SHORT="${CTX:-local-cluster}"

  VM_JSON=$(run_oc get virtualmachines.kubevirt.io --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

  VM_TABLE=$(echo "$VM_JSON" | python3 -c "
import sys, json, os

cluster = os.environ.get('CLUSTER_NAME', 'local-cluster')
items = json.load(sys.stdin).get('items', [])
if not items:
    print('EMPTY')
    sys.exit(0)

for i, vm in enumerate(items):
    name = vm['metadata']['name']
    ns = vm['metadata']['namespace']
    uid = vm['metadata'].get('uid', '?')
    labels = vm['metadata'].get('labels', {})
    tmpl_labels = vm.get('spec', {}).get('template', {}).get('metadata', {}).get('labels', {})
    cron = labels.get('cluster.open-cluster-management.io/backup-vm', '')
    ready = 'Unknown'
    conds = vm.get('status', {}).get('conditions', [])
    for c in conds:
        if c.get('type') == 'Ready':
            ready = 'Ready' if c.get('status') == 'True' else 'NotReady'
    running = vm.get('status', {}).get('printableStatus', ready)
    backup = cron if cron else '-'
    os_type = '-'
    all_labels = {**labels, **tmpl_labels}
    for k in all_labels:
        if k.startswith('os.template.kubevirt.io/'):
            os_type = k.split('/')[-1]
            break
    if os_type == '-':
        os_type = all_labels.get('kubevirt.io/os', all_labels.get('vm.kubevirt.io/os', '-'))
    if os_type == '-':
        itype = vm.get('spec', {}).get('instancetype', {}).get('name', '')
        if itype:
            for tok in itype.lower().replace('.', '-').split('-'):
                if tok in ('fedora', 'centos', 'rhel', 'windows', 'ubuntu', 'debian', 'sles', 'cirros'):
                    os_type = tok
                    break
    if os_type == '-':
        name_lower = name.lower()
        for osn in ('fedora', 'centos', 'rhel', 'windows', 'ubuntu', 'debian', 'sles', 'cirros'):
            if osn in name_lower:
                os_type = osn
                break
    print(f'{i+1}|{cluster}|{ns}|{name}|{running}|{backup}|{os_type}|{uid}')
" 2>/dev/null)

  if [[ "$VM_TABLE" == "EMPTY" || -z "$VM_TABLE" ]]; then
    warn "No VirtualMachines found on this cluster."
    exit 0
  fi
fi

CLUSTER_NAME_ENV="${CTX:-local-cluster}"
export CLUSTER_NAME="$CLUSTER_NAME_ENV"

if [[ -z "$VM_TABLE" ]]; then
  warn "No VirtualMachines found."
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
      result+=("${nums[@]}")
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
for sr in data.get('data', {}).get('searchResult', []):
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
      warn "Unknown filter: $token"
    fi
  done

  printf '%s\n' "${result[@]}" | sort -un
}

# ============================================================
# 2. Remove VMs from backup
# ============================================================

BACKED_UP_TABLE=""
while IFS='|' read -r idx cl ns name status backup os uid; do
  [[ "$backup" != "-" ]] && {
    if [[ -z "$BACKED_UP_TABLE" ]]; then
      BACKED_UP_TABLE="${idx}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
    else
      BACKED_UP_TABLE="${BACKED_UP_TABLE}"$'\n'"${idx}|${cl}|${ns}|${name}|${status}|${backup}|${os}|${uid}"
    fi
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
  printf "${BOLD}Remove:${RESET} "
  read -r REMOVE_SELECTION </dev/tty

  if [[ -n "$REMOVE_SELECTION" ]]; then
    REMOVE_RESOLVED=$(resolve_selection "$REMOVE_SELECTION" "$VM_TABLE" "$VM_COUNT")
    REMOVE_COUNT=0

    for ridx in $REMOVE_RESOLVED; do
      RLINE=$(echo "$VM_TABLE" | sed -n "${ridx}p")
      if [[ -z "$RLINE" ]]; then
        warn "Invalid index: $ridx (skipping)"
        continue
      fi
      IFS='|' read -r _ rcl rns rname _ rbackup _ _ <<< "$RLINE"
      if [[ "$rbackup" == "-" ]]; then
        continue
      fi

      printf "  Removing backup label from %s/%s (%s)..." "$rns" "$rname" "$rcl"
      if run_oc_on_cluster "$rcl" label virtualmachine.kubevirt.io "$rname" -n "$rns" \
        "${BACKUP_LABEL}-" 2>/dev/null; then
        printf " ${GREEN}OK${RESET}\n"
        REMOVE_COUNT=$((REMOVE_COUNT + 1))
        REMOVED_KEYS+=("${rcl}|${rns}/${rname}")
      else
        printf " ${RED}FAILED${RESET}\n"
        if [[ -z "${MC_CONTEXT_MAP[$rcl]:-}" && "$rcl" != "${LOCAL_MC:-local-cluster}" ]]; then
          printf "    ${YELLOW}No kubeconfig context for '%s'. Remove manually on that cluster:${RESET}\n" "$rcl"
          printf "    oc label virtualmachine.kubevirt.io %s -n %s %s-\n" "$rname" "$rns" "$BACKUP_LABEL"
        fi
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
printf "${BOLD}Selection:${RESET} "
read -r SELECTION </dev/tty

if [[ -z "$SELECTION" ]]; then
  if [[ ${#REMOVED_KEYS[@]} -gt 0 ]]; then
    printf "\nNo VMs selected for backup. Only removal was performed.\n"
  else
    warn "No VMs selected."
  fi
  SKIP_TO_STATUS=true
fi

if [[ "${SKIP_TO_STATUS:-false}" != true ]]; then

SEL_RESOLVED=$(resolve_selection "$SELECTION" "$AVAIL_TABLE" "$AVAIL_COUNT")

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
# 4. Choose backup schedule
# ============================================================
header "4. Choose backup schedule"

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
# 5. Check policy infrastructure
# ============================================================
header "5. Verify policy infrastructure"

POLICIES_OK=true
NEEDS_POLICY_INSTALL=false
NEEDS_MC_LABEL=false

step "5a: Check policies exist on hub"

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

step "5b: Check ManagedCluster label"

# Determine target managed clusters: selected VMs + all clusters with virt policies placed
SEL_ONLY_CLUSTERS=$(printf '%s\n' "${SEL_CLUSTER[@]}" | sort -u)
LABELED_MCS=$(run_oc get managedclusters -l acm-virt-config --no-headers 2>/dev/null | awk '{print $1}' || echo "")
TARGET_CLUSTERS=$(printf '%s\n' $SEL_ONLY_CLUSTERS $LABELED_MCS | sort -u)
declare -A MC_LABEL_STATUS=()
NEEDS_MC_LABEL=false
VIRT_CONFIG_LABEL=""

for TC in $TARGET_CLUSTERS; do
  MC_NAME="$TC"
  TC_LABEL=$(run_oc get managedcluster "$MC_NAME" -o jsonpath='{.metadata.labels.acm-virt-config}' 2>/dev/null || echo "")

  if [[ -n "$TC_LABEL" ]]; then
    info "ManagedCluster '$MC_NAME' has acm-virt-config=$TC_LABEL"
    MC_LABEL_STATUS["$MC_NAME"]="$TC_LABEL"
    [[ -z "$VIRT_CONFIG_LABEL" ]] && VIRT_CONFIG_LABEL="$TC_LABEL"
  else
    warn "ManagedCluster '$MC_NAME' does not have the acm-virt-config label."
    MC_LABEL_STATUS["$MC_NAME"]=""
    NEEDS_MC_LABEL=true
    POLICIES_OK=false
  fi
done

step "5c: Check configuration ConfigMap"

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

if [[ "$NEEDS_MC_LABEL" == true ]]; then
  [[ -z "$VIRT_CONFIG_LABEL" ]] && VIRT_CONFIG_LABEL="acm-dr-virt-config"
  for TC in $TARGET_CLUSTERS; do
    if [[ -z "${MC_LABEL_STATUS[$TC]:-}" ]]; then
      if confirm "Label ManagedCluster '$TC' with acm-virt-config=$VIRT_CONFIG_LABEL?"; then
        run_oc label managedcluster "$TC" "acm-virt-config=$VIRT_CONFIG_LABEL" --overwrite 2>/dev/null && \
          info "Labeled '$TC' with acm-virt-config=$VIRT_CONFIG_LABEL" || \
          warn "Failed to label. Run: oc label managedcluster $TC acm-virt-config=$VIRT_CONFIG_LABEL"
      else
        printf "Skipping. Label manually:\n  oc label managedcluster %s acm-virt-config=%s\n" "$TC" "$VIRT_CONFIG_LABEL"
      fi
    fi
  done
fi

step "5d: Check OADP and DPA"

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

step "5e: Check acm-dr-virt-install policy compliance"

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

      # Check if this managed cluster is itself a hub (has MCH CRD)
      TC_IS_HUB=false
      if [[ "$IS_LOCAL_TC" == true ]]; then
        TC_IS_HUB="$IS_HUB"
      elif run_oc_on_cluster "$TC" get crd multiclusterhubs.operator.open-cluster-management.io &>/dev/null; then
        TC_IS_HUB=true
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

  if run_oc_on_cluster "$vm_cluster" label virtualmachine.kubevirt.io "$vm_name" -n "$vm_ns" \
    "${BACKUP_LABEL}=${CHOSEN_SCHEDULE}" --overwrite 2>/dev/null; then
    printf "  ${GREEN}OK${RESET}\n"
    LABELED_COUNT=$((LABELED_COUNT + 1))
  else
    printf "  ${RED}FAILED${RESET}\n"
    if [[ -z "${MC_CONTEXT_MAP[$vm_cluster]:-}" && "$vm_cluster" != "$LOCAL_MC" ]]; then
      printf "    ${YELLOW}No kubeconfig context for '%s'. Label manually on that cluster:${RESET}\n" "$vm_cluster"
      printf "    oc label virtualmachine.kubevirt.io %s -n %s %s=%s --overwrite\n" "$vm_name" "$vm_ns" "$BACKUP_LABEL" "$CHOSEN_SCHEDULE"
    fi
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

BKP_SCHED_LABEL="cluster.open-cluster-management.io/backup-schedule-type=kubevirt"

# All kubevirt backups live on the hub (the hub's OADP runs the schedules).
# Each backup's annotations tell us which cluster + schedule it belongs to.
# The schedule name encodes the source cluster ID and cron name.
BKP_OUT=$(run_oc get backups.velero.io -n "$OADP_NS" -l "$BKP_SCHED_LABEL" -o json 2>/dev/null || echo '{"items":[]}')
BKP_TABLE=$(echo "$BKP_OUT" | python3 -c "
import sys, json, re

items = json.load(sys.stdin).get('items', [])
if not items:
    print('__NONE__')
    sys.exit(0)

BLUE = '\033[34m'; YELLOW = '\033[33m'; RED = '\033[31m'; CYAN = '\033[36m'
BOLD = '\033[1m'; DIM = '\033[2m'; RESET = '\033[0m'

rows = []
for b in items:
    name = b['metadata']['name']
    phase = b.get('status', {}).get('phase', 'Unknown')
    started = b.get('status', {}).get('startTimestamp', '')
    errs = b.get('status', {}).get('errors', 0)
    warns = b.get('status', {}).get('warnings', 0)
    sch = b['metadata'].get('labels', {}).get('velero.io/schedule-name', '?')

    labels = b['metadata'].get('labels', {})
    cluster_id = labels.get('cluster.open-cluster-management.io/backup-cluster', '?')

    # Extract schedule cron name from schedule name
    sched_name = sch
    # acm-rho-virt-schedule-<cron_name>-<clusterid>
    m = re.match(r'acm-rho-virt-schedule-(.+)-[a-f0-9]{8,}$', sch)
    if m:
        sched_name = m.group(1)

    rows.append((cluster_id, sched_name, started, name, phase, errs, warns, sch))

# Sort by cluster_id, schedule name, timestamp desc
rows.sort(key=lambda r: (r[0], r[1], r[2] or ''), reverse=False)

# Find the latest per (cluster_id, schedule)
latest_keys = set()
seen = {}
for r in rows:
    key = (r[0], r[1])
    ts = r[2] or ''
    if key not in seen or ts > seen[key]:
        seen[key] = ts
# rows is sorted asc by ts within group; re-sort desc within groups for display
rows.sort(key=lambda r: (r[0], r[1], r[2] or ''), reverse=False)
# Group display: cluster -> schedule -> backups (newest first within each)
from collections import OrderedDict
groups = OrderedDict()
for r in rows:
    key = (r[0], r[1])
    groups.setdefault(key, []).append(r)

# Compute max widths for clean alignment
cid_w = max((len(r[0]) for r in rows), default=10)
sch_w = max((len(r[1]) for r in rows), default=10)

print(f'  {BOLD}{\"CLUSTER-ID\":<{cid_w}s}  {\"SCHEDULE\":<{sch_w}s}  {\"STATUS\":<18s}  {\"STARTED\":<22s}  {\"ERR\":<4s}  {\"WARN\":<4s}  NAME{RESET}')

for (cid, sname), bkps in groups.items():
    bkps.sort(key=lambda r: r[2] or '', reverse=True)
    show = bkps[:2]
    remaining = len(bkps) - 2
    for i, r in enumerate(show):
        cluster_id, sched_name, started, bname, phase, errs, warns, full_sch = r
        if phase == 'Completed':
            bullet = f'{BLUE}\u25cf{RESET}'
        elif phase == 'PartiallyFailed':
            bullet = f'{YELLOW}\u25cf{RESET}'
        else:
            bullet = f'{RED}\u25cf{RESET}'
        if i == 0:
            cid_disp = f'{CYAN}{cluster_id}{RESET}'
            cid_pad = cid_w + 9
            sname_disp = sched_name
        else:
            cid_disp = ''
            cid_pad = cid_w
            sname_disp = ''
        print(f'  {cid_disp:<{cid_pad}s}  {sname_disp:<{sch_w}s}  {bullet} {phase:<16s}  {started or \"?\":<22s}  {errs:<4}  {warns:<4}  {DIM}{bname}{RESET}')
    if remaining > 0:
        print(f'  {\"\":<{cid_w}s}  {\"\":<{sch_w}s}  {DIM}... {remaining} older backup(s){RESET}')
" 2>/dev/null || echo "__NONE__")

if [[ "$BKP_TABLE" == "__NONE__" ]]; then
  printf "  No kubevirt backups found.\n"
else
  echo "$BKP_TABLE"
fi

# --- DataUploads (on each target cluster) ---
printf "\n"
for TC in $TARGET_CLUSTERS; do
  DU_OUT=$(run_oc_on_cluster "$TC" get datauploads.velero.io -n "$OADP_NS" -o json 2>/dev/null || echo '{"items":[]}')
  DU_SUMMARY=$(echo "$DU_OUT" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if not items:
    print('none')
    sys.exit(0)
by_phase = {}
for du in items:
    phase = du.get('status', {}).get('phase', 'Unknown')
    by_phase[phase] = by_phase.get(phase, 0) + 1
parts = []
for phase in ('Completed', 'InProgress', 'Failed', 'Canceling', 'Canceled', 'Unknown'):
    if phase in by_phase:
        parts.append(f'{phase}={by_phase[phase]}')
for phase in sorted(by_phase):
    if phase not in ('Completed', 'InProgress', 'Failed', 'Canceling', 'Canceled', 'Unknown'):
        parts.append(f'{phase}={by_phase[phase]}')
print(f'{len(items)} total: {\"  \".join(parts)}')

BLUE = '\033[34m'; YELLOW = '\033[33m'; RED = '\033[31m'; RESET = '\033[0m'
failed = [du for du in items if du.get('status',{}).get('phase','') == 'Failed']
in_progress = [du for du in items if du.get('status',{}).get('phase','') == 'InProgress']
for du in (failed + in_progress)[:5]:
    name = du['metadata']['name']
    phase = du.get('status', {}).get('phase', '?')
    msg = du.get('status', {}).get('message', '')[:100]
    started = du.get('status', {}).get('startTimestamp', '?')
    c = RED if phase == 'Failed' else YELLOW
    line = f'    {c}\u25cf{RESET} {name}: {phase}  started={started}'
    if msg:
        line += f'  msg={msg}'
    print(line)
if len(failed) + len(in_progress) > 5:
    print(f'    ... and {len(failed) + len(in_progress) - 5} more')
" 2>/dev/null || echo "none")

  if [[ "$DU_SUMMARY" == "none" ]]; then
    printf "  ${BOLD}DataUploads (%s):${RESET} none\n" "$TC"
  else
    printf "  ${BOLD}DataUploads (%s):${RESET} %s\n" "$TC" "$(echo "$DU_SUMMARY" | head -1)"
    DU_DETAILS=$(echo "$DU_SUMMARY" | tail -n +2)
    [[ -n "$DU_DETAILS" ]] && echo "$DU_DETAILS"
  fi
done

printf "\n${BOLD}Useful commands:${RESET}\n"
printf "  oc get backups.velero.io -n %s -l %s --sort-by=.status.startTimestamp\n" "$OADP_NS" "$BKP_SCHED_LABEL"
printf "  oc get datauploads.velero.io -n %s\n" "$OADP_NS"
printf "  oc get policy -n %s | grep acm-dr-virt\n\n" "$NS"
