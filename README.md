# Film Camera

A social camera app inspired by disposable film cameras.

Film Camera brings the feeling of a disposable camera into a shared mobile experience. Load a roll with a fixed number of exposures, initially 32. A roll can be personal or shared with friends. On a shared roll, everyone uses the same pool: for example, four friends might share 32 shots during a night out.

After taking a photo, you cannot preview, review, delete, retake, or undo it. The image disappears behind the metaphorical shutter until the roll is finished and developed. Nobody sees the photos while shooting. The default development period is seven days; when development completes, everyone on the roll can see the album for the first time together.

**Shoot now. See it later.**

## Why it is different

Film Camera is designed around the emotional experience of disposable film, not simply a film filter:

- **Scarcity:** a fixed roll makes each exposure feel intentional.
- **No instant feedback:** you stay present instead of checking every shot.
- **Less pressure to perform for the camera:** the moment matters more than getting a perfect image.
- **Anticipation:** the wait makes the reveal meaningful.
- **Shared memories:** friends contribute to one roll and discover the album together.
- **The disposable-film feeling:** the product changes how you take and remember photos, rather than only changing how they look.

## Future possibilities

These are ideas for future versions, not features available today:

- 24-hour, 1-hour, or instant development upgrades
- Larger rolls or additional rolls
- Premium film looks
- Larger group rolls
- Physical prints or photo books

## Current status

The project is in early development. At present:

- The Supabase backend foundation exists.
- The database schema and Row Level Security policies exist.
- Private Storage policies exist for original film photos.
- Shared exposure allocation is atomic and backend-authoritative.
- Backend database and concurrency tests exist.
- The React Native / Expo / TypeScript mobile shell is scaffolded with Expo Router and public Supabase configuration validation. Authentication, roll flows, capture, and album screens are not implemented yet.

The repository contains the backend foundation and a minimal mobile shell. The technical sections below document what is implemented, how to run its checks, and the security boundaries future app features must preserve.

## Architecture

The mobile shell uses React Native, Expo, TypeScript, and Expo Router. Supabase provides Auth, Postgres, and private Storage. The app shell is in place; Auth, roll, capture, and album behavior will be added in later issues.

Supabase is authoritative for roll membership, exposure allocation, roll lifecycle, development timing, and photo access. Sensitive state changes happen in database functions and transactions. The mobile client must not set shared exposure totals or use its local clock to decide when a roll is developed.

All public database tables have Row Level Security enabled. The original photo bucket is private. Clients receive only public project configuration and signed-in user permissions; service-role keys and other privileged secrets belong only in trusted backend environments. The migrations do not deploy an Edge Function. A future photo-finalization endpoint must validate the uploaded image and claim before calling the service-only confirmation function.

For hosted projects, keep the private, auth, and storage schemas out of the exposed Data API schemas. The app should use the public schema and explicitly granted RPCs.

## Windows development setup

Use Node.js 22 or newer. Run these commands in PowerShell:

```powershell
Set-Location 'D:\CodexWorkspaces\film-camera-app-1'
npm.cmd ci
```

Start the Expo development server from PowerShell:

```powershell
npm.cmd run start
```

For an iPhone smoke test, install Expo Go, put the phone and Windows computer on the same network, then scan the terminal QR code with the iPhone Camera app and open it in Expo Go. This workflow does not require Xcode or macOS.

The repository pins Supabase CLI 2.119.0 and commits its lockfile. Use the local CLI with npx.cmd --no-install supabase; a global CLI installation is unnecessary.

### Test without Docker or a Supabase account

```powershell
npm.cmd run test:standalone
```

This starts a temporary native PostgreSQL instance bound to loopback, applies every migration, runs the SQL tests and genuine concurrent-session tests, verifies the optional development controls, then stops the database and removes its own temporary files. It ignores external database connection settings. It does not create a Supabase project or modify a hosted database.

