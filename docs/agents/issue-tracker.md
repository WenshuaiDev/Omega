# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI.
Infer the repository from `git remote -v`.

## Conventions

- Create, read, list, comment on, label, and close issues with `gh issue`.
- Fetch comments and labels when reading an issue.
- When a skill says “publish to the issue tracker”, create a GitHub issue.
- When a skill says “fetch the relevant ticket”, read the GitHub issue and its comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

Use one issue labelled `wayfinder:map` as the map. Link child tickets as
GitHub sub-issues when available; otherwise use a task list in the map.
Represent blockers with GitHub issue dependencies when available; otherwise
put `Blocked by: #<n>` in the child issue. Claim the first unassigned,
unblocked open child and record the result on that issue before closing it.
