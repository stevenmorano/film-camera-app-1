import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, realpath, rm } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import EmbeddedPostgres from "embedded-postgres";

const workspace = await realpath(fileURLToPath(new URL("../", import.meta.url)));
const verificationRoot = path.join(workspace, ".verification");
const serverLogs = [];
let runDirectory;
let verifiedRoot;
let database;
let client;
let started = false;
let pgCtlExecutable;
let shutdownPromise;
let stage = "initializing an isolated PostgreSQL database";

function assertInside(parent, target) {
  const relative = path.relative(parent, target);
  assert.ok(
    relative && !relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative),
    "the verification directory must remain inside the workspace",
  );
}

async function allocateLoopbackPort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0 }, resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const port = address.port;
  await new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
  return port;
}

function captureServerLog(message) {
  serverLogs.push(String(message));
  if (serverLogs.length > 12) serverLogs.shift();
}

async function resolvePgCtlExecutable() {
  const platform = process.platform === "win32" ? "windows" : process.platform;
  const binaries = await import(`@embedded-postgres/${platform}-${process.arch}`);
  const executable = await realpath(binaries.pg_ctl);
  const dependencies = await realpath(path.join(workspace, "node_modules"));
  assertInside(dependencies, executable);
  assert.ok(["pg_ctl", "pg_ctl.exe"].includes(path.basename(executable)));
  return executable;
}

async function stopIsolatedDatabase() {
  if (!started) return;
  if (shutdownPromise) return shutdownPromise;
  shutdownPromise = (async () => {
    const target = await realpath(runDirectory);
    assertInside(verifiedRoot, target);
    assert.equal(path.dirname(target), verifiedRoot);
    const child = spawn(pgCtlExecutable, ["-D", target, "-m", "fast", "-w", "-t", "10", "stop"], {
      cwd: workspace,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      timeout: 15_000,
    });
    let output = "";
    for (const stream of [child.stdout, child.stderr]) {
      stream.on("data", (chunk) => { output = (output + chunk.toString()).slice(-3_000); });
    }
    await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => {
        if (code === 0) resolve();
        else reject(new Error(`pg_ctl could not stop this run's database (exit ${code ?? "none"}, signal ${signal ?? "none"}): ${output.trim()}`));
      });
    });
    // pg_ctl -w waits for shutdown. The exit hook's next stop call is a no-op.
    started = false;
  })();
  try {
    await shutdownPromise;
  } finally {
    shutdownPromise = undefined;
  }
}

async function applySQL(file) {
  const source = await readFile(file, "utf8");
  assert.ok(source.trim(), `${path.basename(file)} must not be empty`);
  try {
    await client.query(`BEGIN;\n${source}\nCOMMIT;`);
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw new Error(`${path.basename(file)}: ${error.message}`, { cause: error });
  }
}

async function runTAPSuite(file) {
  const source = await readFile(file, "utf8");
  assert.ok(source.trim(), "the SQL TAP suite must not be empty");
  const result = await client.query(source);
  const results = Array.isArray(result) ? result : [result];
  const lines = results.flatMap((queryResult) => queryResult.rows.flatMap((row) => (
    Object.values(row).flatMap((value) => (
      typeof value === "string" ? value.split(/\r?\n/) : []
    ))
  ))).filter((line) => /^(?:1\.\.\d+|(?:not )?ok \d+(?:\s|$)|#|Bail out!)/.test(line));
  for (const line of lines) console.log(line);
  assert.ok(!lines.some((line) => /^Bail out!/.test(line)), "the SQL TAP suite bailed out");
  const plans = lines.filter((line) => /^1\.\.\d+$/.test(line));
  assert.equal(plans.length, 1, "the SQL TAP suite must emit exactly one plan");
  const expected = Number(plans[0].slice(3));
  assert.ok(expected > 0, "the SQL TAP suite must contain assertions");
  const assertions = lines.filter((line) => /^(?:not )?ok \d+(?:\s|$)/.test(line));
  assert.equal(assertions.length, expected, "SQL TAP assertion count must match its plan");
  assertions.forEach((line, index) => {
    const [, number] = line.match(/^(?:not )?ok (\d+)/);
    assert.equal(Number(number), index + 1, "SQL TAP assertion numbers must be sequential");
  });
  assert.ok(!assertions.some((line) => /^not ok /.test(line)), "one or more SQL authorization assertions failed");
  console.log(`PASS: ${expected} SQL authorization and integrity assertions`);
}

async function runConcurrencySuite(connectionString) {
  const child = spawn(process.execPath, [path.join(workspace, "scripts", "test-concurrency.mjs")], {
    cwd: workspace,
    env: { ...process.env, TEST_DATABASE_URL: connectionString },
    stdio: "inherit",
    windowsHide: true,
    timeout: 120_000,
  });
  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`concurrency tests failed (exit ${code ?? "none"}, signal ${signal ?? "none"})`));
    });
  });
}

