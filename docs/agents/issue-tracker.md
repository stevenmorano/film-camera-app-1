# Issue tracker: GitHub

Issues and specs for this repository live as GitHub issues. Use the `gh` CLI for issue operations. Infer the repository from `git remote -v`; `gh` does this automatically when run inside a clone.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`
- **Read an issue**: `gh issue view <number> --comments`
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close an issue**: `gh issue close <number> --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.** Set this to `yes` if this repository later treats external PRs as feature requests.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. Create it with `gh issue create --label wayfinder:map`.
- **Child ticket**: create an issue linked to the map as a GitHub sub-issue. Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Use labels `wayfinder:<type>` (`research`, `prototype`, `grilling`, or `task`). Once claimed, assign it to the driving developer.
- **Blocking**: use GitHub's native issue dependencies. If unavailable, use a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open child issues, exclude issues with an open blocker or an assignee, and choose the first remaining issue in map order.
- **Claim**: assign the issue with `gh issue edit <n> --add-assignee @me`.
- **Resolve**: comment with the answer, close the issue, then append a context pointer to the map's Decisions-so-far.

GitHub shares one number space across issues and PRs. Resolve a bare `#42` by checking `gh pr view 42` and falling back to `gh issue view 42`.
