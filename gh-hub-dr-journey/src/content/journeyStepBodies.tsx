import type { ReactNode } from "react";
import { DocLink } from "./DocLink";
import { docs } from "./docLinks";

export type JourneyStepBody = {
  summary: ReactNode;
  steps?: ReactNode[];
  details: ReactNode;
};

export const journeyStepBodies: Record<string, JourneyStepBody> = {
  "acm-backup": {
    summary:
      "Turn on the MCH backup component, connect OADP to object storage, then create a BackupSchedule so Velero runs on a cadence.",
    steps: [
      <>
        Enable the <code>cluster-backup</code> component on{" "}
        <DocLink href={docs.cbMchBackup}>MultiClusterHub</DocLink>. MCH installs
        OADP and cluster-backup-operator into{" "}
        <code>open-cluster-management-backup</code> (see{" "}
        <DocLink href={docs.cbReadme}>cluster-backup-operator README</DocLink>).
      </>,
      <>
        <DocLink href={docs.oadpInstall}>OADP</DocLink> owns Velero: its
        controller installs Velero and BackupStorageLocation. Velero runs backup
        jobs. Optional validation:{" "}
        <DocLink href={docs.mchClusterBackupToggle}>
          hub-backup validation Policy
        </DocLink>
        .
      </>,
      <>
        Create a credentials{" "}
        <DocLink href={docs.oadpSecret}>Secret for cloud storage</DocLink> in
        the backup namespace (S3/Azure/GCP). DPA references this secret — not the
        Global Hub pgBackRest secret.
      </>,
      <>
        Create a{" "}
        <DocLink href={docs.oadpDpa}>DataProtectionApplication</DocLink> that
        points at that Secret and sets bucket/region/prefix (BSL must be
        Available).
      </>,
      <>
        Create a{" "}
        <DocLink href={docs.sampleBackupSchedule}>BackupSchedule</DocLink> (
        <DocLink href={docs.cbScheduling}>scheduling docs</DocLink>). The
        operator creates five Velero Schedule CRs (credentials, resources,
        generic, managed-clusters, validation).
      </>,
      <>
        Verify BackupSchedule is Enabled — not{" "}
        <DocLink href={docs.cbCollision}>BackupCollision</DocLink> or
        FailedValidation. Confirm backups in object storage. See{" "}
        <DocLink href={docs.rhAcmBusinessContinuity}>
          ACM business continuity
        </DocLink>
        .
      </>,
    ],
    details: (
      <>
        More: <DocLink href={docs.cbArch}>ARCHITECTURE.md</DocLink>. Restore
        timing and passive vs activation belong in steps 6–7 here, not in backup
        setup.
      </>
    ),
  },
  "gh-s3": {
    summary:
      "pgBackRest S3 secret, S3-only repo2 schedules, backups under a dedicated prefix (not Velero hub prefix).",
    details: (
      <>
        <DocLink href={docs.playbookPgbackrestS3}>
          Playbook §2–§4
        </DocLink>
        :{" "}
        <DocLink href={docs.manifestPgbackrestS3SecretSh}>
          pgBackRest S3 secret script
        </DocLink>
        , patch <code>PostgresCluster</code> for repo2, verify{" "}
        <code>pgbackrest info</code> and S3 listing. Crunchy:{" "}
        <DocLink href={docs.crunchyPgBackRestS3}>
          disaster recovery from S3
        </DocLink>
        .
      </>
    ),
  },
  "label-secret": {
    summary:
      "cluster.open-cluster-management.io/backup on the S3 secret (not cluster-activation) for credentials schedule.",
    details: (
      <>
        <DocLink href={docs.cbExtendingBackup}>Extending backup data</DocLink>{" "}
        and playbook{" "}
        <DocLink href={docs.playbookPgbackrestS3}>§2.1</DocLink>. Passive
        credentials restore before Postgres on hub B; label before the next
        credentials backup snapshot.
      </>
    ),
  },
  "passive-platform": {
    summary:
      "New OpenShift hub: ACM/OADP, GH + Crunchy operators only — no MulticlusterGlobalHub yet.",
    details: (
      <>
        Apply{" "}
        <DocLink href={docs.manifestOperatorsOnly}>
          global-hub-operators-only.yaml
        </DocLink>{" "}
        (playbook §7.1). On passive hub,{" "}
        <DocLink href={docs.oadpDpa}>DPA</DocLink> must reach the same backup
        storage as hub A. Scale GH operator to 0 only if needed until Postgres
        restore completes.
      </>
    ),
  },
  "postgres-restore": {
    summary:
      "PostgresCluster with dataSource.pgbackrest (source repo2-path) before MGH passive restore.",
    details: (
      <>
        Old hub: <code>spec.shutdown: true</code> or stop repo2 writes (playbook
        §7.2). Manifest:{" "}
        <DocLink href={docs.manifestRestoreFromS3}>
          global-hub-postgres-restore-from-s3.yaml
        </DocLink>
        . Path A: secret script; Path B: credentials restore first (
        <DocLink href={docs.playbookPgbackrestS3}>§7.1.1</DocLink>).
      </>
    ),
  },
  "passive-velero": {
    summary:
      "Restore CR with MC=skip; exclude PostgresCluster from replace. MGH, Kafka, agent CRs after hoh exists.",
    details: (
      <>
        Sample:{" "}
        <DocLink href={docs.sampleRestorePassive}>
          restore_passive.yaml
        </DocLink>{" "}
        (<DocLink href={docs.cbPassive}>passive data</DocLink>). Velero does
        not restore <code>hoh</code> rows — playbook{" "}
        <DocLink href={docs.playbookPgbackrestS3}>§7.2</DocLink> first.
        Re-apply S3-only patch if operand reverts to repo1 PVC.
      </>
    ),
  },
  activation: {
    summary: (
      <>
        Old hub down; <code>veleroManagedClustersBackupName: latest</code> on
        Restore.
      </>
    ),
    details: (
      <>
        <DocLink href={docs.sampleRestorePassiveActivate}>
          restore_passive_activate.yaml
        </DocLink>{" "}
        and <DocLink href={docs.cbActivation}>activation data</DocLink>. Hive
        clusters reconnect; imports need MSA/auto-import. Sync option:{" "}
        <DocLink href={docs.sampleRestorePassiveSync}>
          restore_passive_sync.yaml
        </DocLink>
        . MGH with <code>cluster-activation</code> label — plan restore timing
        explicitly.
      </>
    ),
  },
};
