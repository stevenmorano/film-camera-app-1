import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import pg from "pg";

const { Client } = pg;
const databaseURL = process.env.TEST_DATABASE_URL
  ?? "postgres://postgres:postgres@127.0.0.1:54322/postgres";
const endpoint = new URL(databaseURL);
const hostname = endpoint.hostname.replace(/^\[|\]$/g, "").toLowerCase();

// These tests create and delete fixtures. Never point them at a hosted project.
if (!["localhost", "127.0.0.1", "::1"].includes(hostname)) {
  throw new Error("Concurrency tests require a local PostgreSQL database (localhost, 127.0.0.1, or ::1).");
}

const runId = randomUUID();
const ownerId = randomUUID();
const memberId = randomUUID();
const userIds = [ownerId, memberId];
const rollIds = new Set();
const clients = new Set();
let admin;
let currentTest = "fixture setup";

async function openClient(label) {
  const client = new Client({
    connectionString: databaseURL,
    application_name: `film-concurrency-${runId.slice(0, 8)}-${label}`,
    connectionTimeoutMillis: 5_000,
  });
  clients.add(client);
  try {
    await client.connect();
    await client.query("SET statement_timeout = '15s'");
    return client;
  } catch (error) {
    await closeClient(client);
    throw error;
  }
}

async function closeClient(client) {
  try {
    await client.end();
  } finally {
    clients.delete(client);
  }
}

async function beginAuthenticated(client, userId) {
  await client.query("BEGIN");
  await client.query("SET LOCAL ROLE authenticated");
  await client.query(
    `SELECT
       set_config('request.jwt.claim.sub', $1, true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('request.jwt.claims', $2, true)`,
    [userId, JSON.stringify({ sub: userId, role: "authenticated" })],
  );
}

async function authenticatedQuery(userId, sql, parameters) {
  const client = await openClient("fixture-action");
  try {
    await beginAuthenticated(client, userId);
    const result = await client.query(sql, parameters);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    await closeClient(client);
  }
}

async function createSharedRoll(name) {
  const { rows } = await authenticatedQuery(
    ownerId,
    "SELECT * FROM public.create_roll($1)",
    [`concurrency-${runId}-${name}`],
  );
  assert.equal(rows.length, 1, "create_roll should return its roll");
  const roll = rows[0];
  rollIds.add(roll.id);
  assert.equal(roll.total_exposures, 32, "a new roll should have 32 exposures");
  assert.equal(roll.exposures_used, 0);
  await admin.query(
    "INSERT INTO public.roll_members (roll_id, user_id, role) VALUES ($1, $2, 'member')",
    [roll.id, memberId],
  );
  return roll;
}

async function claimOnce(rollId, userId, requestId = randomUUID()) {
  const { rows } = await authenticatedQuery(
    userId,
    "SELECT * FROM public.claim_exposure($1::uuid, $2::uuid)",
    [rollId, requestId],
  );
  assert.equal(rows.length, 1, "claim_exposure should return its claim");
  return rows[0];
}

async function waitUntilWorkersAreBlocked(workerPids) {
  const deadline = Date.now() + 5_000;
  let observed = [];
  do {
    // Statistics can be cached within an open transaction; refresh before polling.
    await admin.query("SELECT pg_stat_clear_snapshot()");
    const { rows } = await admin.query(
      "SELECT pid, state, wait_event_type FROM pg_stat_activity WHERE pid = ANY($1::int[])",
      [workerPids],
    );
    observed = rows;
    if (rows.length === workerPids.length
      && rows.every((row) => row.state === "active" && row.wait_event_type === "Lock")) {
      return;
    }
    await delay(25);
  } while (Date.now() < deadline);
  assert.fail(`Expected both claim workers to wait on the held roll lock; observed ${JSON.stringify(observed)}`);
}

async function runClaimAndCommit(client, rollId, requestId) {
  try {
    const { rows } = await client.query(
      "SELECT * FROM public.claim_exposure($1::uuid, $2::uuid)",
      [rollId, requestId],
    );
    assert.equal(rows.length, 1, "claim_exposure should return its claim");
    await client.query("COMMIT");
    return { status: "fulfilled", value: rows[0] };
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    return { status: "rejected", reason: error };
  }
}