async function authenticateFixture(userId) {
  await client.query("SET LOCAL ROLE authenticated");
  await client.query(
    `SELECT set_config('request.jwt.claim.sub', $1, true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('request.jwt.claims', $2, true)`,
    [userId, JSON.stringify({ sub: userId, role: "authenticated" })],
  );
}

async function expectSQLState(sql, parameters, expectedState) {
  await client.query("SAVEPOINT expected_failure");
  let failure;
  try {
    await client.query(sql, parameters);
  } catch (error) {
    failure = error;
  } finally {
    // Even an unexpected successful mutation is discarded.
    await client.query("ROLLBACK TO SAVEPOINT expected_failure");
    await client.query("RELEASE SAVEPOINT expected_failure");
  }
  assert.ok(failure, `expected SQLSTATE ${expectedState}, but the statement succeeded`);
  assert.equal(failure.code, expectedState, failure.message);
}

async function insertDevelopmentFixture(userId) {
  await client.query(
    `INSERT INTO auth.users (id, aud, role, email, raw_user_meta_data)
     VALUES ($1, 'authenticated', 'authenticated', $2, '{"display_name":"Development guard fixture"}')`,
    [userId, `development-${userId}@example.invalid`],
  );
}

async function assertDevelopmentRPCIsAbsent(expectedEnvironment) {
  const query =
    "SELECT to_regprocedure('public.create_development_roll(text,integer,integer,text)') IS NULL AS public_absent, " +
    "to_regprocedure('private.create_development_roll(text,integer,integer,text)') IS NULL AS private_absent, " +
    "(SELECT NOT is_development FROM private.project_settings WHERE singleton) AS disabled, " +
    "(SELECT project_environment FROM private.project_settings WHERE singleton) AS project_environment";
  const { rows } = await client.query(query);
  assert.equal(rows[0].public_absent, true);
  assert.equal(rows[0].private_absent, true);
  assert.equal(rows[0].disabled, true);
  if (expectedEnvironment !== undefined) {
    assert.equal(rows[0].project_environment, expectedEnvironment);
  }
}

async function assertDevelopmentEnableFails(sql, expectedState, label) {
  let failure;
  try {
    await client.query(sql);
  } catch (error) {
    failure = error;
  }
  if (failure) await client.query("ROLLBACK");
  assert.ok(failure, label + ": expected SQLSTATE " + expectedState + ", but the script succeeded");
  assert.equal(failure.code, expectedState, label + ": " + failure.message);
}

