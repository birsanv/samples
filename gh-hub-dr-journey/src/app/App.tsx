import { useCallback, useEffect, useMemo, useState } from "react";
import { ChoicesPage } from "../pages/ChoicesPage";
import { JourneyPage } from "../pages/JourneyPage";
import { PrepPage } from "../pages/PrepPage";
import { SolutionPage } from "../pages/SolutionPage";
import { DocLink } from "../content/DocLink";
import { docs } from "../content/docLinks";
import { href, parseHash, type PageId, type Route, type SolutionPhase } from "./router";

const pages: { id: PageId; label: string }[] = [
  { id: "journey", label: "Journey map" },
  { id: "choices", label: "DR paths" },
  { id: "prep", label: "Prep & handoffs" },
  { id: "solution", label: "Solution example" },
];

export function App() {
  const [route, setRoute] = useState<Route>(() =>
    parseHash(window.location.hash),
  );
  const [choiceSelections, setChoiceSelections] = useState<Record<string, string>>(
    { "dr-path": "b", mc: "skip", "restore-cleanup": "none", "postgres-order": "postgres-first" },
  );
  const [secretLabeled, setSecretLabeled] = useState(false);
  const [completedPhases, setCompletedPhases] = useState<Set<SolutionPhase>>(
    () => new Set(),
  );
  const [oldHubDown, setOldHubDown] = useState(false);
  const solutionPath = useMemo(
    () =>
      route.page === "solution"
        ? route.path
        : choiceSelections["dr-path"] === "a"
          ? "a"
          : "b",
    [route, choiceSelections],
  );

  useEffect(() => {
    const onHash = () => setRoute(parseHash(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const navigate = useCallback((next: Route) => {
    const url = href(next);
    if (window.location.hash !== url) window.location.hash = url;
    setRoute(next);
  }, []);

  const onSelectChoice = (group: string, value: string) => {
    setChoiceSelections((s) => ({ ...s, [group]: value }));
    if (group === "dr-path") {
      navigate({
        page: "solution",
        phase:
          route.page === "solution" ? route.phase : "active",
        path: value === "a" ? "a" : "b",
      });
    }
  };

  const resetSolution = () => {
    setCompletedPhases(new Set());
    setOldHubDown(false);
    navigate({ page: "solution", phase: "active", path: solutionPath });
  };

  const completePhase = (p: SolutionPhase) => {
    setCompletedPhases((prev) => new Set([...prev, p]));
    const order: SolutionPhase[] = [
      "active",
      "passive-prep",
      "postgres",
      "passive-velero",
      "activation",
    ];
    const i = order.indexOf(p);
    if (i < order.length - 1) {
      navigate({
        page: "solution",
        phase: order[i + 1],
        path: solutionPath,
      });
    }
  };

  const activePage: PageId =
    route.page === "solution"
      ? "solution"
      : route.page === "choices"
        ? "choices"
        : route.page === "prep"
          ? "prep"
          : "journey";

  return (
    <div className="application">
      <header className="app-header">
        <a
          className="app-brand"
          href={href({ page: "journey" })}
          onClick={(e) => {
            e.preventDefault();
            navigate({ page: "journey" });
          }}
        >
          <svg width="28" height="28" viewBox="0 0 32 32" aria-hidden>
            <rect width="32" height="32" rx="6" fill="#ee0000" />
            <path
              d="M8 22V10h8v12h8V10"
              stroke="#fff"
              strokeWidth="2"
              fill="none"
            />
          </svg>
          <span>
            <strong>Global Hub</strong>
            active–passive DR
          </span>
        </a>
        <nav className="app-nav" aria-label="Main">
          {pages.map((p) => (
            <a
              key={p.id}
              className={`nav-btn ${activePage === p.id ? "active" : ""}`}
              href={
                p.id === "solution"
                  ? href({ page: "solution", phase: "active", path: solutionPath })
                  : href({ page: p.id })
              }
              onClick={(e) => {
                e.preventDefault();
                if (p.id === "journey") navigate({ page: "journey" });
                else if (p.id === "choices")
                  navigate({
                    page: "choices",
                    path: solutionPath === "a" ? "a" : "b",
                  });
                else if (p.id === "prep") navigate({ page: "prep" });
                else
                  navigate({
                    page: "solution",
                    phase: "active",
                    path: solutionPath,
                  });
              }}
            >
              {p.label}
            </a>
          ))}
        </nav>
      </header>
      {route.page === "journey" && <JourneyPage />}
      {route.page === "choices" && (
        <ChoicesPage
          path={route.path}
          selections={choiceSelections}
          onSelect={onSelectChoice}
        />
      )}
      {route.page === "prep" && (
        <PrepPage
          path={solutionPath}
          secretLabeled={secretLabeled}
          onToggleSecret={() => setSecretLabeled((v) => !v)}
        />
      )}
      {route.page === "solution" && (
        <SolutionPage
          phase={route.phase}
          path={route.path}
          completed={completedPhases}
          oldHubDown={oldHubDown}
          onPhase={(phase) =>
            navigate({ page: "solution", phase, path: route.path })
          }
          onPath={(path) =>
            navigate({ page: "solution", phase: route.phase, path })
          }
          onComplete={completePhase}
          onToggleOldHub={() => setOldHubDown((v) => !v)}
          onReset={resetSolution}
        />
      )}
      <footer className="app-footer">
        Training UI only — no cluster calls. Docs:{" "}
        <DocLink href={docs.playbookPgbackrestS3}>pgBackRest S3 playbook</DocLink>
        , <DocLink href={docs.cbReadme}>cluster-backup-operator</DocLink>.
      </footer>
    </div>
  );
}
