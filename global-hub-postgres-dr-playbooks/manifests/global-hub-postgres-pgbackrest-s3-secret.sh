#!/usr/bin/env bash
# pgBackRest S3 credentials for repo2 on Global Hub PostgresCluster (postgres).
# Playbook: global-hub-postgres-pgbackrest-s3.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-oc}"

AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
GH_NS="${GH_NS:-multicluster-global-hub}"
OUT_SECRET="${OUT_SECRET:-multicluster-global-hub-pgbackrest-s3}"
PG_REPO="${PG_REPO:-repo2}"

python3 "${SCRIPT_DIR}/pgbackrest-s3-secret-apply.py" \
  --kubectl "${KUBECTL}" \
  --credentials-file "${AWS_CREDENTIALS_FILE}" \
  --namespace "${GH_NS}" \
  --secret-name "${OUT_SECRET}" \
  --pg-repo "${PG_REPO}"

echo "Applied Secret/${OUT_SECRET} in ${GH_NS} (pgBackRest repo ${PG_REPO}, creds from ${AWS_CREDENTIALS_FILE})"
