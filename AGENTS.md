Prefer inspecting the existing codebase before making changes. Reuse existing patterns and dependencies when practical. Avoid unnecessary rewrites, new dependencies, or architectural changes unless they materially improve the project. When editing, make the smallest effective change, preserve working behavior, and verify builds/tests when possible. Explain significant tradeoffs briefly.

## Product invariants

This app recreates the experience of shooting a disposable film camera. Preserve these rules unless an issue or explicit user instruction intentionally changes them:

- Users cannot preview a captured photo while a roll is active or developing.
- Do not add thumbnails, recent-photo previews, retakes, undo, delete, or gallery access before development.
- A captured exposure is intentional and should not be silently restored because of UI navigation or ordinary upload retries.
- Shared rolls use a backend-authoritative exposure count. The mobile client must not directly mutate shared exposure totals.
- Photo access before development must be prevented by backend/storage authorization, not merely hidden in the UI.
- Development eligibility must use trusted server/database time, never the phone's local clock.
- Roll owners and photographers do not receive special early access to undeveloped photos.
- Active-roll photos must not automatically be saved to the user's normal Photos library.
- Failed uploads should retry the same captured image when recoverable rather than giving the user a new exposure.
- Preserve the core product idea: **shoot now, see it later**.

## Technical direction

Default to the existing project architecture unless there is a strong reason to change it:

- React Native
- Expo
- TypeScript
- Expo Router
- Supabase Auth
- Supabase Postgres
- Supabase Storage
- Supabase Row Level Security / backend database functions for sensitive authorization

The primary development environment is Windows with testing on a physical iPhone.

Prefer Expo-compatible libraries and workflows. Do not introduce a dependency on local Xcode or macOS for normal development unless the task genuinely requires native iOS work and the limitation is clearly explained.

Do not place Supabase service-role keys or other privileged secrets in the Expo client.

## Backend and security

Treat Supabase as authoritative for:

- roll membership
- exposure allocation
- roll lifecycle
- development timing
- invitations
- photo-access authorization

Sensitive state transitions should use database functions, transactions, Edge Functions, or equivalent trusted backend operations rather than trusting client-provided values.

When changing storage or RLS policies, explicitly consider:

- authenticated member
- roll owner
- photographer
- unrelated authenticated user
- unauthenticated user
- active roll
- developing roll
- developed roll

Do not weaken an existing security rule merely to simplify client implementation.

## Implementation style

Work incrementally.

- Inspect the current implementation before creating new abstractions.
- Prefer the smallest change that completes the issue.
- Avoid broad rewrites while implementing an unrelated feature.
- Keep routes/screens thin when business logic already belongs in features, hooks, or services.
- Preserve existing domain vocabulary and schema terminology.
- Do not introduce speculative abstractions for future features unless they materially simplify the current implementation.
- If a change affects a product invariant or security boundary, call that out before implementing it.

## Verification

For each implementation task, verify the smallest relevant set of checks available in the repository.

Where applicable:

- run TypeScript/type checks
- run linting
- run relevant automated tests
- run Supabase/database tests for schema, RLS, and concurrency changes
- verify Expo starts successfully
- describe the exact physical-iPhone test needed for camera or device behavior

Do not claim something is verified if it was not actually run.

For development-only shortcuts such as shortened development times or nearly-complete rolls, ensure they cannot become available in production accidentally.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default triage labels configured for this repository. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.