async function runDevelopmentGuards() {
  const userId = randomUUID();
  await assertDevelopmentRPCIsAbsent("unknown");
  await client.query("BEGIN");
  try {
    await insertDevelopmentFixture(userId);
    await authenticateFixture(userId);
    await expectSQLState(
      "UPDATE private.project_settings SET is_development = true WHERE singleton",
      [],
      "42501",
    );
    await expectSQLState(
      "UPDATE private.project_settings SET project_environment = 'development' WHERE singleton",
      [],
      "42501",
    );
  } finally {
    await client.query("ROLLBACK");
  }
  console.log("PASS: unknown projects default closed; authenticated users cannot enable or classify development");
  await client.query("BEGIN");
  try {
    await expectSQLState(
      "UPDATE private.project_settings SET project_environment = 'staging' WHERE singleton",
      [],
      "23514",
    );
  } finally {
    await client.query("ROLLBACK");
  }
  console.log("PASS: unrecognized project environment values are rejected");

  const enableFile = path.join(workspace, "supabase", "dev", "enable_test_development.sql");
  const disableFile = path.join(workspace, "supabase", "dev", "disable_test_development.sql");
  const markDevelopmentFile = path.join(workspace, "supabase", "dev", "mark_development_environment.sql");
  const enableSql = await readFile(enableFile, "utf8");
  const disableSql = await readFile(disableFile, "utf8");
  const markDevelopmentSql = await readFile(markDevelopmentFile, "utf8");

  await assertDevelopmentEnableFails(enableSql, "42501", "unknown project enable");
  await assertDevelopmentRPCIsAbsent("unknown");
  console.log("PASS: an unknown/default project cannot enable or create development RPCs");

  // Simulate a missing project marker row. A failed enable must leave both the
  // setting and test RPCs absent; restore the disposable fixture afterward.
  await client.query("DELETE FROM private.project_settings WHERE singleton");
  await assertDevelopmentEnableFails(enableSql, "42501", "missing project marker enable");
  await assertDevelopmentEnableFails(markDevelopmentSql, "42501", "missing project marker classification");
  const missingMarkerQuery =
    "SELECT to_regprocedure('public.create_development_roll(text,integer,integer,text)') IS NULL AS public_absent, " +
    "to_regprocedure('private.create_development_roll(text,integer,integer,text)') IS NULL AS private_absent, " +
    "count(*) = 0 AS marker_absent FROM private.project_settings";
  const { rows: missingMarker } = await client.query(missingMarkerQuery);
  assert.equal(missingMarker[0].public_absent, true);
  assert.equal(missingMarker[0].private_absent, true);
  assert.equal(missingMarker[0].marker_absent, true);
  await client.query(
    "INSERT INTO private.project_settings (singleton, is_development, project_environment) VALUES (true, false, 'unknown')",
  );
  await assertDevelopmentRPCIsAbsent("unknown");
  console.log("PASS: a missing project marker fails before state changes or test RPC creation");

  // This admin-only marker is a deliberate, separate opt-in from enabling the
  // shortened-duration RPCs.
  await client.query(markDevelopmentSql);
  const { rows: markedDevelopment } = await client.query(
    "SELECT project_environment, is_development FROM private.project_settings WHERE singleton",
  );
  assert.equal(markedDevelopment[0].project_environment, "development");
  assert.equal(markedDevelopment[0].is_development, false);
  await client.query(enableSql);

  await client.query("BEGIN");
  try {
    await insertDevelopmentFixture(userId);
    await authenticateFixture(userId);
    for (const seconds of [30, 300, 3600, 604800]) {
      const { rows } = await client.query(
        "SELECT * FROM public.create_development_roll($1, $2)",
        [`Duration fixture ${seconds}`, seconds],
      );
      assert.equal(rows.length, 1);
      assert.equal(rows[0].development_seconds, seconds);
      assert.equal(rows[0].total_exposures, 32);
    }
    await expectSQLState(
      "SELECT * FROM public.create_development_roll('Invalid duration', 1)",
      [],
      "22023",
    );
    const { rows: ordinary } = await client.query("SELECT * FROM public.create_roll('Ordinary duration fixture')");
    assert.equal(ordinary[0].development_seconds, 604800);
    console.log("PASS: development allows only 30s, 5m, 1h, and 7d; ordinary rolls retain seven days");

    await client.query("RESET ROLE");
    await client.query("UPDATE private.project_settings SET is_development = false WHERE singleton");
    await authenticateFixture(userId);
    await expectSQLState(
      "SELECT * FROM public.create_development_roll('Disabled development fixture', 30)",
      [],
      "42501",
    );
    const { rows: disabledRoll } = await client.query(
      "SELECT * FROM public.create_roll('Disabled development override fixture')",
    );
    await client.query("RESET ROLE");
    await expectSQLState(
      "UPDATE public.rolls SET development_speed = 'test_30s', development_seconds = 30 WHERE id = $1",
      [disabledRoll[0].id],
      "42501",
    );
    console.log("PASS: disabling the flag blocks both the RPC and direct shortened roll settings");
  } finally {
    // Rolls, memberships, and the auth/profile fixture all belong to this transaction.
    await client.query("ROLLBACK");
  }

  // The enable script is expected to have installed the RPCs; the disable
  // script must remove them, clear the override, and tolerate a repeated run.
  await client.query(disableSql);
  await assertDevelopmentRPCIsAbsent("development");
  await client.query(disableSql);
  await assertDevelopmentRPCIsAbsent("development");
  console.log("PASS: disabling is idempotent and restores the fail-closed roll guard");

  await client.query(
    "UPDATE private.project_settings SET project_environment = 'production' WHERE singleton",
  );
  await assertDevelopmentEnableFails(enableSql, "42501", "production project enable");
  await assertDevelopmentRPCIsAbsent("production");
  await assertDevelopmentEnableFails(markDevelopmentSql, "42501", "production reclassification");
  await assertDevelopmentRPCIsAbsent("production");
  await client.query("BEGIN");
  try {
    await expectSQLState(
      "UPDATE private.project_settings SET is_development = true WHERE singleton",
      [],
      "42501",
    );
    await expectSQLState(
      "UPDATE private.project_settings SET project_environment = 'development' WHERE singleton",
      [],
      "42501",
    );
  } finally {
    await client.query("ROLLBACK");
  }
  await assertDevelopmentRPCIsAbsent("production");
  console.log("PASS: production projects fail closed and cannot be reclassified as development");
}

