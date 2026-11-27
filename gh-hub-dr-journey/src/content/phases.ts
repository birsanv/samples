/** Journey timeline titles only; bodies live in journeyStepBodies.tsx */
export const journeySteps = [
  { id: "acm-backup", title: "ACM hub backup on the active hub" },
  { id: "gh-s3", title: "Global Hub Postgres → S3 (repo2)" },
  { id: "label-secret", title: "Label pgBackRest secret (Path B)" },
  { id: "passive-platform", title: "Passive hub platform" },
  { id: "postgres-restore", title: "Restore hoh from S3" },
  { id: "passive-velero", title: "ACM passive Velero restore" },
  { id: "activation", title: "Managed-cluster activation" },
] as const;

export const choiceOptions = [
  {
    id: "dr-path",
    label: "Passive Postgres secret",
    options: [
      {
        id: "a",
        name: "Path A — manual secret script",
        blurb: "Run global-hub-postgres-pgbackrest-s3-secret.sh on passive before apply restore manifest.",
      },
      {
        id: "b",
        name: "Path B — Velero credentials first",
        blurb:
          "Label secret on active hub; passive Restore with veleroResourcesBackupName: skip; then Postgres §7.2; then resources latest.",
      },
    ],
  },
  {
    id: "restore-cleanup",
    label: "cleanupBeforeRestore",
    options: [
      {
        id: "none",
        name: "None",
        blurb: "First passive restore on greenfield hub; minimal cleanup.",
      },
      {
        id: "cleanup",
        name: "CleanupRestored",
        blurb: "Re-restore on same hub; remove resources from prior restore not in current backup.",
      },
    ],
  },
  {
    id: "mc",
    label: "veleroManagedClustersBackupName",
    options: [
      {
        id: "skip",
        name: "skip (passive only)",
        blurb: "Clusters stay on active hub; use for DR drill or warm standby view.",
      },
      {
        id: "latest",
        name: "latest (activation)",
        blurb: "Only when old hub is shut down — dual management otherwise.",
      },
    ],
  },
  {
    id: "postgres-order",
    label: "MGH vs Postgres order",
    options: [
      {
        id: "postgres-first",
        name: "Postgres before MGH",
        blurb: "Required for GH — operator must not create empty PostgresCluster first.",
      },
      {
        id: "mgh-first",
        name: "MGH before Postgres",
        blurb: "Wrong for GH DR — leads to empty hoh and Grafana with no data.",
      },
    ],
  },
] as const;

export const prepHandoffs = [
  {
    id: "s3",
    title: "S3 bucket & IAM",
    owner: "Cloud / platform",
    need: "Separate prefixes: Velero BSL vs pgBackRest repo2-path (e.g. hub-a vs hub-b).",
  },
  {
    id: "oadp",
    title: "OADP on both hubs",
    owner: "Hub admin",
    need: "Passive hub can read backups from BSL; cluster-backup-operator installed for Restore CR.",
  },
  {
    id: "creds-backup",
    title: "Credentials schedule",
    owner: "ACM backup",
    need: "Secrets labeled cluster.open-cluster-management.io/backup (passive, not cluster-activation).",
  },
  {
    id: "shutdown",
    title: "Source Postgres shutdown",
    owner: "GH admin",
    need: "spec.shutdown: true or decommission before restore — no concurrent repo2-path writers.",
  },
] as const;
