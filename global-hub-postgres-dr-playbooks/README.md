# Global Hub Postgres DR playbooks

Playbooks and manifests for **Multicluster Global Hub** active–passive hub DR:

- **Velero / ACM** passive vs activation restore ([cluster-backup-operator](https://github.com/stolostron/cluster-backup-operator))
- **Crunchy PGO** `PostgresCluster/postgres` with **pgBackRest on S3** (`hoh` database)
- Passive hub bootstrap via `dataSource.pgbackrest` and optional Velero credentials **Path A / Path B**

## Start here

| Document | Description |
|----------|-------------|
| [global-hub-postgres-pgbackrest-s3.md](./global-hub-postgres-pgbackrest-s3.md) | Main runbook: S3-only pgBackRest + passive hub restore |
| [crunchy-pg-pgbackrest-lab.md](./crunchy-pg-pgbackrest-lab.md) | Isolated `postgres-lab` exercises (PVC + S3) |
| [manifests/](./manifests/) | YAML patches, restore manifest, secret helper scripts |

## Layout

Run commands from this directory (`global-hub-postgres-dr-playbooks/`):

```bash
cd global-hub-postgres-dr-playbooks
chmod +x manifests/*.sh
./manifests/global-hub-postgres-pgbackrest-s3-secret.sh
oc apply -f manifests/global-hub-postgres-restore-from-s3.yaml
```

## Related sample

Interactive flow: [../gh-hub-dr-journey/](../gh-hub-dr-journey/)

## Notes

- Manifests use placeholders (`YOUR_S3_BUCKET`, `~/.aws/credentials`) — set bucket, region, and paths before use.
- Intended for a **private** branch or personal repo; not part of upstream `stolostron/cluster-backup-operator`.