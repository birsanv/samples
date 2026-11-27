#!/usr/bin/env bash
# Create postgres-lab-pgbackrest-s3 from a local AWS credentials INI file.
# Does not print credential material. Re-run after rotating keys in the file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"

AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
LAB_NS="${LAB_NS:-postgres-lab}"
OUT_SECRET="${OUT_SECRET:-postgres-lab-pgbackrest-s3}"
PG_REPO="${PG_REPO:-repo1}"

python3 "${SCRIPT_DIR}/pgbackrest-s3-secret-apply.py" \
  --kubectl "${KUBECTL}" \
  --credentials-file "${AWS_CREDENTIALS_FILE}" \
  --namespace "${LAB_NS}" \
  --secret-name "${OUT_SECRET}" \
  --pg-repo "${PG_REPO}"

echo "Applied Secret/${OUT_SECRET} in namespace ${LAB_NS} (repo ${PG_REPO}, creds from ${AWS_CREDENTIALS_FILE})"
