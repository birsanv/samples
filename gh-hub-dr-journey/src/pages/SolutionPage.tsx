import type { SolutionPhase } from "../app/router";
import { href } from "../app/router";
import { DocLink } from "../content/DocLink";
import { docs } from "../content/docLinks";

const phaseOrder: SolutionPhase[] = [
  "active",
  "passive-prep",
  "postgres",
  "passive-velero",
  "activation",
];

const phaseTitles: Record<SolutionPhase, string> = {
  active: "Active hub — backup & S3",
  "passive-prep": "Passive hub — operators & creds",
  postgres: "Postgres restore (hoh)",
  "passive-velero": "Passive Velero (MGH, …)",
  activation: "MC activation",
};

type Props = {
  phase: SolutionPhase;
  path: "a" | "b";
  completed: Set<SolutionPhase>;
  oldHubDown: boolean;
  onPhase: (p: SolutionPhase) => void;
  onPath: (p: "a" | "b") => void;
  onComplete: (p: SolutionPhase) => void;
  onToggleOldHub: () => void;
  onReset: () => void;
};

export function SolutionPage({
  phase,
  path,
  completed,
  oldHubDown,
  onPhase,
  onPath,
  onComplete,
  onToggleOldHub,
  onReset,
}: Props) {
  const phaseIndex = phaseOrder.indexOf(phase);
  return (
    <main className="page solution-page" id="main-content" tabIndex={-1}>
      <h1>Solution example — hub-a → hub-b</h1>
      <p className="lead">
        Simulated cutover: <code>hub-a</code> (active) to <code>hub-b</code>{" "}
        (passive). Mark steps done to unlock the next phase. Refresh resets
        progress.
      </p>
      <div style={{ display: "flex", gap: "0.5rem", marginBottom: "1rem" }}>
        <button
          type="button"
          className={`btn secondary ${path === "a" ? "selected" : ""}`}
          onClick={() => onPath("a")}
        >
          Path A
        </button>
        <button
          type="button"
          className={`btn secondary ${path === "b" ? "selected" : ""}`}
          onClick={() => onPath("b")}
        >
          Path B
        </button>
        <button type="button" className="btn secondary" onClick={onReset}>
          Reset simulation
        </button>
      </div>
      <nav className="phase-nav" aria-label="Phases">
        {phaseOrder.map((p, i) => {
          const done = completed.has(p);
          const locked = i > 0 && !completed.has(phaseOrder[i - 1]);
          const current = p === phase;
          return (
            <button
              key={p}
              type="button"
              className={`phase-pill ${done ? "done" : ""} ${current ? "current" : ""} ${locked ? "locked" : ""}`}
              disabled={locked}
              onClick={() => !locked && onPhase(p)}
            >
              {done ? "✓ " : ""}
              {phaseTitles[p]}
            </button>
          );
        })}
      </nav>
      <PhaseBody
        phase={phase}
        path={path}
        phaseIndex={phaseIndex}
        oldHubDown={oldHubDown}
        onComplete={onComplete}
        onToggleOldHub={onToggleOldHub}
      />
      <PhaseDocLinks phase={phase} />
    </main>
  );
}

function PhaseBody({
  phase,
  path,
  phaseIndex,
  oldHubDown,
  onComplete,
  onToggleOldHub,
}: {
  phase: SolutionPhase;
  path: "a" | "b";
  phaseIndex: number;
  oldHubDown: boolean;
  onComplete: (p: SolutionPhase) => void;
  onToggleOldHub: () => void;
}) {
  const tasks = phaseTasks(phase, path);
  return (
    <div className="sim-panel">
      <h2>{phaseTitles[phase]}</h2>
      <ul className="checklist">
        {tasks.map((t) => (
          <li key={t}>
            <span>{t}</span>
          </li>
        ))}
      </ul>
      {phase === "activation" && (
        <label style={{ display: "block", margin: "0.75rem 0" }}>
          <input type="checkbox" checked={oldHubDown} onChange={onToggleOldHub} />{" "}
          Confirm <strong>hub-a</strong> is shut down (required for activation)
        </label>
      )}
      {phase === "activation" && !oldHubDown && (
        <div className="alert warn">
          Activation with <code>veleroManagedClustersBackupName: latest</code> is
          blocked until the old hub is down.
        </div>
      )}
      <button
        type="button"
        className="btn"
        disabled={phase === "activation" && !oldHubDown}
        onClick={() => onComplete(phase)}
      >
        Mark phase complete
      </button>
      {phaseIndex < phaseOrder.length - 1 && (
        <p style={{ fontSize: "0.85rem", color: "var(--muted)", marginTop: "1rem" }}>
          Next: {phaseTitles[phaseOrder[phaseIndex + 1]]}. See also{" "}
          <a href={href({ page: "choices", path })}>DR paths</a>.
        </p>
      )}
    </div>
  );
}

