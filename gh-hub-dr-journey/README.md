# Global Hub active–passive DR journey

Interactive web app (same *shape* as [openshift-install-visualizations](https://github.com/mshort55/openshift-install-visualizations)) for teaching:

- ACM **passive** vs **managed-cluster activation** restores
- **Multicluster Global Hub** + **Postgres `hoh`** via **pgBackRest on S3** (Paths A/B from the sibling [global-hub-postgres-dr-playbooks](../global-hub-postgres-dr-playbooks/) folder)

**Four pages:** Journey map · DR paths · Prep & handoffs · Solution example (simulated hub-a → hub-b).

Nothing in this app connects to a cluster.

## Run locally (Node)

```bash
cd gh-hub-dr-journey
npm ci
npm run app
```

Open **http://localhost:5175**

## Run with Podman (no Node on the host)

```bash
podman machine start   # macOS, once per reboot

cd gh-hub-dr-journey
podman run --rm -it \
  -v "$PWD":/app:Z \
  -w /app \
  -p 5175:5175 \
  docker.io/library/node:22-bookworm \
  bash -lc 'npm ci && npm run app -- --host 0.0.0.0'
```

## Build static site

```bash
npm ci && npm run build
python3 -m http.server 8080 -d dist
```

Use hash URLs, e.g. `http://localhost:8080/#/solution?phase=postgres&path=b`

## Deep links

| URL | Page |
|-----|------|
| `#/journey` | Timeline |
| `#/choices?path=b` | DR path decisions |
| `#/prep` | S3 / OADP handoffs |
| `#/solution?phase=passive-prep&path=b` | Guided simulation |

## Upstream documentation (linked in the UI)

| Topic | URL |
|-------|-----|
| GH pgBackRest S3 playbook | [global-hub-postgres-pgbackrest-s3.md](../global-hub-postgres-dr-playbooks/global-hub-postgres-pgbackrest-s3.md) |
| cluster-backup-operator README | [README.md](https://github.com/stolostron/cluster-backup-operator/blob/main/README.md) |
| OADP install / DPA / secret | [install_olm.md](https://github.com/openshift/oadp-operator/blob/master/docs/install_olm.md) |
| ACM 2.16 business continuity | [Red Hat docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index) |
| BackupSchedule sample | [cluster_v1beta1_backupschedule.yaml](https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_backupschedule.yaml) |
| Passive / activation restore | [passive](https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_restore_passive.yaml) · [activate](https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_restore_passive_activate.yaml) |

## License

MIT (sample content; playbook references remain under their upstream repos).
