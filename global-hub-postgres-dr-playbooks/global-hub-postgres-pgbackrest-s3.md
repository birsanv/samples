# Global Hub Postgres: S3-only pgBackRest + passive hub restore

Configure Global Hub Crunchy **`PostgresCluster/postgres`** (`hoh`) so **all pgBackRest backups and WAL archives go to S3 only** (`repo2`), aligned with ACM **OADP / DPA** (same AWS account, **dedicated prefix**). Scheduled backups:

| Type | Schedule (UTC cron) |
|------|---------------------|
| **Full** | Sunday `02:00` — `0 2 * * 0` |
| **Incremental** | Every hour — `0 * * * *` |
| **Differential** | Mon–Sat `03:00` (not Sunday) — `0 3 * * 1-6` |

Passive-hub DR on a **new** cluster has two documented paths:

| Path | Order (summary) |
|------|------------------|
| **A — manual S3 Secret** | Operators only → create pgBackRest Secret (§7.2 script) → Postgres from S3 (§7.2) → ACM Velero passive restore (§7.3) |
| **B — Velero passive credentials** | Operators only → passive **credentials** restore (§2.1 label on active hub) → Postgres from S3 (§7.2) → ACM Velero **resources** passive restore (§7.3) |

In **both** paths, restore **`hoh` in Postgres before** `MulticlusterGlobalHub` and other GH workload CRs that would reconcile an empty `PostgresCluster`. Managed-cluster **activation** (`veleroManagedClustersBackupName: latest`) stays **after** passive data and Postgres, per [cluster-backup-operator README](https://github.com/stolostron/cluster-backup-operator/blob/main/README.md).

Velero carries the pgBackRest **S3 credential Secret** as passive data when it is labeled on the backup hub (§2.1). pgBackRest on S3 still owns **`hoh`**; Velero does not.

This does **not** replace Velero for hub Kubernetes objects (MCH, activation, etc.).

**Related lab:** [crunchy-pg-pgbackrest-lab.md](./crunchy-pg-pgbackrest-lab.md) (`postgres-lab` / `pg-playground`).

---

## Prerequisites

- `oc` / `kubectl` logged into the hub as cluster-admin (or sufficient rights on `multicluster-global-hub`).
- **Active hub (§1–§5):** **Multicluster Global Hub** with Crunchy Postgres — MGH annotated `mgh-install-crunchy-operator: "true"`, `PostgresCluster/postgres` **Ready**.
- **Passive hub (§7):** **Operators only** first (`global-hub-operators-only.yaml`); MGH comes from **ACM Velero restore** after Postgres S3 restore.
- **PGO 5.8.x** CSV `Succeeded` (Postgres **16** if operand defaults to 14 — see §1).
- AWS credentials INI (default: `~/.aws/credentials`); S3 bucket IAM on pgBackRest prefix (not Velero’s schedule prefix).
- **Passive hub:** cluster-backup-operator / OADP installed for Velero **Restore** (§7.3).

**Manifests / scripts in this repo**

| File | Purpose |
|------|---------|
| [manifests/global-hub-postgres-pgbackrest-s3-secret.sh](./manifests/global-hub-postgres-pgbackrest-s3-secret.sh) | Build pgBackRest S3 Secret from local AWS INI file |
| [manifests/pgbackrest-s3-secret-apply.py](./manifests/pgbackrest-s3-secret-apply.py) | Shared apply logic (used by GH + lab scripts) |
| [manifests/global-hub-postgres-pgbackrest-dual-repo.yaml](./manifests/global-hub-postgres-pgbackrest-dual-repo.yaml) | Merge patch: **S3-only** `repo2` + cron schedules (§3) |
| [manifests/global-hub-postgres-restore-from-s3.yaml](./manifests/global-hub-postgres-restore-from-s3.yaml) | Passive hub: `PostgresCluster` with `dataSource.pgbackrest` (§7) |
| [manifests/global-hub-operators-only.yaml](./manifests/global-hub-operators-only.yaml) | New hub: GH + Crunchy OLM only — **no MGH** (§7.1) |
| [manifests/global-hub-instance.yaml](./manifests/global-hub-instance.yaml) | Example MGH spec (reference; on passive hub prefer **Velero restore** of MGH) |
| [manifests/postgres-lab-s3-secret.sh](./manifests/postgres-lab-s3-secret.sh) | Same pattern for `postgres-lab` (defaults to **repo1** S3 keys) |

---

## Configuration (edit before you run)

Set these to match your hub (export or edit the YAML patch):

| Variable | Example | Meaning |
|----------|---------|---------|
| `GH_NS` | `multicluster-global-hub` | Global Hub namespace |
| `CLUSTER` | `postgres` | PGO `PostgresCluster` name (GH hardcodes this) |
| `S3_BUCKET` | `YOUR_S3_BUCKET` | S3 bucket (can match DPA bucket; use a **different prefix**) |
| `S3_REGION` | `us-east-2` | AWS region |
| `S3_ENDPOINT` | `s3.us-east-2.amazonaws.com` | Regional endpoint |
| `S3_PREFIX` | `/pgbackrest/multicluster-global-hub/postgres/repo2` | `global.repo2-path` (object key prefix in bucket) |
| `REPO_S3` | `repo2` | S3 repo name (must match Secret key prefix `repo2-s3-key`) |
| `AWS_CREDENTIALS_FILE` | `~/.aws/credentials` | Path to AWS INI (same format as Velero `cloud` key) |

**Do not** store Velero backups and pgBackRest objects under the same prefix (e.g. DPA `hub-a/`). Use something like `pgbackrest/multicluster-global-hub/postgres/repo2/`.

**Note:** The GH operator’s default operand creates **repo1 on PVC**. This playbook **replaces** `spec.backups.pgbackrest.repos` with **repo2 S3 only** (§3). Re-apply §3 after ACM restore if the operand resets backups to repo1-only.

---

## 1. Confirm Global Hub Postgres is healthy

```bash
oc get mgh -n multicluster-global-hub
oc get postgrescluster postgres -n multicluster-global-hub
oc get pods -n multicluster-global-hub | grep -E '^postgres-'
```

If PostgresCluster reports **MissingRequiredImage** for Postgres 14:

```bash
oc patch postgrescluster postgres -n multicluster-global-hub \
  --type=merge -p '{"spec":{"postgresVersion":16}}'
```

Wait until primaries are `4/4 Running` and `PostgresCluster` is ready.

---

## 2. Create the pgBackRest S3 Secret (repo2)

The Secret must use PGO’s `s3.conf` format with keys named for the **S3 repo** (`repo2`, not `repo1`):

```ini
[global]
repo2-s3-key=<AWS_ACCESS_KEY_ID>
repo2-s3-key-secret=<AWS_SECRET_ACCESS_KEY>
```

**From local AWS INI file (default `~/.aws/credentials`):**

```bash
chmod +x manifests/global-hub-postgres-pgbackrest-s3-secret.sh

# Optional overrides:
export AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export KUBECTL=oc
export GH_NS=multicluster-global-hub
export OUT_SECRET=multicluster-global-hub-pgbackrest-s3
export PG_REPO=repo2

manifests/global-hub-postgres-pgbackrest-s3-secret.sh
```

Verify (metadata only):

```bash
oc get secret multicluster-global-hub-pgbackrest-s3 -n multicluster-global-hub
```

### 2.1 Label the Secret for ACM passive backup (Path B)

On the **backup (active) hub**, label the pgBackRest S3 Secret so cluster-backup-operator backs it up on **`acm-credentials-schedule`** and restores it with **passive credentials** (before managed-cluster activation). The operator does **not** label this Secret automatically.

```bash
GH_NS=multicluster-global-hub
SECRET=multicluster-global-hub-pgbackrest-s3

oc label secret "$SECRET" -n "$GH_NS" \
  cluster.open-cluster-management.io/backup=global-hub-pgbackrest \
  --overwrite
```

| Label value | Restore timing |
|-------------|----------------|
| Any string **except** `cluster-activation` (example: `global-hub-pgbackrest`) | Passive credentials restore |
| `cluster-activation` | **Do not use** — delays the Secret until MC activation (wrong for pgBackRest S3 restore) |

Requirements:

1. Label the Secret **before** the next successful **credentials** backup snapshot (or restore on the passive hub will not contain it).
2. The restored Secret must remain PGO **`s3.conf`** format (§2); Velero restores the same object you created on the active hub.
3. If AWS keys rotate on the active hub, update and re-backup the Secret, or patch the passive copy before §7.2.

See [README — Extending backup data](../../README.md#extending-backup-data) and [README — Restoring passive resources](../../README.md#restoring-passive-resources).

---

## 3. Patch PostgresCluster: S3-only backups (repo2) + schedules

After the GH operator has created `PostgresCluster/postgres`, merge this patch (overwrites the default **repo1 PVC** backup repo with **S3-only repo2** and cron schedules):

Edit [global-hub-postgres-pgbackrest-dual-repo.yaml](./manifests/global-hub-postgres-pgbackrest-dual-repo.yaml) if your bucket, region, endpoint, or `repo2-path` differ, then:

```bash
oc patch postgrescluster postgres -n multicluster-global-hub \
  --type=merge \
  --patch-file manifests/global-hub-postgres-pgbackrest-dual-repo.yaml
```

**Console alternative** — merge under `spec.backups.pgbackrest`:

```yaml
  backups:
    pgbackrest:
      configuration:
        - secret:
            name: multicluster-global-hub-pgbackrest-s3
      global:
        repo2-path: /pgbackrest/multicluster-global-hub/postgres/repo2
        repo2-retention-full: "4"
        repo2-retention-full-type: count
      repos:
        - name: repo2
          schedules:
            full: "0 2 * * 0"
            incremental: "0 * * * *"
            differential: "0 3 * * 1-6"
          s3:
            bucket: YOUR_S3_BUCKET
            endpoint: s3.us-east-2.amazonaws.com
            region: us-east-2
```

Keep existing `spec.postgresVersion`, `instances`, `users`, and `patroni` unchanged.

**Retention (repo2):** pgBackRest defaults to `repo2-retention-full-type=count` without `repo2-retention-full`, which logs a **WARN** on every backup (not a failure). Set how many **full** backups to keep on S3 (older fulls and their dependent incrs/diffs are expired). Example above keeps **4** fulls (~4 weekly Sunday backups). For **days** instead of count:

```yaml
        repo2-retention-full: "90"
        repo2-retention-full-type: time
```

If the cluster still has **repo1** on PVC, set `repo1-retention-full` the same way to silence repo1 WARNs.

PGO will roll repo-host / backup jobs as needed. Watch:

```bash
oc get pods -n multicluster-global-hub -w | grep -E 'repo|postgres-pgha'
oc get cronjob -n multicluster-global-hub | grep -i postgres
oc describe postgrescluster postgres -n multicluster-global-hub | tail -25
```

---

## 4. Verify S3 backups (and optional manual full)

Scheduled jobs should appear after §3. For an immediate **full** to S3 before DR testing, set `manual.repoName` to **`repo2`** ([Crunchy backup management](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/backup-management/)):

```bash
oc patch postgrescluster postgres -n multicluster-global-hub --type=merge -p '{
  "spec": {
    "backups": {
      "pgbackrest": {
        "manual": {
          "repoName": "repo2",
          "options": ["--type=full", "--repo=2"]
        }
      }
    }
  }
}'

oc annotate -n multicluster-global-hub postgrescluster postgres \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

oc -n multicluster-global-hub get jobs -w | grep -E 'postgres|backup'
```

### 4.1 Check whether a backup exists (authoritative: `pgbackrest info`)

From the **current primary**:

```bash
PRIMARY=$(oc get pods -n multicluster-global-hub \
  -l postgres-operator.crunchydata.com/cluster=postgres,postgres-operator.crunchydata.com/role=master \
  -o name | head -1)

oc exec -n multicluster-global-hub "${PRIMARY#pod/}" -c database -- pgbackrest info
```

How to read the output:

| What you see | Meaning |
|--------------|---------|
| `repo2: ok` and `full` / `incr` / `diff` with `repo2: backup set size` | Valid backup on **S3** |
| `repo2: error (no valid backups)` | No usable S3 backup — run §4 manual full or wait for Sunday full schedule |
| `repo1:` lines | Old **repo1 PVC** config still present — re-apply §3 S3-only patch |

S3 repo only:

```bash
oc exec -n multicluster-global-hub "${PRIMARY#pod/}" -c database -- \
  pgbackrest info --stanza=db --repo=2
```

### 4.2 Check objects in the S3 bucket (AWS CLI)

Use the same credentials file as the Secret script (not Velero’s `hub-a/` prefix):

```bash
export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export AWS_DEFAULT_REGION=us-east-2

# Prefix matches global.repo2-path (leading / is usually omitted in S3 keys)
aws s3 ls s3://YOUR_S3_BUCKET/pgbackrest/multicluster-global-hub/postgres/repo2/ --recursive
```

A healthy repo typically has **`backup/`** and **`archive/`** (WAL) keys under that prefix. An empty listing matches `no valid backups` in `pgbackrest info`.

If the prefix is wrong, search more broadly (then fix `repo2-path` in the `PostgresCluster`):

```bash
aws s3 ls s3://YOUR_S3_BUCKET/pgbackrest/ --recursive | head -50
```

### 4.3 Backup job logs

When repo2 fails, the primary or repo-host backup job log shows S3/auth errors:

```bash
oc get jobs -n multicluster-global-hub | grep -E 'postgres|pgbackrest|backup'

# Replace JOB with the latest Completed/Failed backup job name:
oc logs -n multicluster-global-hub job/JOB -c pgbackrest
```

Look for `repo=2`, `S3`, `HTTP 403`, or credential errors.

Confirm the Job was created for **repo2**, not the default **repo1 PVC** repo:

```bash
JOB=$(oc get jobs -n multicluster-global-hub --sort-by=.metadata.creationTimestamp \
  | grep -E 'postgres-backup|repo2' | tail -1 | awk '{print $1}')

oc get job "$JOB" -n multicluster-global-hub -o yaml | grep -E 'pgbackrest-repo|--repo='
```

| Job args / annotation | Meaning |
|----------------------|---------|
| `--repo=2` and/or `pgbackrest-repo: repo2` | S3 backup attempt |
| `--repo=1` or `pgbackrest-repo: repo1` | **Local PVC only** — nothing written to your S3 prefix |
| No new Job after annotate | Often `spec.shutdown: true` or repo-host not ready — see §6 |

Common **repo2** failure before any object exists in S3:

```text
ERROR: [055]: unable to load info file '.../backup/db/backup.info' ...
HINT: has a stanza-create been performed?
```

That usually means **repo2 was never initialized on S3** (no stanza / no `backup.info` yet). An **incremental** schedule firing before the first **full** on repo2 produces the same error.

### 4.4 Debug checklist: S3 prefix empty or repo2 backups failing

Use this when `aws s3 ls` shows no prefix (or only an empty folder), manual backup “succeeds” in the UI but S3 stays empty, or repo2 CronJobs never complete. Replace `GH_NS`, bucket, and prefix with your values (`global.repo2-path` on the cluster — e.g. `.../repo2` or per-hub `.../hub-1-repo2`).

**1. PostgresCluster must be running (not shut down)**

```bash
GH_NS=multicluster-global-hub
oc get postgrescluster postgres -n "$GH_NS" -o jsonpath='shutdown={.spec.shutdown}{"\n"}'
```

If `shutdown=true`, primaries and repo-host are scaled to **0**, repo2 CronJobs are **suspended**, and a backup annotation may **not** create a Job. Patch `spec.shutdown: false` and wait for pods before continuing.

**2. Pods and pgBackRest repo-host**

```bash
oc get pods -n "$GH_NS" -l postgres-operator.crunchydata.com/cluster=postgres
oc get sts -n "$GH_NS" | grep postgres
```

Expect a **Running** primary (`postgres-pgha1-*`, `4/4`) and **`postgres-repo-host-0`** (`2/2`). S3 scheduled backups run through repo-host; if it is `0/0`, fix shutdown / conditions first.

**3. PostgresCluster conditions**

```bash
oc get postgrescluster postgres -n "$GH_NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

| Condition | What you want |
|-----------|----------------|
| `PGBackRestRepoHostReady=True` | Repo-host ready for S3 backup jobs |
| `PGBackRestManualBackupSuccessful=True` | **Check §6 step 5** — may refer to an old **repo1** job, not S3 |
| `stanzaCreated` on repo2 in status | **Not sufficient alone** — confirm with `pgbackrest info --repo=2` on repo-host (step 6) |

**4. Repo2 CronJobs (scheduled backups)**

```bash
oc get cronjob -n "$GH_NS" | grep repo2
for cj in postgres-repo2-full postgres-repo2-incr postgres-repo2-diff; do
  printf '%s ' "$cj"
  oc get cronjob "$cj" -n "$GH_NS" -o jsonpath='suspend={.spec.suspend} lastSchedule={.status.lastScheduleTime} lastSuccess={.status.lastSuccessfulTime}{"\n"}' 2>/dev/null || echo '(missing)'
done
```

| Observation | Likely cause |
|-------------|--------------|
| `suspend=true` | Cluster shut down or repo-host not ready |
| `lastSchedule` unset | Cron never fired yet, or still suspended |
| Failed `postgres-repo2-incr-*` Jobs | **No first full on repo2** — run §4 manual full after stanza exists |

**5. Backup Jobs (manual and scheduled)**

```bash
oc get jobs -n "$GH_NS" --sort-by=.metadata.creationTimestamp | grep -E 'postgres-backup|repo2'
```

For each **Failed** or latest Job, inspect logs (see §4.3) and repo:

```bash
oc get job JOB -n "$GH_NS" -o yaml | grep -E 'pgbackrest-repo|--repo=|--type='
oc logs -n "$GH_NS" job/JOB --all-containers | tail -30
```

Delete stuck **Failed** Jobs after fixing repo2 stanza so a fresh manual run is easier to read:

```bash
oc delete job -n "$GH_NS" -l postgres-operator.crunchydata.com/cluster=postgres 2>/dev/null || true
# Or delete specific names: postgres-backup-XXXX, postgres-repo2-incr-XXXXX
```

Then re-run §4 manual full (patch `manual.repoName: repo2` + annotate).

**6. Authoritative repo2 view (repo-host, not only primary)**

```bash
REPO_HOST=$(oc get pods -n "$GH_NS" -l postgres-operator.crunchydata.com/cluster=postgres,postgres-operator.crunchydata.com/data=pgbackrest -o jsonpath='{.items[0].metadata.name}')

oc exec -n "$GH_NS" "$REPO_HOST" -c pgbackrest -- pgbackrest info
oc exec -n "$GH_NS" "$REPO_HOST" -c pgbackrest -- pgbackrest info --stanza=db --repo=2
```

| `pgbackrest info --repo=2` | Meaning |
|----------------------------|---------|
| `error (missing stanza path)` / **No stanzas exist** | Repo2 not initialized on S3 — run step 7, then §4 manual **full** |
| `error (no valid backups)` but `wal archive min/max` present | **Stanza + WAL archiving OK**; still need a successful **full** backup for restore-sized `backup/` data |
| `full backup` with `repo2: backup set size` | S3 repo2 is healthy for DR |

**7. Initialize repo2 on S3 (stanza-create) if step 6 shows missing stanza**

Run on **repo-host** (pgBackRest applies to all repos; do **not** pass `--repo` to `stanza-create`):

```bash
oc exec -n "$GH_NS" "$REPO_HOST" -c pgbackrest -- pgbackrest stanza-create --stanza=db
oc exec -n "$GH_NS" "$REPO_HOST" -c pgbackrest -- pgbackrest info --stanza=db --repo=2
```

Then trigger §4 manual **full** to repo2 (annotate after `manual.repoName: repo2` is set). Wait for a **Completed** Job with `--repo=2 --type=full`.

**8. S3 console / CLI (match `repo2-path` exactly)**

Read the prefix from the cluster (avoid guessing):

```bash
PREFIX=$(oc get postgrescluster postgres -n "$GH_NS" -o jsonpath='{.spec.backups.pgbackrest.global.repo2-path}')
echo "repo2-path=${PREFIX}"
# Strip leading slash for aws s3 ls:
KEY="${PREFIX#/}"
```

```bash
export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export AWS_DEFAULT_REGION=us-east-2   # match spec.repos[].s3.region

aws s3 ls "s3://YOUR_S3_BUCKET/${KEY}/"
aws s3 ls "s3://YOUR_S3_BUCKET/${KEY}/" --recursive | head -30
```

What to expect over time:

| S3 under prefix | Meaning |
|-----------------|---------|
| Nothing at all | Wrong bucket/region/credentials, wrong prefix, or repo2 never reached S3 (steps 1–7) |
| `backup/db/backup.info` only (~hundreds of bytes) | Stanza created; **no full backup yet** |
| `archive/` with `.gz` WAL segments | Archiving to repo2 works |
| `backup/db/` plus large backup set paths | Full/incr/diff backups landing on S3 |

If you use **one bucket for multiple hubs**, use a **unique** `repo2-path` per hub (e.g. `.../hub-1-repo2` vs `.../repo2-hub-b`). List the parent prefix to see other hubs’ folders:

```bash
aws s3 ls s3://YOUR_S3_BUCKET/pgbackrest/multicluster-global-hub/postgres/
```

**9. Secret and config (metadata only)**

```bash
oc get secret multicluster-global-hub-pgbackrest-s3 -n "$GH_NS"
oc get configmap postgres-pgbackrest-config -n "$GH_NS" -o yaml | grep repo2-path
```

Keys in the Secret must be `repo2-s3-key` / `repo2-s3-key-secret` in `s3.conf` (§2). Bucket/endpoint/region come from the `PostgresCluster` spec and ConfigMap, not only the Secret.

---

## 5. Policies and other `hoh` data vs WAL on S3

ACM **Policy** resources (GRC) live on the hub as Kubernetes CRs. Multicluster Global Hub copies policy **spec** into Postgres database **`hoh`** (for example `local_spec.policies`) via **agent → Kafka → manager**. That path is independent of pgBackRest.

pgBackRest does **not** put policy names in S3 as objects you can browse. It stores:

- **Backup sets** under `backup/` (full/incr images of the database at backup time).
- **WAL segments** under `archive/` (committed changes **after** the last backup, for point-in-time recovery).

So when you create a new policy:

| Question | Typical answer |
|----------|----------------|
| Is it in **`hoh` on the hub** yet? | Yes, after agent/manager sync (seconds to minutes). Check Postgres, not S3. |
| Is it inside the last **full backup** on S3? | Only if that backup ran **after** the row was committed. Older full backups do not include it. |
| Is it recoverable from S3 anyway? | **Yes**, if WAL archiving to repo2 is healthy: restore **backup + WAL** to a time after the insert (PITR). |
| Do I need a new full backup for the policy to “exist” for DR? | **No** for logical continuity (WAL carries changes). New full/incr backups are still useful for faster restore and retention. |

**Compliance** history (`history.local_compliance`, Grafana daily views) can lag policy **spec** rows; that is separate from pgBackRest.

### 5.1 Confirm policy spec in Postgres

Resolve the current primary (same as §4.2):

```bash
PRIMARY=$(oc get pods -n multicluster-global-hub \
  -l postgres-operator.crunchydata.com/cluster=postgres,postgres-operator.crunchydata.com/role=master \
  -o name | head -1)
```

Row count and latest updates:

```bash
oc exec -n multicluster-global-hub "${PRIMARY#pod/}" -c database -- \
  psql -U postgres -d hoh -c \
  "SELECT count(*), max(updated_at) FROM local_spec.policies;"

oc exec -n multicluster-global-hub "${PRIMARY#pod/}" -c database -- \
  psql -U postgres -d hoh -c \
  "SELECT policy_name, updated_at FROM local_spec.policies ORDER BY updated_at DESC LIMIT 10;"
```

Compare with hub Policy CRs (replace namespace if needed):

```bash
oc get policy -A --sort-by=.metadata.creationTimestamp
```

### 5.2 Compare full backup time vs WAL archive on repo2

`wal archive min/max` should extend **past** the `wal stop` of the latest full backup if archiving is catching up commits after that backup:

```bash
oc exec -n multicluster-global-hub "${PRIMARY#pod/}" -c database -- \
  pgbackrest info --stanza=db --repo=2
```

From **repo-host** (same stanza view):

```bash
REPO_HOST=$(oc get pods -n multicluster-global-hub -o name | grep repo-host | head -1)

oc exec -n multicluster-global-hub "${REPO_HOST#pod/}" -c pgbackrest -- \
  pgbackrest info --stanza=db --repo=2
```

Example reading:

- `full backup` … `wal start/stop: …/0000004F` — database image as of that backup.
- `wal archive min/max` ending at `…/00000052` — segments through **52** are (or were) archived; transactions committed after backup end WAL **4F** are in later segments, not in the full backup file alone.

Re-run `pgbackrest info --repo=2` after creating a policy; **`wal archive max`** should advance over time as segments fill and archive.

### 5.3 WAL objects under the S3 prefix (optional)

WAL keys appear under `archive/` (not as readable policy JSON):

```bash
export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export AWS_DEFAULT_REGION=us-east-2

aws s3 ls s3://YOUR_S3_BUCKET/pgbackrest/multicluster-global-hub/postgres/repo2/archive/ --recursive | tail -20
```

Recent timestamps after policy changes indicate archiving is active. An empty `archive/` with only `backup/` may mean archiving is misconfigured or very new.

### 5.4 Per-repo manual backup (after large `hoh` changes)

WAL + an older full backup is enough for PITR. To refresh the **backup set** on S3 (faster restore, clearer `pgbackrest info`), trigger a full backup **to repo2** by setting `manual.repoName` to `repo2` and optional `options` (see [Crunchy backup management](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/backup-management/)):

```bash
oc patch postgrescluster postgres -n multicluster-global-hub --type=merge -p '{
  "spec": {
    "backups": {
      "pgbackrest": {
        "manual": {
          "repoName": "repo2",
          "options": ["--type=full", "--repo=2"]
        }
      }
    }
  }
}'

oc annotate -n multicluster-global-hub postgrescluster postgres \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

Then re-check §5.2 and §4.3.

---

## 7. Passive hub: operators → Postgres S3 restore → ACM Velero restore

Use this on a **new** OpenShift hub that has **ACM/OADP** available but **no** Global Hub workload yet. **Order matters:** restore **`hoh` in Postgres before** the cluster-backup-operator **Restore** recreates hub CRs (including `MulticlusterGlobalHub`).

### 7.0 DR paths (A vs B)

```text
Path A (manual Secret)
 1. Operators only
 2. pgBackRest S3 Secret     §7.2 script
 3. Postgres from S3         §7.2 apply restore manifest
 4. ACM passive restore      §7.3 (credentials + resources; exclude PostgresCluster)
 5. Reconcile                §7.4

Path B (Velero credentials + pgBackRest between passive steps)
 1. Operators only           §7.1
 2. Passive credentials only §7.1.1 (pgBackRest Secret from backup hub §2.1)
 3. Postgres from S3         §7.2 (skip Secret script if step 2 restored the Secret)
 4. Passive resources        §7.3 (MGH, Kafka, …; still exclude PostgresCluster)
 5. Reconcile                §7.4
 6. MC activation (optional) veleroManagedClustersBackupName: latest when cutting over
```

Path **B** matches ACM’s split between **passive** data and **managed-cluster activation**: the S3 credential Secret is available after step 2; pgBackRest runs **before** passive **resources** restore recreates `MulticlusterGlobalHub`.

### 7.1 Install operators only (no MulticlusterGlobalHub)

```bash
oc apply -f manifests/global-hub-operators-only.yaml

oc get csv -n multicluster-global-hub
# Wait: multicluster-global-hub-operator-rh.* Succeeded
#       postgresoperator.* Succeeded

oc get mgh -n multicluster-global-hub
# Expect: No resources found
```

Do **not** apply [global-hub-instance.yaml](./manifests/global-hub-instance.yaml) yet. The restored MGH from Velero should include:

```yaml
metadata:
  annotations:
    mgh-install-crunchy-operator: "true"
```

If the backup predates that annotation, patch MGH after restore.

Scale the GH **operator deployment to 0** only if it already exists and might reconcile before step 7.2 completes (optional on a truly empty namespace):

```bash
GH_NS=multicluster-global-hub
oc scale deployment multicluster-global-hub-operator -n "$GH_NS" --replicas=0 2>/dev/null || true
```

### 7.1.1 Restore passive credentials only (Path B)

Run this after §7.1 when the pgBackRest Secret was **labeled on the backup hub** (§2.1). It restores the Secret (and other passive credentials) **without** running the full passive **resources** restore yet.

Apply a passive [Restore](../../config/samples/cluster_v1beta1_restore_passive.yaml) CR with **`veleroResourcesBackupName: skip`** so only the credentials Velero restore runs (cluster-backup-operator restores **Credentials** before **Resources** when both are set; `skip` avoids MGH and other CRs until §7.2 completes):

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm-passive-creds-only
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: None
  veleroManagedClustersBackupName: skip
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: skip
```

Wait until the Restore CR is **Enabled** (or Finished) and the Velero credentials restore completes, then verify the Secret:

```bash
GH_NS=multicluster-global-hub
oc get secret multicluster-global-hub-pgbackrest-s3 -n "$GH_NS"
```

If the Secret is missing, the backup hub did not label it before the credentials snapshot (§2.1), or the backup is too old — use **Path A** and run the §7.2 secret script instead.

**Alternative:** one-off Velero CLI restore from the latest `acm-credentials-schedule` backup into `multicluster-global-hub` (same effect; you manage filters yourself).

### 7.2 Restore Postgres from S3 (before passive resources / MGH)

**Old hub:** stop archiving to the source `repo2-path` (shutdown `PostgresCluster` or decommission hub).

**S3 Secret on this hub** — use **one** of:

| Situation | Action |
|-----------|--------|
| Path **B** and Secret present after §7.1.1 | Skip `global-hub-postgres-pgbackrest-s3-secret.sh` |
| Path **A**, or Secret missing | Run the script |

```bash
# Path A only (or Path B fallback):
manifests/global-hub-postgres-pgbackrest-s3-secret.sh
```

Edit [global-hub-postgres-restore-from-s3.yaml](./manifests/global-hub-postgres-restore-from-s3.yaml):

- `dataSource.pgbackrest.global.repo2-path` — **source** hub prefix (where backups were written).
- `spec.backups.pgbackrest.global.repo2-path` — **new** prefix on this hub after cutover (default `repo2-hub-b`).

Apply (creates `PostgresCluster/postgres` with restored `hoh`; GH operator has **not** created an empty cluster because MGH is absent):

```bash
oc apply -f manifests/global-hub-postgres-restore-from-s3.yaml
oc get postgrescluster postgres -n multicluster-global-hub -w
```

Immediately confirm **`dataSource`** was applied (empty means restore will **not** happen — see §7.6):

```bash
oc get postgrescluster postgres -n multicluster-global-hub \
  -o jsonpath='dataSource.repo2-path={.spec.dataSource.pgbackrest.global.repo2-path}{"\n"}'
```

Verify:

```bash
GH_NS=multicluster-global-hub
PRIMARY=$(oc get pods -n "$GH_NS" \
  -l postgres-operator.crunchydata.com/cluster=postgres,postgres-operator.crunchydata.com/role=master \
  -o name | head -1)
oc exec -n "$GH_NS" "${PRIMARY#pod/}" -c database -- \
  psql -U postgres -d hoh -c "SELECT count(*), max(updated_at) FROM local_spec.policies;"
```

Confirm **`guest`** user exists (`postgres-pguser-guest` Secret) — required when the GH operator starts after MGH restore.

### 7.3 ACM cluster-backup Restore (Velero passive resources)

Run the passive **resources** restore **after** §7.2 succeeds.

| Path | Restore CR |
|------|------------|
| **A** | Full passive sample: `veleroCredentialsBackupName: latest` and `veleroResourcesBackupName: latest` ([restore_passive.yaml](../../config/samples/cluster_v1beta1_restore_passive.yaml)) |
| **B** | Edit the §7.1.1 Restore (or create a new one): set `veleroResourcesBackupName: latest` (keep `veleroManagedClustersBackupName: skip` until activation). Credentials are already restored — reconcile may no-op credentials or refresh; that is OK |

See [cluster-backup-operator README](https://github.com/stolostron/cluster-backup-operator/blob/main/README.md) and [ARCHITECTURE](../ARCHITECTURE.md).

**Exclude or skip restoring** the Crunchy operand so Velero does not replace the restored database:

- Prefer **partial restore** / resource filters that **omit** `postgresclusters.postgres-operator.crunchydata.com/postgres` in `multicluster-global-hub`, **or**
- Restore all hub resources, then **delete** any Velero-recreated empty `PostgresCluster` and **re-apply** [global-hub-postgres-restore-from-s3.yaml](./manifests/global-hub-postgres-restore-from-s3.yaml) only if you must (destructive — avoid if §7.2 already completed).

Velero should restore at minimum:

- `MulticlusterGlobalHub` (with `mgh-install-crunchy-operator: "true"`)
- Kafka / Strimzi CRs and secrets in `multicluster-global-hub`
- GH agent, routes, configmaps — per your passive backup selection

Velero does **not** restore `hoh` rows; that is why §7.2 runs first.

### 7.4 After ACM Restore

```bash
oc scale deployment multicluster-global-hub-operator -n multicluster-global-hub --replicas=1
oc get mgh -n multicluster-global-hub
oc get deploy -n multicluster-global-hub | grep -E 'manager|grafana'
```

1. **Re-apply §3** if `PostgresCluster` backups reverted to repo1-only.
2. Wait for MGH **Ready**; manager and Grafana deploy from the operator.
3. Expect agent/manager to **re-sync** live Policy CRs into `hoh` (soft-delete restored rows not on the hub) — see §5.

**PITR:** Uncomment `dataSource.pgbackrest.options` in the restore manifest before §7.2 apply ([Crunchy PITR](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/disaster-recovery/#perform-a-point-in-time-recovery-pitr)).

### 7.5 In-place restore (alternative)

If `PostgresCluster` already exists on the passive hub and you cannot delete it, use **Path B** from a prior revision: `spec.backups.pgbackrest.restore` + `pgbackrest-restore` annotation with **repo2** only. Prefer §7.2 on a greenfield hub.

### 7.6 Debug checklist: passive hub restore — data / policies not showing

Use when §7.2 “succeeded” in `oc apply` but **`hoh` is empty**, Grafana has no history, or S3 only shows a **new** prefix on hub B (not the source hub’s backup set). Replace `GH_NS`, bucket, and paths with yours.

**0. Confirm cluster context**

```bash
oc config current-context
oc get nodes -o jsonpath='{.items[0].metadata.name}{"\n"}'   # sanity-check this is hub B, not hub A
```

**1. `dataSource` must exist on the PostgresCluster (smoking gun)**

`spec.dataSource.pgbackrest` is applied **only at create time**. If the cluster already existed (GH operator, Velero, or an earlier install), `oc apply` of [global-hub-postgres-restore-from-s3.yaml](./manifests/global-hub-postgres-restore-from-s3.yaml) **does not** retroactively restore from S3.

```bash
GH_NS=multicluster-global-hub
oc get postgrescluster postgres -n "$GH_NS" -o jsonpath='dataSource.repo2-path={.spec.dataSource.pgbackrest.global.repo2-path}{"\n"}'
```

| Result | Meaning |
|--------|---------|
| **Empty / blank** | Postgres was **never** bootstrapped from S3 Path A — you have an empty or hub-A-shaped cluster, not a restore |
| **`.../hub-1-repo2`** (or your **source** prefix) | Restore manifest was used at **create** — continue below |

**Fix when `dataSource` is missing:** delete `PostgresCluster/postgres` (and its PVCs if you need a clean PGDATA), ensure **no `MulticlusterGlobalHub`** (or GH operator scaled to **0**), then **create** from the restore YAML once. Do **not** rely on merge-patch alone.

**2. Two `repo2-path` values — do not swap them**

| Field | Must point to |
|-------|----------------|
| `spec.dataSource.pgbackrest.global.repo2-path` | **Source** hub S3 prefix (e.g. `.../hub-1-repo2`) |
| `spec.backups.pgbackrest.global.repo2-path` | **This** hub’s **new** prefix (e.g. `.../hub-b-repo-2`) |

If both are the same, or `dataSource` points at hub B’s empty prefix, restore reads the wrong repo.

```bash
oc get postgrescluster postgres -n "$GH_NS" -o yaml | grep -E 'dataSource:|repo2-path' -A1
```

**3. Postgres actually running (not shut down)**

```bash
oc get postgrescluster postgres -n "$GH_NS" -o jsonpath='shutdown={.spec.shutdown}{"\n"}'
oc get pods -n "$GH_NS" -l postgres-operator.crunchydata.com/cluster=postgres
oc get sts -n "$GH_NS" | grep postgres
```

| Observation | Action |
|-------------|--------|
| `shutdown=true`, STS **0/0** | Patch `spec.shutdown: false` and wait for primary **4/4** before `psql` or UI checks |
| No `postgres-pgha1-*` pods | Restore init failed or cluster shut down — check events and restore Job logs (step 5) |

**4. Order: MGH / Velero vs Postgres**

```bash
oc get mgh -n "$GH_NS"
```

| Observation | Typical problem |
|-------------|-----------------|
| **MGH present** before §7.2 completed | GH operator may have created an **empty** `PostgresCluster` **without** `dataSource` — delete and recreate per step 1 |
| Velero **Restore** ran **before** Postgres S3 bootstrap | Velero does **not** restore `hoh` rows; empty DB or wrong CR — redo §7.2, exclude `PostgresCluster` from Velero (§7.3) |

**5. Restore / init Jobs and events**

On first create with `dataSource.pgbackrest`, PGO runs pgBackRest **restore** (not a normal backup Job name only):

```bash
oc get jobs -n "$GH_NS" --sort-by=.metadata.creationTimestamp | grep -iE 'postgres|restore|pgbackrest'
oc get events -n "$GH_NS" --sort-by='.lastTimestamp' | grep -iE 'postgres|restore|pgbackrest' | tail -30
```

Inspect the latest **Failed** Job:

```bash
JOB=$(oc get jobs -n "$GH_NS" --sort-by=.metadata.creationTimestamp -o name | grep postgres | tail -1)
oc logs -n "$GH_NS" "$JOB" --all-containers | tail -40
```

Look for wrong `repo2-path`, S3 **403**, missing `backup.info` on the **source** prefix, or stanza errors (see §4.4).

**6. Authoritative: row counts in `hoh`**

```bash
PRIMARY=$(oc get pods -n "$GH_NS" \
  -l postgres-operator.crunchydata.com/cluster=postgres,postgres-operator.crunchydata.com/role=master \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$PRIMARY" ] && oc exec -n "$GH_NS" "$PRIMARY" -c database -- \
  psql -U postgres -d hoh -c "SELECT count(*) AS policies FROM local_spec.policies;"
```

| `policies` count | Likely cause |
|------------------|--------------|
| **0** | Empty DB — no S3 restore, or restore from empty/wrong prefix |
| **> 0** | Postgres restore OK — if UI still empty, check MGH/manager/agent (§7.4), not pgBackRest |

**7. S3: source vs hub-B write prefix**

```bash
export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
export AWS_DEFAULT_REGION=us-east-2

SOURCE_PREFIX=pgbackrest/multicluster-global-hub/postgres/hub-1-repo2   # edit
TARGET_PREFIX=pgbackrest/multicluster-global-hub/postgres/hub-b-repo-2    # edit

aws s3 ls "s3://YOUR_S3_BUCKET/${SOURCE_PREFIX}/backup/db/" 
aws s3 ls "s3://YOUR_S3_BUCKET/${TARGET_PREFIX}/backup/db/"
```

| S3 pattern | Meaning |
|------------|---------|
| **Source** has `20261030-*F/` (or similar) **before** restore | Good — hub A backups exist |
| **Target** only has **new** backups **after** hub B install, source unchanged | Hub B **backed up its own empty DB** to the target prefix — **not** a restore from hub A |
| Source `backup/db/` empty | Fix hub A backups first (§4–§4.4), then redo §7.2 |

**8. After ACM Restore — data “disappears” or policies vanish**

Manager **re-sync** can soft-delete `local_spec.policies` rows that have no Policy CR on the hub (§5). That is **after** a good Postgres restore. Confirm step 6 **before** Velero restore; if counts drop **after** MGH/manager start, compare Policy CRs vs Postgres.

**9. Greenfield redo (destructive summary)**

Only when step 1 shows missing `dataSource` or wrong order:

1. Scale GH operator to **0**; pause or remove MGH if it keeps reconciling empty Postgres.
2. Delete `PostgresCluster/postgres` and PVCs for a clean PGDATA.
3. Confirm `oc get mgh` absent (or operator scaled down).
4. Apply S3 Secret; edit restore YAML paths; **`oc apply`** restore manifest **once**.
5. Wait for primary Ready; run step **6** (`policies` > 0).
6. ACM Velero restore **excluding** `PostgresCluster/postgres` (§7.3).
7. Scale operator up; re-apply §3 backups on hub B’s **target** prefix only.

---

## 8. Reference: `dataSource.pgbackrest` fragment

On create only; `repo` is a **single** object (not `repos`):

```yaml
spec:
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: multicluster-global-hub-pgbackrest-s3
      global:
        repo2-path: /pgbackrest/multicluster-global-hub/postgres/repo2
      repo:
        name: repo2
        s3:
          bucket: YOUR_S3_BUCKET
          endpoint: s3.us-east-2.amazonaws.com
          region: us-east-2
```

See [crunchy-pg-pgbackrest-lab.md](./crunchy-pg-pgbackrest-lab.md) §7 for lab S3 patterns.

---

## Operator / upgrade notes

- The Global Hub operator **creates** `PostgresCluster` with **PVC `repo1` only** when MGH appears; it does **not** configure S3. Apply §3 for **S3-only** schedules; re-apply after Velero restore if needed.
- Without MGH, the operator does **not** create `PostgresCluster` — use §7.2 for passive hub bootstrap.
- Database name for GH remains **`hoh`**.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `repo2-retention-full` not set WARN in backup logs | Harmless; set `spec.backups.pgbackrest.global.repo2-retention-full` (+ optional `repo2-retention-full-type`) — §3 |
| Backup job fails S3 auth | Secret keys must be `repo2-s3-key` / `repo2-s3-key-secret`; repo name in spec must be `repo2` |
| Annotate succeeds but **no new Job** | `spec.shutdown: true` or repo-host not ready (§6 steps 1–2); and/or missing `spec.backups.pgbackrest.manual` with `repoName: repo2` (§4) |
| `PGBackRestManualBackupSuccessful` but S3 empty | Job may have used **`--repo=1`** (PVC) — §6 step 5 |
| `repo2: error (no valid backups)` | Run manual **full** to repo2 (§4); WAL may still archive — §6 step 6 |
| `ERROR [055] backup.info` / stanza-create hint in Job log | Repo2 not on S3 yet — §6 steps 6–7, then §4 manual full; incr cron before first full causes this |
| `repo2: error (missing stanza path)` on repo-host | §6 step 7 `stanza-create`; ignore `stanzaCreated: true` on CR until `pgbackrest info --repo=2` is OK |
| Repo2 CronJobs `suspend=true`, never scheduled | Cluster shut down or repo-host not ready — §6 steps 1–4 |
| Only repo1 lines in `pgbackrest info` | Re-apply §3 S3-only patch; confirm merge replaced `repos` |
| S3 `ls` empty | Wrong prefix (read from cluster — §6 step 8); IAM; or steps 1–7 not done |
| S3 has `archive/` + tiny `backup.info` only | Stanza OK; run §4 manual **full** for restorable backup sets |
| Velero restore replaced Postgres | Exclude `PostgresCluster/postgres` from restore; redo §7.2 if empty DB |
| New hub empty `hoh` after install | Wrong order — Postgres restore (§7.2) must run **before** ACM Restore |
| `oc apply` restore YAML but empty `hoh` | **`spec.dataSource` empty** on live CR — recreate PostgresCluster; `dataSource` not patchable — §7.6 step 1 |
| S3 **hub-b** prefix has backups, UI empty | May be **new** backups of empty DB; check **source** prefix + `dataSource` path — §7.6 step 7 |
| Policies in Postgres then gone after MGH | Manager resync vs restored rows — §7.6 step 8, §5 |
| Postgres `shutdown=true` | No pods — patch `shutdown: false` — §7.6 step 3 |
| No Grafana route; `postgres-pguser-guest is nil` | Add `spec.users` entry `guest` on `PostgresCluster` (restore manifest); wait for Secret; operator reconciles MGH |
| Restore job S3 403 / no backups | Same Secret keys, `repo2-path`, bucket/region as source; confirm `aws s3 ls` on backup/ |
| Passive hub: no pgBackRest Secret after restore | Secret not labeled on backup hub before credentials backup (§2.1); use §7.2 secret script (Path A) |
| Path B: MGH appeared before `hoh` restore | Ran full passive restore before §7.2 — use §7.1.1 credentials-only first; redo Postgres per §7.6 |
| `spec.instances: Required value` on apply | Use `spec.instances` in restore manifest (not `instanceSets`); see `global-hub-postgres-restore-from-s3.yaml` |

For a step-by-step flow, use **§4.4 Debug checklist**.

---

## Cleanup (S3 repo only)

1. Edit `PostgresCluster` and remove `repo2`, `global.repo2-path`, schedules, and the `configuration` secret reference (GH default repo1 returns if you reinstall MGH without §3).
2. Delete Secret `multicluster-global-hub-pgbackrest-s3` if unused.
3. Optionally delete S3 prefix contents in the bucket (data destruction — confirm bucket/path first).
