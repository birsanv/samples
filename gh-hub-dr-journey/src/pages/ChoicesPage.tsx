import { choiceOptions } from "../content/phases";
import { DocLink } from "../content/DocLink";
import { docs } from "../content/docLinks";

type Props = {
  path?: "a" | "b";
  selections: Record<string, string>;
  onSelect: (group: string, value: string) => void;
};

export function ChoicesPage({ path, selections, onSelect }: Props) {
  return (
    <main className="page choices-page" id="main-content" tabIndex={-1}>
      <h1>DR paths & restore choices</h1>
      <p className="lead">
        ACM passive vs activation split plus Global Hub Postgres ordering. Pick
        options to see highlighted recommendations (session only).
      </p>
      {path && (
        <div className="alert warn">
          Linked from solution example: Postgres secret{" "}
          <strong>Path {path.toUpperCase()}</strong>.
        </div>
      )}
      <motionChoices
        group={choiceOptions[0]}
        selected={selections["dr-path"] ?? path ?? "b"}
        onSelect={onSelect}
      />
      {choiceOptions.slice(1).map((group) => (
        <motionChoices
          key={group.id}
          group={group}
          selected={selections[group.id]}
          onSelect={onSelect}
        />
      ))}
      <motionWarning selections={selections} />
      <section className="card">
        <h2>Reference samples</h2>
        <ul className="checklist">
          <li>
            <DocLink href={docs.sampleRestorePassive}>Passive restore</DocLink>
          </li>
          <li>
            <DocLink href={docs.sampleRestorePassiveActivate}>
              Passive + activation
            </DocLink>
          </li>
          <li>
            <DocLink href={docs.playbookPgbackrestS3}>
              GH pgBackRest S3 playbook
            </DocLink>{" "}
            (Paths A/B §7.0)
          </li>
        </ul>
      </section>
    </main>
  );
}

function motionChoices({
  group,
  selected,
  onSelect,
}: {
  group: (typeof choiceOptions)[number];
  selected?: string;
  onSelect: (group: string, value: string) => void;
}) {
  return (
    <section className="card" style={{ marginBottom: "1rem" }}>
      <h2>{group.label}</h2>
      <div className="choice-grid">
        {group.options.map((opt) => (
          <button
            key={opt.id}
            type="button"
            className={`choice-option ${selected === opt.id ? "selected" : ""}`}
            onClick={() => onSelect(group.id, opt.id)}
          >
            <strong>{opt.name}</strong>
            <p>{opt.blurb}</p>
          </button>
        ))}
      </div>
    </section>
  );
}

function motionWarning({ selections }: { selections: Record<string, string> }) {
  const badOrder = selections["postgres-order"] === "mgh-first";
  const earlyMc = selections.mc === "latest";
  if (!badOrder && !earlyMc) return null;
  return (
    <div className="alert warn">
      {badOrder && (
        <p>
          <strong>MGH before Postgres</strong> on Global Hub breaks DR — restore
          S3 <code>hoh</code> first, then passive Velero for MGH.
        </p>
      )}
      {earlyMc && (
        <p>
          <strong>Activation latest</strong> while the old hub is still running
          causes dual management — shut down the active hub first.
        </p>
      )}
    </div>
  );
}
