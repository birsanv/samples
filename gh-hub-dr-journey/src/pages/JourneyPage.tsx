import { docs } from "../content/docLinks";
import { DocLink } from "../content/DocLink";
import { journeyStepBodies } from "../content/journeyStepBodies";
import { journeySteps } from "../content/phases";
import { href } from "../app/router";

export function JourneyPage() {
  return (
    <main className="page journey-page" id="main-content" tabIndex={-1}>
      <h1>Journey map</h1>
      <p className="lead">
        End-to-end flow for an <strong>active ACM hub</strong> with{" "}
        <strong>Multicluster Global Hub</strong>, backing up hub objects with
        Velero and <strong>hoh</strong> with pgBackRest on S3, then recovering
        on a passive hub. Based on{" "}
        <DocLink href={docs.playbookPgbackrestS3}>
          Global Hub pgBackRest S3 playbook
        </DocLink>
        , <DocLink href={docs.cbReadme}>cluster-backup-operator</DocLink>, and{" "}
        <DocLink href={docs.rhAcmBusinessContinuity}>
          ACM business continuity
        </DocLink>
        . Training only — no cluster calls.
      </p>
      <div className="timeline">
        {journeySteps.map((step, i) => {
          const body = journeyStepBodies[step.id];
          return (
            <article key={step.id} className="card" id={step.id}>
              <h2>
                {i + 1}. {step.title}
              </h2>
              <p className="step-summary">{body?.summary ?? ""}</p>
              {body?.steps && (
                <ol className="journey-checklist">
                  {body.steps.map((line, j) => (
                    <li key={`${step.id}-${j}`}>{line}</li>
                  ))}
                </ol>
              )}
              <details>
                <summary>More detail</summary>
                <div className="step-details">{body?.details}</div>
              </details>
            </article>
          );
        })}
      </div>
      <p className="lead">
        Walk through decisions on{" "}
        <a href={href({ page: "choices" })}>DR paths</a>, platform handoffs on{" "}
        <a href={href({ page: "prep" })}>Prep & handoffs</a>, or the guided{" "}
        <a href={href({ page: "solution", phase: "active", path: "b" })}>
          solution example
        </a>
        .
      </p>
    </main>
  );
}
