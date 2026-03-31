---
name: jira-weekly-activity-filters
description: Produces weekly Jira/GitHub activity summaries with low-noise JQL (resolutiondate, worklog, status CHANGED, created—not raw updated alone), a readable executive summary (short intro plus themed bullets), and optional Google Doc HTML via scripts/md_to_google_doc_html.py. Supports the same JQL patterns for any assignee/reporter email the caller specifies (subject to Jira visibility). Use when writing weekly summaries, “what I did this week”, Jira filters, Google Doc paste HTML, or when stale issues appear in updated-based queries.
---

# Jira weekly activity: low-noise data + readable summaries

## Why `updated` is noisy

Jira’s **`updated`** field changes on *any* edit: workflow, comment, label, sprint, link, **bulk operations**, automation, or integrations. Old issues (e.g. [ACM-24642](https://issues.redhat.com/browse/ACM-24642)) can surface in “**updated** this week” without new work from you.

**When an issue “jumps” in date:** open the issue → **History** (or **Activity**). Look for bulk users, automation, or mass transitions.

---

## What to query instead (“what I did this week”)

Prefer **`project = ACM`** (or an explicit project list) plus assignee/reporter. Use **one or more** rows below; combine results for narrative and **cross-check** closures against PRs and History.

| Intent | JQL pattern (adjust dates and email) |
|--------|--------------------------------------|
| **Resolved in the window** | `project = ACM AND assignee = "you@company.com" AND resolutiondate >= "YYYY-MM-DD" AND resolutiondate <= "YYYY-MM-DD"` |
| **Filed in the window** | `project = ACM AND reporter = "you@company.com" AND created >= "YYYY-MM-DD" AND created <= "YYYY-MM-DD"` |
| **Time logged in the window** | `project = ACM AND worklogAuthor = "you@company.com" AND worklogDate >= "YYYY-MM-DD" AND worklogDate <= "YYYY-MM-DD"` — *or `startOfWeek()` / `endOfWeek()` if supported* |
| **Status changed (workflow signal)** | `project = ACM AND assignee = "you@company.com" AND status CHANGED DURING ("YYYY-MM-DD", "YYYY-MM-DD")` — *validate syntax in your Jira (Cloud vs DC)* |
| **OADP (same ideas)** | `project = OADP AND …` with **`--project OADP`** in **jira** CLI so the default project is not ACM |

**Optional:** `updated` in range **only** with an explicit caveat that bulk edits inflate counts—never as the sole “delivery” signal.

### Same patterns for **another person** (substitute email)

Use the **same JQL**, replacing the email with their **`assignee` / `reporter` / `worklogAuthor` value as stored in Jira** (often `firstname.lastname@company.com`). Example:

`project = ACM AND assignee = "colleague@redhat.com" AND status CHANGED DURING ("2026-03-23", "2026-03-30")`

- **Jira visibility:** The `jira` CLI (and browser) only return issues the **authenticated account** is allowed to see. You may get **fewer rows** or **empty** results for someone else if your permissions are narrower than theirs—or you may see **nothing** if you cannot browse their queue. **Do not** assume silence means they did no work.
- **GitHub:** `gh` PR search uses **GitHub username**, not email. Resolve with `gh search users --q "email@..."` or ask; use `--author <login>` for merged PRs in the date range.
- **Narrative:** Prompts default to **first person** (“I focused…”). For another person, use **third person** (“They focused…”, “**Name** merged…”) or title the doc **“Weekly activity — Full Name”** and keep sections neutral—**do not** imply they wrote the summary unless it is their own report.
- **Use responsibly:** Generating activity reports about colleagues may be **sensitive** (manager rollups, HR, performance). Prefer **explicit request**, **role-appropriate** use, and **company policy** on Jira data.

---

## Agent workflow (gather → write)

1. Run **`resolutiondate`**, **`created`**, **`worklogDate`**, and **`status CHANGED DURING`** queries for the period; note **0 results** honestly. Use the **subject’s email** in JQL when generating for someone else (see above).
2. Fetch **GitHub** PRs (`gh`): merged and open for target repos (e.g. `stolostron/cluster-backup-operator`), scoped by **`--author`** when the report is for a specific person.
3. Ground narrative in **PRs + Jira keys**; do **not** claim “closed N issues” from raw **`updated`** alone without **`resolutiondate`** or History alignment.
4. For unexpected **Closed** on old keys, flag **“sanity-check History”** (bulk automation).

---

## Delivered markdown: what readers see

Follow **[`prompts/weekly_summary.md`](../../../prompts/weekly_summary.md)** and the tone of **`results/weekly_summary_mar3-9_2026.md`** / **`results/weekly_summary_mar23_mar30_2026.md`**.

### Executive Summary (required shape)

- **Do not** open with a large **“How this summary was built”** table of JQL and CLI outputs unless the user explicitly asks for methodology—that belongs in **agent workflow**, not the default reader-facing doc.
- **Do** use:
  - **1–2 sentence intro** (themes for the week: BC, restore, DR, etc.).
  - **Themed bullet groups** so it is scannable—adapt labels to the week, for example:
    - **Theme** — main delivery narrative + anchor issue link(s).
    - **Shipped** — merged PRs with repo + issue links.
    - **In flight** — open PRs.
    - **Review & backlog** — issues in Review / In Progress / New as appropriate.
    - **Reporter only** — reporter ≠ assignee; note assignee.
    - **Closures to sanity-check** — old issues closed this period; remind to check **History** if bulk automation is suspected.

Keep every issue key as a markdown link: `[ACM-12345](https://issues.redhat.com/browse/ACM-12345)`.

### Rest of the document

- **`## 📋 Jira Activity`** — `### 🔧 Issues I Actively Contributed To` with per-issue **Updated**, **My Role**, **Recent Activity**, **Impact**, **Technical Details** when useful.
- **`⭐ New Issues`**, **`✅ Issues Closed`**, **`## 🔧 GitHub Activity`** (PR table), **Cross-Team**, **Metrics**, **Key Achievements**, **Looking Ahead**, closing **italic** BC/quality line—per **`prompts/weekly_summary.md`**.

### Optional appendix

If the user wants transparency, add a short **“Data sources”** subsection with JQL links—**not** the default.

---

## Google Doc HTML (companion file)

After the markdown is saved under **`results/`**, generate paste-ready HTML from the **jira_cli** repo root:

```bash
python3 scripts/md_to_google_doc_html.py results/weekly_summary_<stem>.md
```

- **Output:** `results/weekly_summary_<stem>_for_google_doc.html` (same directory as the `.md`).
- **Paste workflow:** open the `.html` in a browser → **Select all** → **Copy** → paste into Google Docs. Headings map to outline styles; tables use `<td>` for headers (avoids spurious TOC entries). See **`results/google_doc_INDEX.md`** for the manager-doc index and TSV row to add each week.
- **Converter behavior:** [`scripts/md_to_google_doc_html.py`](../../../scripts/md_to_google_doc_html.py) — nested `-` / `  -` lists, `1.` ordered lists, markdown tables, `**Period**` / `**Generated**` metadata.

When the user asks for a weekly summary “for Google Docs” or “as HTML,” run this script after writing the `.md` (or instruct them to run it) and mention the output path.

---

## `jira` CLI notes

- Use **`--project OADP`** (or `project = …` in `-q`) for non-ACM queries; default config may assume **ACM** only.
- Put **`ORDER BY`** in CLI flags (e.g. `--order-by updated`), not inside `-q`, if the CLI rejects it in the JQL string.

---

## Quick reference: noise vs signal

| Field | Good for “my week” | Noise risk |
|-------|---------------------|------------|
| `resolutiondate` | Closures in window | Low when assignee-scoped |
| `worklogDate` / `worklogAuthor` | Time spent | Low |
| `created` | New issues filed | Low |
| `status CHANGED` | Workflow movement | Low–medium |
| `updated` | Anything touched | **High** (bulk/automation) |

---

## Related (this repo)

- Section order and style: [`prompts/weekly_summary.md`](../../../prompts/weekly_summary.md)
- Examples: `results/weekly_summary_mar3-9_2026.md`, `results/weekly_summary_mar23_mar30_2026.md`
- Google Doc paste: `results/weekly_summary_mar23_mar30_2026_for_google_doc.html`, [`results/google_doc_INDEX.md`](../../../results/google_doc_INDEX.md)