async function removeOwnDirectory() {
  if (!runDirectory) return;
  // Resolve and check the exact absolute target immediately before recursive deletion.
  const target = await realpath(runDirectory);
  assertInside(workspace, target);
  assertInside(verifiedRoot, target);
  assert.equal(path.dirname(target), verifiedRoot, "cleanup must remove only this run's direct child directory");
  assert.ok(path.basename(target).startsWith("postgres-"));
  await rm(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}

async function main() {
  try {
    await mkdir(verificationRoot, { recursive: true });
    verifiedRoot = await realpath(verificationRoot);
    assertInside(workspace, verifiedRoot);
    runDirectory = await mkdtemp(path.join(verifiedRoot, "postgres-"));
    assertInside(verifiedRoot, await realpath(runDirectory));
    pgCtlExecutable = await resolvePgCtlExecutable();
    const port = await allocateLoopbackPort();
    const password = randomBytes(24).toString("hex");
    database = new EmbeddedPostgres({
      databaseDir: runDirectory,
      user: "postgres",
      password,
      port,
      authMethod: "scram-sha-256",
      persistent: true,
      createPostgresUser: false,
      postgresFlags: ["-c", "listen_addresses=127.0.0.1"],
      onLog: captureServerLog,
      onError: captureServerLog,
    });
    // embedded-postgres uses taskkill on Windows. Its exit hook dispatches to
    // this instance method, so use a bounded, graceful, directory-scoped stop.
    database.stop = stopIsolatedDatabase;
    await database.initialise();
    await database.start();
    started = true;
    client = database.getPgClient("postgres", "127.0.0.1");
    await client.connect();
    await client.query("SET statement_timeout = '30s'");
    const { rows } = await client.query("SHOW server_version");
    console.log(`Native PostgreSQL ${rows[0].server_version}; minimal Supabase SQL stand-ins, no Storage HTTP service.`);

    stage = "bootstrapping isolated auth and storage SQL stand-ins";
    await applySQL(path.join(workspace, "scripts", "standalone-bootstrap.sql"));
    const migrationDirectory = path.join(workspace, "supabase", "migrations");
    const migrations = (await readdir(migrationDirectory)).filter((name) => name.endsWith(".sql")).sort();
    assert.ok(migrations.length > 0, "at least one database migration is required");
    for (const migration of migrations) {
      stage = `applying ${migration}`;
      await applySQL(path.join(migrationDirectory, migration));
      console.log(`PASS: migration ${migration}`);
    }

    stage = "running the SQL authorization suite";
    await runTAPSuite(path.join(workspace, "supabase", "tests", "database", "film_backend.test.sql"));
    stage = "running overlapping PostgreSQL concurrency scenarios";
    await runConcurrencySuite(`postgres://postgres:${password}@127.0.0.1:${port}/postgres`);
    stage = "checking development-only duration controls";
    await runDevelopmentGuards();
  } catch (error) {
    process.exitCode = 1;
    console.error(`FAIL: ${stage}: ${error?.message ?? String(error)}`);
    if (!started && serverLogs.length > 0) {
      console.error(serverLogs.join("\n").slice(-6_000));
    }
  } finally {
    if (client) {
      try {
        await client.query("ROLLBACK");
        await client.end();
      } catch (error) {
        process.exitCode = 1;
        console.error(`FAIL: database client cleanup: ${error.message}`);
      }
    }
    let stopped = !started;
    if (started) {
      try {
        await database.stop();
        stopped = true;
      } catch (error) {
        process.exitCode = 1;
        console.error(`FAIL: PostgreSQL shutdown: ${error.message}`);
      }
    }
    if (stopped) {
      try {
        await removeOwnDirectory();
      } catch (error) {
        process.exitCode = 1;
        console.error(`FAIL: verification directory cleanup: ${error.message}`);
      }
    }
  }
  if (!process.exitCode) console.log("PASS: native PostgreSQL verification complete; isolated database removed");
}

await main();
// embedded-postgres's async-exit-hook handles beforeExit with a fixed exit 0.
// Cleanup is already awaited; flush diagnostics and exit with the actual result.
const finalExitCode = process.exitCode ?? 0;
await Promise.all([process.stdout, process.stderr].map((stream) => (
  new Promise((resolve) => stream.write("", resolve))
)));
process.exit(finalExitCode);
