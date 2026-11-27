export type PageId = "journey" | "choices" | "prep" | "solution";

export type SolutionPhase =
  | "active"
  | "passive-prep"
  | "postgres"
  | "passive-velero"
  | "activation";

export type Route =
  | { page: "journey" }
  | { page: "choices"; path?: "a" | "b" }
  | { page: "prep" }
  | { page: "solution"; phase: SolutionPhase; path: "a" | "b" };

export function parseHash(hash: string): Route {
  const raw = hash.replace(/^#\/?/, "");
  if (!raw || raw === "journey") return { page: "journey" };
  if (raw.startsWith("choices")) {
    const q = new URLSearchParams(raw.split("?")[1] ?? "");
    const path = q.get("path");
    return { page: "choices", path: path === "b" ? "b" : path === "a" ? "a" : undefined };
  }
  if (raw.startsWith("prep")) return { page: "prep" };
  if (raw.startsWith("solution")) {
    const q = new URLSearchParams(raw.split("?")[1] ?? "");
    const phase = (q.get("phase") ?? "active") as SolutionPhase;
    const path = q.get("path") === "b" ? "b" : "a";
    const phases: SolutionPhase[] = [
      "active",
      "passive-prep",
      "postgres",
      "passive-velero",
      "activation",
    ];
    return {
      page: "solution",
      phase: phases.includes(phase) ? phase : "active",
      path,
    };
  }
  return { page: "journey" };
}

export function href(route: Route): string {
  switch (route.page) {
    case "journey":
      return "#/journey";
    case "choices":
      return route.path ? `#/choices?path=${route.path}` : "#/choices";
    case "prep":
      return "#/prep";
    case "solution":
      return `#/solution?phase=${route.phase}&path=${route.path}`;
  }
}