The standalone database uses small test substitutes for Supabase's auth and storage schemas. Its PostgreSQL engine is real; its Storage HTTP service, Auth token issuance, and binary object store are not Supabase. Run the full local-stack checks below before connecting an app. SQL tests prove policy decisions, including the SELECT prerequisite for early reads; they do not prove actual HTTP download or signing behavior.

Successful output includes ok ... for each of the 83 SQL assertions, PASS: 83 SQL authorization and integrity assertions, concurrent-claim PASS lines, development-control PASS lines, and PASS: native PostgreSQL verification complete; isolated database removed. Any assertion failure exits nonzero.

### Test against the full local Supabase stack

Install Docker Desktop with its WSL2 backend and start Docker. No hosted project or Supabase login is required for these local commands.

```powershell
npx.cmd --no-install supabase start
npx.cmd --no-install supabase db reset --local
npx.cmd --no-install supabase db lint --local --schema public,private --fail-on error
npx.cmd --no-install supabase db advisors --local
npx.cmd --no-install supabase test db --local
npm.cmd run test:concurrency
```

The command supabase db reset --local recreates this project's LOCAL database and discards its local data. Use it only for a disposable development stack. The SQL test file itself rolls back its fixtures. The concurrency runner commits overlapping transactions, then deletes only its own UUID-scoped fixtures. It rejects non-local database hosts.

The SQL suite emits Test Anything Protocol (TAP) directly, so the CLI's pg_prove runner can execute it without a pgTAP extension dependency. Expected CLI summary:

```text
...film_backend.test.sql .. ok
All tests successful.
Result: PASS
```

db lint should report no errors; review the advisors output rather than assuming an empty report. Optional Auth-provider setup warnings are distinct from the database policies implemented here.

### Create or connect a hosted development project

Only this section needs a Supabase account and hosted project. Create a NEW development project in the Supabase dashboard and retain its database password. Keep production in a separate project. Do not use these initial migrations against an unrelated database with existing tables of the same names.

```powershell
npx.cmd --no-install supabase login
npx.cmd --no-install supabase link --project-ref YOUR_DEVELOPMENT_PROJECT_REF
npx.cmd --no-install supabase db push --linked --dry-run
npx.cmd --no-install supabase db push --linked
npx.cmd --no-install supabase migration list --linked
```

Linking prompts for database credentials when needed. The project ref is the identifier in the dashboard project URL, not the project display name. The first push applies the three migrations listed below. This creates the bucket and database policies, but does not deploy an Edge Function. In the hosted project's API settings keep the private, auth, and storage schemas OUT of the exposed Data API schemas; use public (and the default GraphQL schema if enabled). Client access is granted explicitly, and RLS remains enabled.

Before production use, verify the bucket is private in Storage, anonymous Auth sign-ins are disabled, and only the production migrations are applied. Do not apply development SQL there.

## Environment variables

Copy the example file for future Expo configuration:

```powershell
Copy-Item -LiteralPath '.env.example' -Destination '.env'
```

Fill in the app's public configuration from the project's Connect dialog:

