/** Upstream documentation URLs (stolostron / OADP). */
/** Playbooks live in ../global-hub-postgres-dr-playbooks (set PLAYBOOK_GITHUB_BASE after push to your private repo). */
const PLAYBOOK_GITHUB_BASE =
  "https://github.com/birsanv/samples/blob/main/global-hub-postgres-dr-playbooks";

export const docs = {
  cbReadme:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md",
  cbArch:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/docs/ARCHITECTURE.md",
  cbMchBackup:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#cluster-backup-and-restore-flow",
  cbScheduling:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#scheduling-a-cluster-backup",
  cbPassive:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#passive-data",
  cbActivation:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#managed-clusters-activation-data",
  cbCollision:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#backup-collision",
  cbExtendingBackup:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/README.md#extending-backup-data",
  sampleBackupSchedule:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_backupschedule.yaml",
  sampleRestorePassive:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_restore_passive.yaml",
  sampleRestorePassiveActivate:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_restore_passive_activate.yaml",
  sampleRestorePassiveSync:
    "https://github.com/stolostron/cluster-backup-operator/blob/main/config/samples/cluster_v1beta1_restore_passive_sync.yaml",
  playbookPgbackrestS3: `${PLAYBOOK_GITHUB_BASE}/global-hub-postgres-pgbackrest-s3.md`,
  manifestOperatorsOnly: `${PLAYBOOK_GITHUB_BASE}/manifests/global-hub-operators-only.yaml`,
  manifestRestoreFromS3: `${PLAYBOOK_GITHUB_BASE}/manifests/global-hub-postgres-restore-from-s3.yaml`,
  manifestPgbackrestS3SecretSh: `${PLAYBOOK_GITHUB_BASE}/manifests/global-hub-postgres-pgbackrest-s3-secret.sh`,
  oadpInstall:
    "https://github.com/openshift/oadp-operator/blob/master/docs/install_olm.md",
  oadpSecret:
    "https://github.com/openshift/oadp-operator/blob/master/docs/install_olm.md#create-credentials-secret",
  oadpDpa:
    "https://github.com/openshift/oadp-operator/blob/master/docs/install_olm.md#create-the-dataprotectionapplication-custom-resource",
  rhAcmBusinessContinuity:
    "https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.16/html/business_continuity/index",
  mchClusterBackupToggle:
    "https://github.com/stolostron/multiclusterhub-operator/blob/main/pkg/templates/charts/toggle/cluster-backup/templates/hub-backup-pod.yaml",
  crunchyPgBackRestS3:
    "https://access.crunchydata.com/documentation/postgres-operator/latest/tutorials/backups-disaster-recovery/disaster-recovery-from-s3.html",
} as const;
