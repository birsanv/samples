# Crunchy Postgres + pgBackRest lab playbook

Hands-on lab on an OpenShift hub with **Crunchy Postgres for Kubernetes (PGO)** already installed. Mirrors the Global Hub pattern (**repo1 on PVC**) and adds **manual backup** and **DR restore** into a second `PostgresCluster`.

**Prerequisites**

- PGO CSV `Succeeded` (e.g. `postgresoperator.v5.8.x` in `openshift-operators`)
- `kubectl` / `oc` logged into the hub
- Default storage class (this playbook uses `gp3-csi`; change if yours differs)

**Manifests in this repo**

- `manifests/postgres-lab-primary.yaml`
- `manifests/postgres-lab-dr.yaml`

---

## 1. Deploy primary cluster

```bash
kubectl apply -f manifests/postgres-lab-primary.yaml
kubectl -n postgres-lab get postgrescluster pg-playground -w
kubectl -n postgres-lab get pods
```

Wait until `PostgresCluster` status is **Ready** and the primary pod is `Running`.

---

## 2. Connect and load sample data

Credentials (user `app`, database `playground`):

```bash
export PGUSER=$(kubectl -n postgres-lab get secret pg-playground-pguser-app -o jsonpath='{.data.user}' | base64 -d)
export PGPASSWORD=$(kubectl -n postgres-lab get secret pg-playground-pguser-app -o jsonpath='{.data.password}' | base64 -d)
kubectl -n postgres-lab port-forward svc/pg-playground-primary 5432:5432
```

In another terminal (port-forward):

```bash
export PGUSER=app
export PGPASSWORD='<paste from above>'
psql -h localhost -U "$PGUSER" -d playground -c "
  CREATE TABLE IF NOT EXISTS dr_demo (id serial PRIMARY KEY, note text, ts timestamptz default now());
  INSERT INTO dr_demo (note) VALUES ('before-backup');
  SELECT * FROM dr_demo;
"
```

**Alternative (no port-forward):** run `psql` inside the primary pod as the `postgres` OS user (local socket):

```bash
PRIMARY=$(kubectl -n postgres-lab get pods -l postgres-operator.crunchydata.com/cluster=pg-playground,postgres-operator.crunchydata.com/data=postgres -o name | head -1)
kubectl -n postgres-lab exec "$PRIMARY" -c database -- psql -U postgres -d playground -c "SELECT 1"
```

---

## 3. Manual pgBackRest full backup

PGO runs a one-off backup when you annotate the cluster ([Crunchy backup management](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/backup-management/)):

```bash
kubectl annotate -n postgres-lab postgrescluster pg-playground \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date -Iseconds)" --overwrite

kubectl -n postgres-lab get jobs -w
kubectl -n postgres-lab get pvc | grep -E 'pg-playground|repo'
```

After the backup job **Completes**, simulate data you want to “lose” on restore:

```bash
psql -h localhost -U "$PGUSER" -d playground -c \
  "INSERT INTO dr_demo (note) VALUES ('after-backup-should-disappear');"
```

---

## 4. DR drill: restore into a new cluster (same hub)

```bash
kubectl apply -f manifests/postgres-lab-dr.yaml
kubectl -n postgres-lab get postgrescluster pg-playground-dr -w
```

Port-forward the DR cluster and verify rows:

```bash
kubectl -n postgres-lab port-forward svc/pg-playground-dr-primary 5433:5432
psql -h localhost -p 5433 -U "$PGUSER" -d playground -c "SELECT * FROM dr_demo ORDER BY id;"
```

Or from the DR pod:

```bash
DR=$(kubectl -n postgres-lab get pods -l postgres-operator.crunchydata.com/cluster=pg-playground-dr,postgres-operator.crunchydata.com/data=postgres -o name | head -1)
kubectl -n postgres-lab exec "$DR" -c database -- psql -U postgres -d playground -c "SELECT * FROM dr_demo ORDER BY id;"
```

Expected: **`before-backup`** present; **`after-backup-should-disappear`** absent (full restore from repo1).

### Optional: point-in-time restore (PITR)

After WAL is archived to repo1, you can add restore options on the DR cluster **before first start** (edit `postgres-lab-dr.yaml`):

```yaml
dataSource:
  postgresCluster:
    clusterName: pg-playground
    clusterNamespace: postgres-lab
    repoName: repo1
    options:
      - --type=time
      - --target=2026-10-26 20:00:00+00
```

Delete `pg-playground-dr` and re-apply if you need to change `dataSource`.

---

## 5. Inspect pgBackRest (optional)

```bash
PRIMARY=$(kubectl -n postgres-lab get pods -l postgres-operator.crunchydata.com/cluster=pg-playground,postgres-operator.crunchydata.com/role=master -o name | head -1)
kubectl -n postgres-lab exec -it "$PRIMARY" -c database -- pgbackrest info
```

---

## 6. Cleanup

```bash
kubectl delete -f manifests/postgres-lab-dr.yaml --ignore-not-found
kubectl delete -f manifests/postgres-lab-primary.yaml --ignore-not-found
# Namespace removes remaining PVCs once PostgresClusters are gone
kubectl delete namespace postgres-lab --ignore-not-found
```

---

## Relation to Global Hub and ACM DR

| This lab | Global Hub (`NewPostgresCluster`) | Passive-hub DR |
|----------|-----------------------------------|----------------|
| `repo1` on PVC | Same declarative spec | PVC on active hub only |
| PGO runs backup/restore | No pgBackRest CLI in GH Go code | Needs **off-cluster repo** (e.g. S3) + restore on hub B |
| `dataSource.postgresCluster` | Manual / drill | Target pattern for “new cluster from backup” |

See also: `docs/GLOBAL-HUB-PGBACKREST-AND-BACKUP-SUMMARY.md`, `docs/GLOBAL-HUB-POSTGRES-DR-SUMMARY-google-doc.html`.

---

## 7. S3 repo aligned with ACM DPA (same bucket as Velero BSL)

`postgres-lab-dr.yaml` archives pgBackRest **repo1** to the same AWS bucket/region as OADP `YOUR_DPA` (`YOUR_S3_BUCKET`, `us-east-2`), using a **dedicated** key prefix (`repo1-path`), not Velero’s `hub-a/` prefix.

Before applying the DR manifest:

```bash
manifests/postgres-lab-s3-secret.sh   # keys from ~/.aws/credentials
kubectl apply -f manifests/postgres-lab-dr.yaml
```

Restore still uses `dataSource.postgresCluster` (primary PVC `repo1`) in this lab. For passive-hub / cross-cluster DR, push backups from the primary to the same S3 repo, then bootstrap with `spec.dataSource.pgbackrest` per [Crunchy S3 DR](https://access.crunchydata.com/documentation/postgres-operator/v5/tutorial/backups/).

**Global Hub `PostgresCluster/postgres` (keep PVC repo1 + add S3 repo2):** [global-hub-postgres-pgbackrest-s3.md](./global-hub-postgres-pgbackrest-s3.md).

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| PostgresCluster not Ready | `kubectl -n postgres-lab describe postgrescluster <name>`; pod logs |
| Backup job fails | `kubectl -n postgres-lab logs job/<pgbackrest-job>` |
| DR cluster empty / wrong data | Confirm backup job completed; `pgbackrest info` on primary; `repoName` matches |
| PVC pending | `kubectl get sc`; set `storageClassName` in manifests |