```dotenv
EXPO_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The app config helper accepts only the current `sb_publishable_` key format and validates the URL before a Supabase client is initialized. The initial placeholder screen does not connect to Supabase, so the app shell can start before project values are configured. The publishable key does not authorize private data by itself: the signed-in user's JWT and RLS do.

Never put a secret/service-role key, database password, or CLI access token in an EXPO_PUBLIC_* variable or mobile bundle. No privileged key is required in this repository's .env for the standalone tests. TEST_DATABASE_URL is an optional backend-test-only local PostgreSQL override; the default is postgresql://postgres:postgres@127.0.0.1:54322/postgres.

For later testing on an iPhone, use a hosted development project's HTTPS URL. 127.0.0.1 on the phone points to the phone, not this Windows computer. There is no mobile app to test yet.

## Database migrations

| File | Responsibility |
| --- | --- |
| 20261004231435_film_schema.sql | Core tables and foreign keys; unique request/exposure/path constraints; bounded counters; exact development deadlines; profile signup trigger; RLS enabled; protected project setting; capacity and development-speed guards. |
| 20261004231438_film_access_and_rpcs.sql | Explicit client grants and member/profile/photo policies; invoker RPC wrappers around narrowly granted internal functions; atomic creation/claiming; owner-only finishing; server-clock development release; service-only upload confirmation. |
| 20261004231440_film_storage.sql | Private JPEG-only film-originals bucket with 10 MiB maximum objects; reserved-path INSERT; developed-member SELECT; restrictive guards against anonymous access, replacement, deletion, and policy widening. |
| 20261005000000_project_environment_guard.sql | Adds a private project-environment marker that defaults to unknown, prevents production from being reclassified as development, and requires both the development marker and admin opt-in for shortened roll durations. |

The migrations were created with the installed Supabase CLI. Optional supabase/dev/*.sql files are deliberately outside the migration directory and are not included in db push or db reset. Use mark_development_environment.sql as an administrator only after verifying the target is the intended dedicated development project.

## Database API contract

| RPC | Caller | Behavior |
| --- | --- | --- |
| create_roll(p_name, p_total_exposures=32, p_roll_type='shared') | Authenticated user | Creates an active shared-pool roll and its owner membership atomically; always seven-day development. personal uses the same pool with one member. Capacity is 1..256. |
| claim_exposure(p_roll_id, p_request_id) | Current member | Returns one claim and assigned path; consumes exactly one slot. A retry by that photographer returns the original claim, even if the roll has since closed. Revoked members cannot replay. |
| finish_roll(p_roll_id) | Current owner | Irreversibly closes capture. Remains active while claimed uploads are pending; starts development when they are resolved. Rejects an empty roll. |
| refresh_roll_status(p_roll_id) | Current member | Marks a developing roll developed only once the database clock reaches its stored deadline. Call on countdown expiry and before album loading. |
| confirm_exposure(p_claim_id, p_captured_at) | Backend service_role only | Checks that the assigned Storage object exists, confirms the photo idempotently, and starts development if the roll is full or finished and no pending claims remain. |

Public RPCs are SECURITY INVOKER wrappers. Internal SECURITY DEFINER functions use an empty search_path, qualified relations, explicit identity/membership checks, and restricted EXECUTE grants. Mobile clients cannot directly insert, update, or delete rolls, membership, claims, or photos. They can change only their own profile's display name. Invitation hashes remain unreadable; invitation creation/redemption is reserved for a later task.

Claiming locks the user/request key, then the roll row and caller membership. It checks idempotency after locking and before capacity. Counter increments and the claim insert share one transaction. Reusing a request UUID for a different roll is rejected. Future membership mutation functions must use the same roll-before-member lock order.

New-claim errors include 42501 (membership denied), 55000 (capture closed), P0001 (no exposures remain), and 22023 (invalid settings/request). Authentication is required even inside the internal functions.

exposures_used counts consumed slots, including uploads still pending. Retry the SAME captured file and request; never reclaim a slot or replace its object. No missing-frame recovery endpoint is implemented yet. The schema reserves missing for a later trusted recovery process; unresolved uploads intentionally prevent development rather than silently dropping photographs.

The future finalization Edge Function must validate the user and claim ownership before calling the service-only confirmer. Storage existence is checked in SQL; actual byte/type validation and upload error recovery belong to that later endpoint. There is no client-accessible privileged upload confirmation now.

## Photo release security model

Both photo rows and private Storage reads require current membership, a stored claim, a confirmed photo, developed status, and database wall-clock time at or after develops_at. Neither owner nor photographer gets an exception. Guessing a path does not grant access. Active/developing photo rows and objects are invisible; the claim RPC returns the photographer's upload path but never a usable download URL.

Clients may INSERT only at the exact pending claim path <roll UUID>/<claim UUID>.jpg. Use authenticated direct upload with upsert: false. The INSERT policies also require storage.allow_only_operation('object.upload'): signed upload tokens, resumable/TUS uploads, S3, and copy operations are deliberately unsupported, preventing reusable upload capabilities from bypassing later claim state or replacement checks. This requires the current Supabase Storage operation helper; migrations fail closed on older schemas lacking it. SELECT is withheld before development; UPDATE and DELETE are withheld throughout the lifecycle. Restrictive policies prevent later broad permissive policies from widening access to this bucket.

After development, an authorized member can download or create a signed download URL. Such a URL is a bearer capability; later sharing code should choose short lifetimes and avoid persisting URLs. Backend administrators and privileged server credentials intentionally remain trusted. Backend rules cannot prevent a modified phone from extracting its own camera output.

## Development-only shortened development times

The project_environment field in private.project_settings defaults to unknown. Unknown, missing, and production markers fail closed. Only a database administrator can classify an unknown project as development with supabase/dev/mark_development_environment.sql; the script refuses a production marker. Production markers cannot be changed back to development through ordinary updates.

After independently verifying the project ref, mark only the dedicated DEVELOPMENT project, then apply supabase/dev/enable_test_development.sql as the database administrator. The enable script checks the marker before changing the override or creating test RPCs. The database also requires both project_environment = development and the separate is_development opt-in before accepting shortened durations. The only allowed values are 30, 300, 3600, and 604800 seconds. No client parameter or environment flag can enable them, and ordinary create_roll remains seven days.

To disable the override, apply supabase/dev/disable_test_development.sql as an administrator. It removes both test RPCs and resets is_development to false; the project remains marked development, but short durations stay disabled until the enable script is deliberately applied again. Do not run the marker or enable scripts against production.

```powershell
# LOCAL disposable stack: mark this local database, then enable its test RPC.
npx.cmd --no-install supabase db query --local --file supabase/dev/mark_development_environment.sql
npx.cmd --no-install supabase db query --local --file supabase/dev/enable_test_development.sql
# For a dedicated LINKED development project, verify the project ref, then mark and enable:
npx.cmd --no-install supabase db query --linked --file supabase/dev/mark_development_environment.sql
npx.cmd --no-install supabase db query --linked --file supabase/dev/enable_test_development.sql
# Disable on that same project when finished:
npx.cmd --no-install supabase db query --linked --file supabase/dev/disable_test_development.sql
```

To remove the test RPC, apply supabase/dev/disable_test_development.sql. Existing test rolls retain their configured deadlines. Test UI and nearly-finished roll fixtures are not part of this backend step.

## Testing and verification boundaries

The SQL suite covers creation/membership, hidden rolls, atomic RPC behavior, capacity exhaustion, global UUID reuse, metadata/object denial for owner/photographer/outsider, server-clock release, spoofed timestamps, immutable client fields, exact-path upload, deletion/overwrite denial, pending-upload finishing, and revocation. The multi-session script independently proves simultaneous claims, the last-slot race, and simultaneous duplicate requests using observed database lock waits.

The standalone harness uses real PostgreSQL with small auth and storage schema substitutes. It does not prove behavior through Supabase Auth token issuance or Storage HTTP endpoints. The current database tests exercise Storage policy logic but do not establish actual HTTP upload, download, listing, or signed-URL behavior.

Before connecting the camera, run HTTP checks against the actual development Supabase project: upload a real JPEG at its claim path; verify download, list, signed-download URL issuance, overwrite/upsert, copy/move, and delete are denied before release; verify member reads succeed only after backend release and outsiders remain denied. Never upload private real photographs as fixtures.

Primary references: [Storage access controls](https://supabase.com/docs/guides/storage/security/access-control), [database function security](https://supabase.com/docs/guides/database/functions), [CLI database testing](https://supabase.com/docs/reference/cli/supabase-test-db), and [Supabase API keys](https://supabase.com/docs/guides/api/api-keys).