async function runLockedRace(rollId, requests) {
  const workers = [];
  let adminLockIsOpen = false;
  let pending = [];
  try {
    for (let index = 0; index < requests.length; index += 1) {
      const client = await openClient(`worker-${index}`);
      workers.push(client);
      await beginAuthenticated(client, requests[index].userId);
    }
    const workerPids = await Promise.all(workers.map(async (client) => {
      const { rows } = await client.query("SELECT pg_backend_pid() AS pid");
      return rows[0].pid;
    }));
    await admin.query("BEGIN");
    adminLockIsOpen = true;
    const locked = await admin.query(
      "SELECT id FROM public.rolls WHERE id = $1::uuid FOR UPDATE",
      [rollId],
    );
    assert.equal(locked.rowCount, 1, "race fixture should exist");
    pending = workers.map((client, index) => (
      runClaimAndCommit(client, rollId, requests[index].requestId)
    ));
    await waitUntilWorkersAreBlocked(workerPids);
    await admin.query("COMMIT");
    adminLockIsOpen = false;
    return await Promise.all(pending);
  } finally {
    if (adminLockIsOpen) {
      await admin.query("ROLLBACK").catch(() => {});
    }
    // Releasing the lock lets every query settle before disconnecting workers.
    await Promise.all(pending);
    for (const worker of workers) {
      await worker.query("ROLLBACK").catch(() => {});
      await closeClient(worker);
    }
  }
}

async function readCounters(rollId) {
  const { rows: rolls } = await admin.query(
    "SELECT total_exposures, exposures_used FROM public.rolls WHERE id = $1::uuid",
    [rollId],
  );
  const { rows: memberships } = await admin.query(
    "SELECT user_id, exposures_used FROM public.roll_members WHERE roll_id = $1::uuid",
    [rollId],
  );
  const { rows: claims } = await admin.query(
    "SELECT id, photographer_id, exposure_number FROM public.exposure_claims WHERE roll_id = $1::uuid ORDER BY exposure_number",
    [rollId],
  );
  assert.equal(rolls.length, 1);
  assert.equal(memberships.length, 2);
  assert.equal(
    memberships.reduce((sum, membership) => sum + membership.exposures_used, 0),
    rolls[0].exposures_used,
    "member counters should agree with the shared roll counter",
  );
  assert.equal(claims.length, rolls[0].exposures_used, "each consumed slot should have one claim");
  return { roll: rolls[0], memberships, claims };
}

function successfulClaims(outcomes) {
  for (const outcome of outcomes) {
    if (outcome.status === "rejected") {
      throw outcome.reason;
    }
  }
  return outcomes.map((outcome) => outcome.value);
}

async function testDistinctConcurrentClaims() {
  const roll = await createSharedRoll("distinct");
  const claims = successfulClaims(await runLockedRace(roll.id, [
    { userId: ownerId, requestId: randomUUID() },
    { userId: memberId, requestId: randomUUID() },
  ]));
  assert.notEqual(claims[0].id, claims[1].id);
  assert.deepEqual(claims.map((claim) => claim.exposure_number).sort((a, b) => a - b), [1, 2]);
  const counters = await readCounters(roll.id);
  assert.equal(counters.roll.exposures_used, 2);
  assert.ok(counters.memberships.every((membership) => membership.exposures_used === 1));
}

async function testFinalSlotRace() {
  const roll = await createSharedRoll("final-slot");
  for (let index = 0; index < roll.total_exposures - 1; index += 1) {
    await claimOnce(roll.id, ownerId);
  }
  const outcomes = await runLockedRace(roll.id, [
    { userId: ownerId, requestId: randomUUID() },
    { userId: memberId, requestId: randomUUID() },
  ]);
  const succeeded = outcomes.filter((outcome) => outcome.status === "fulfilled");
  const failed = outcomes.filter((outcome) => outcome.status === "rejected");
  assert.equal(succeeded.length, 1, "exactly one member should secure the final slot");
  assert.equal(failed.length, 1, "the other member should receive a capacity error");
  assert.equal(failed[0].reason.code, "P0001", "the losing request should receive the capacity error SQLSTATE");
  assert.equal(failed[0].reason.message, "No exposures remain.");
  assert.equal(succeeded[0].value.exposure_number, roll.total_exposures);
  const counters = await readCounters(roll.id);
  assert.equal(counters.roll.exposures_used, counters.roll.total_exposures);
  assert.deepEqual(
    counters.claims.map((claim) => claim.exposure_number),
    Array.from({ length: roll.total_exposures }, (_, index) => index + 1),
  );
}