function PhaseDocLinks({ phase }: { phase: SolutionPhase }) {
  const byPhase: Record<SolutionPhase, { label: string; href: string }[]> = {
    active: [
      { label: "BackupSchedule sample", href: docs.sampleBackupSchedule },
      { label: "OADP DPA", href: docs.oadpDpa },
      { label: "GH playbook §2–4", href: docs.playbookPgbackrestS3 },
    ],
    "passive-prep": [
      { label: "Operators-only manifest", href: docs.manifestOperatorsOnly },
      { label: "Passive restore sample", href: docs.sampleRestorePassive },
    ],
    postgres: [
      { label: "Postgres restore YAML", href: docs.manifestRestoreFromS3 },
      { label: "Playbook §7.2", href: docs.playbookPgbackrestS3 },
    ],
    "passive-velero": [
      { label: "restore_passive.yaml", href: docs.sampleRestorePassive },
      { label: "Playbook §7.3", href: docs.playbookPgbackrestS3 },
    ],
    activation: [
      { label: "restore_passive_activate.yaml", href: docs.sampleRestorePassiveActivate },
      { label: "Activation data (README)", href: docs.cbActivation },
    ],
  };
  return (
    <section className="card" style={{ marginTop: "1rem" }}>
      <h3>Docs for this phase</h3>
      <ul className="checklist">
        {byPhase[phase].map((l) => (
          <li key={l.href}>
            <DocLink href={l.href}>{l.label}</DocLink>
          </li>
        ))}
      </ul>
    </section>
  );
}

function phaseTasks(phase: SolutionPhase, path: "a" | "b"): string[] {
  switch (phase) {
    case "active":
      return [
        "MCH: enable cluster-backup component → OADP + cluster-backup-operator in open-cluster-management-backup",
        "Secret + DataProtectionApplication → BackupStorageLocation Available (bucket/prefix)",
        "BackupSchedule Enabled; five Velero schedules producing backups (no BackupCollision)",
        "Then Global Hub: §2–§3 pgBackRest repo2 to S3 (hub-1-repo2 prefix)",
        path === "b"
          ? "Label pgBackRest secret for acm-credentials-schedule"
          : "Optional: label pgBackRest secret for Path B",
        "Verify pgbackrest info + aws s3 ls on repo2 prefix",
      ];
    case "passive-prep":
      return path === "b"
        ? [
            "hub-b: operators only (GH + Crunchy CSVs)",
            "Restore CR: credentials latest, resources skip",
            "Verify multicluster-global-hub-pgbackrest-s3 restored",
          ]
        : [
            "hub-b: operators only (GH + Crunchy CSVs)",
            "No MGH; GH operator scaled down if needed",
          ];
    case "postgres":
      return path === "b"
        ? [
            "Skip secret script if creds restore succeeded",
            "Stop repo2 writes on hub-a (shutdown PostgresCluster)",
            "Apply PostgresCluster dataSource from hub-1-repo2",
            "Confirm hoh has policy rows before MGH restore",
          ]
        : [
            "Run global-hub-postgres-pgbackrest-s3-secret.sh",
            "Stop repo2 writes on hub-a",
            "Apply PostgresCluster restore manifest",
            "Confirm guest user secret and hoh data",
          ];
    case "passive-velero":
      return [
        "Restore CR: veleroManagedClustersBackupName skip",
        "veleroResourcesBackupName latest (Path B continues partial restore)",
        "Exclude or fix PostgresCluster — do not replace restored DB",
        "MGH with mgh-install-crunchy-operator: true",
        "Re-apply S3-only repo2 patch if operand reverted to repo1",
      ];
    case "activation":
      return [
        "BackupSchedule paused or passive hub only",
        "Edit Restore: veleroManagedClustersBackupName latest",
        "Validate managed clusters on hub-b",
        "Grafana/manager healthy when Postgres not shutdown",
      ];
  }
}
