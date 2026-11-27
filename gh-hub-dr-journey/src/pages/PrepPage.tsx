import { prepHandoffs } from "../content/phases";
import { DocLink } from "../content/DocLink";
import { docs } from "../content/docLinks";

type Props = {
  path: "a" | "b";
  secretLabeled: boolean;
  onToggleSecret: () => void;
};

export function PrepPage({ path, secretLabeled, onToggleSecret }: Props) {
  return (
    <main className="page prep-page" id="main-content" tabIndex={-1}>
      <h1>Prep & handoffs</h1>
      <p className="lead">
        Same idea as “network prep” in the OpenShift journey: who must deliver
        what before restore day. S3, OADP, and Postgres shutdown span teams.
      </p>
      <ButtonPath path={path} />
      <div className="prep-map">
        {prepHandoffs.map((h) => (
          <article key={h.id} className="card">
            <h3>{h.title}</h3>
            <p>
              <strong>{h.owner}</strong>
            </p>
            <p>{h.need}</p>
          </article>
        ))}
      </div>
      <section className="card">
        <h2>Path B checklist — secret in credentials backup</h2>
        <label style={{ display: "flex", gap: "0.5rem", alignItems: "center" }}>
          <input
            type="checkbox"
            checked={secretLabeled}
            onChange={onToggleSecret}
          />
          Active hub:{" "}
          <code>multicluster-global-hub-pgbackrest-s3</code> labeled{" "}
          <code>cluster.open-cluster-management.io/backup</code> (not{" "}
          <code>cluster-activation</code>)
        </label>
        {!secretLabeled && path === "b" && (
          <p className="alert warn" style={{ marginTop: "0.75rem" }}>
            Path B on passive hub needs a credentials backup taken after
            labeling, or fall back to Path A{" "}
            <DocLink href={docs.manifestPgbackrestS3SecretSh}>secret script</DocLink>
            .
          </p>
        )}
        <p style={{ fontSize: "0.88rem", marginTop: "0.75rem" }}>
          <DocLink href={docs.cbExtendingBackup}>Labeling rules</DocLink> ·{" "}
          <DocLink href={docs.playbookPgbackrestS3}>Playbook §2.1</DocLink>
        </p>
      </section>
      <section className="card">
        <h2>Data stores (what goes where)</h2>
        <ul className="checklist">
          <li>
            <span>Velero BSL</span> — hub Kubernetes objects (passive +
            activation slices)
          </li>
          <li>
            <span>S3 repo2-path</span> — pgBackRest full/incr/diff + WAL for{" "}
            <code>hoh</code>
          </li>
          <li>
            <span>etcd</span> — live cluster state; Velero rehydrates selected
            API objects, not Postgres rows
          </li>
        </ul>
        <p style={{ fontSize: "0.88rem", marginTop: "0.75rem" }}>
          Velero prefix: <DocLink href={docs.oadpDpa}>DPA / BSL</DocLink>.
          pgBackRest prefix:{" "}
          <DocLink href={docs.playbookPgbackrestS3}>playbook §Configuration</DocLink>
          .
        </p>
      </section>
    </main>
  );
}

function ButtonPath({ path }: { path: "a" | "b" }) {
  return (
    <p className="lead">
      Current story path: <strong>Path {path.toUpperCase()}</strong> (change on
      Solution example).
    </p>
  );
}