async function testConcurrentDuplicateRequest() {
  const roll = await createSharedRoll("duplicate");
  const requestId = randomUUID();
  const claims = successfulClaims(await runLockedRace(roll.id, [
    { userId: ownerId, requestId },
    { userId: ownerId, requestId },
  ]));
  assert.equal(claims[0].id, claims[1].id, "duplicate requests should return the original claim");
  assert.equal(claims[0].exposure_number, 1);
  assert.equal(claims[0].storage_path, claims[1].storage_path);
  const retry = await claimOnce(roll.id, ownerId, requestId);
  assert.equal(retry.id, claims[0].id, "a subsequent retry should preserve the same claim");
  const counters = await readCounters(roll.id);
  assert.equal(counters.roll.exposures_used, 1);
  assert.equal(counters.memberships.find((membership) => membership.user_id === ownerId).exposures_used, 1);
  assert.equal(counters.memberships.find((membership) => membership.user_id === memberId).exposures_used, 0);
}

async function cleanupFixtures() {
  await admin.query("ROLLBACK");
  await admin.query("BEGIN");
  try {
    const ids = [...rollIds];
    if (ids.length > 0) {
      // Explicit IDs belong only to this run; existing local user data is untouched.
      for (const table of ["film_photos", "invitations", "exposure_claims", "roll_members", "rolls"]) {
        const idColumn = table === "rolls" ? "id" : "roll_id";
        await admin.query(`DELETE FROM public.${table} WHERE ${idColumn} = ANY($1::uuid[])`, [ids]);
      }
    }
    await admin.query("DELETE FROM auth.users WHERE id = ANY($1::uuid[])", [userIds]);
    await admin.query("COMMIT");
  } catch (error) {
    await admin.query("ROLLBACK").catch(() => {});
    throw error;
  }
}

async function main() {
  try {
    admin = await openClient("admin");
    for (const [index, id] of userIds.entries()) {
      await admin.query(
        `INSERT INTO auth.users
          (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
         VALUES ($1, 'authenticated', 'authenticated', $2, $3::jsonb, $4::jsonb, now(), now())`,
        [
          id,
          `concurrency-${runId}-${index}@example.invalid`,
          JSON.stringify({ provider: "email", providers: ["email"] }),
          JSON.stringify({ display_name: `Concurrency fixture ${index}` }),
        ],
      );
    }
    const scenarios = [
      ["distinct overlapping claims allocate unique slots and update counters", testDistinctConcurrentClaims],
      ["the final-slot race cannot exceed roll capacity", testFinalSlotRace],
      ["simultaneous and subsequent duplicate requests consume one slot", testConcurrentDuplicateRequest],
    ];
    for (const [name, scenario] of scenarios) {
      currentTest = name;
      await scenario();
      console.log(`PASS: ${name}`);
    }
  } catch (error) {
    process.exitCode = 1;
    console.error(`FAIL: ${currentTest}: ${error.message}`);
  } finally {
    if (admin) {
      try {
        await cleanupFixtures();
      } catch (error) {
        process.exitCode = 1;
        console.error(`FAIL: fixture cleanup: ${error.message}`);
      }
    }
    for (const client of [...clients]) {
      try {
        await closeClient(client);
      } catch (error) {
        process.exitCode = 1;
        console.error(`FAIL: client disconnect: ${error.message}`);
      }
    }
  }
  if (!process.exitCode) {
    console.log("PASS: all concurrency scenarios; fixtures removed");
  }
}

await main();
