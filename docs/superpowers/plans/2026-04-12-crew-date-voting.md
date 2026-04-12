# Crew Date Voting & Group-Text Share — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared voting loop so the crew enters availability via a link sent to a group text, Claude picks a consensus date, and the organizer locks the plan and re-shares it to the group.

**Architecture:** Extend the existing `sorted-api` Express server (Railway) with persistent plans stored in Cloudflare KV (REST API). The frontend (`sorted/index.html`) gains organizer share/final screens and a voter flow that activates when the URL contains `?p={planId}`. A single `index.html` serves both organizer and voter flows; routing is decided at load time by the presence of the query param.

**Tech Stack:** Node 18+ / Express 4 (sorted-api, Railway), vanilla HTML/CSS/JS (sorted, Cloudflare Pages), Cloudflare KV (REST API), Anthropic Messages API (Claude sonnet-4-6), `node:test` for backend unit tests.

**Spec:** `docs/superpowers/specs/2026-04-12-crew-date-voting-design.md`

---

## Environment setup (one-time, before Task 1)

Before writing code, make sure these are set as environment variables on the Railway deployment of `sorted-api` (and in a local `.env` for development):

- `CLOUDFLARE_ACCOUNT_ID` — `1296578b4a5d7b3a297c771d22ab280f`
- `CLOUDFLARE_KV_NAMESPACE_ID` — created via the Cloudflare dashboard: **Workers & Pages → KV → Create namespace → `grip-it-plans`** (or via wrangler: `wrangler kv namespace create grip-it-plans`). Copy the returned namespace ID.
- `CLOUDFLARE_API_TOKEN` — a scoped token with **Account → Workers KV Storage → Edit** permission on the account above. Create at `https://dash.cloudflare.com/profile/api-tokens`.

Per `CLAUDE.md`, do not hardcode these. Production values go in **Railway Variables**.

---

## File Structure

**sorted-api (backend, Railway-deployed Express):**

- `index.js` — existing entrypoint. Mount the new router, add the new env-var check. No other changes.
- `kvStore.js` — **new.** Thin wrapper over Cloudflare KV REST. Exports `putPlan(id, plan, ttlSeconds)`, `getPlan(id)`. One responsibility: KV I/O.
- `consensus.js` — **new.** Pure functions: `buildConsensusPrompt(plan, todayISO)` → string, `parseConsensusResponse(rawText)` → `{ date, reasoning }` (throws on bad JSON / missing fields).
- `planBuilder.js` — **new.** Pure functions: `buildPlanPrompt(plan, lockedDate)` → string, `parsePlanResponse(rawText)` → per-person plans array.
- `planRoutes.js` — **new.** Express router that wires `kvStore`, `consensus`, `planBuilder`, and the existing Claude-call pattern into the four plan endpoints. One responsibility: HTTP handling + orchestration.
- `tests/kvStore.test.js` — **new.** Mocks `fetch`; asserts KV REST request shape.
- `tests/consensus.test.js` — **new.** Pure-function unit tests for prompt building and response parsing.
- `tests/planBuilder.test.js` — **new.** Pure-function unit tests.
- `tests/planRoutes.test.js` — **new.** Supertest-style integration over the router with `kvStore` mocked.
- `scripts/smoke-plan.sh` — **new.** End-to-end curl smoke test against a running server.

**sorted (frontend, Cloudflare Pages):**

- `index.html` — existing single-file app. All changes land here:
  - `s-crew`: add phone input per row; `phones[]` global.
  - `s-loc`: replace date-picker + `date-options` block with free-text availability textbox; remove `voteMode`, `toggleDateOptions`, `date-opt-1/2/3`.
  - `s-results`: picking an activity now calls `POST /api/plan` and routes to `s-share`.
  - `s-share`: **new.** Activity pitch, "Send to group text", waiting dashboard with polling, "Lock it in".
  - `s-final`: **new.** Locked date + reasoning + per-person plan; "Send plan to group text" + existing "Copy all plans".
  - `v-vote`, `v-thanks`, `v-final`: **new.** Voter flow screens.
  - JS: `planId`, `availability`, `phones[]` globals; URL-param router at load; `smsHref(phones, body)` helper; `pollPlan()` interval; `renderDashboard(plan)`, `renderFinalPlan(plan)`.

---

## Task 1: Scaffold KV helper with failing tests

**Files:**
- Create: `/Users/everettsteele/PROJECTS/sorted-api/kvStore.js`
- Create: `/Users/everettsteele/PROJECTS/sorted-api/tests/kvStore.test.js`
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/package.json` (add `"test": "node --test tests/"` script)

- [ ] **Step 1: Add the test script to `package.json`**

Edit `/Users/everettsteele/PROJECTS/sorted-api/package.json` so the `scripts` block becomes:

```json
"scripts": {
  "start": "node index.js",
  "test": "node --test tests/"
}
```

- [ ] **Step 2: Write the failing tests**

Create `/Users/everettsteele/PROJECTS/sorted-api/tests/kvStore.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert/strict');

process.env.CLOUDFLARE_ACCOUNT_ID = 'acct-123';
process.env.CLOUDFLARE_KV_NAMESPACE_ID = 'ns-456';
process.env.CLOUDFLARE_API_TOKEN = 'token-789';

const { putPlan, getPlan } = require('../kvStore');

function stubFetch(responder) {
  const calls = [];
  global.fetch = async (url, opts) => {
    calls.push({ url, opts });
    return responder({ url, opts });
  };
  return calls;
}

test('putPlan calls Cloudflare KV REST with correct URL, method, auth, body, and TTL', async () => {
  const calls = stubFetch(() => new Response('{"success":true}', { status: 200 }));
  const plan = { id: 'abc', crewName: 'Crew' };

  await putPlan('abc', plan, 3600);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.cloudflare.com/client/v4/accounts/acct-123/storage/kv/namespaces/ns-456/values/abc?expiration_ttl=3600');
  assert.equal(calls[0].opts.method, 'PUT');
  assert.equal(calls[0].opts.headers.Authorization, 'Bearer token-789');
  assert.equal(calls[0].opts.headers['Content-Type'], 'application/json');
  assert.equal(calls[0].opts.body, JSON.stringify(plan));
});

test('putPlan throws on non-2xx', async () => {
  stubFetch(() => new Response('{"success":false,"errors":[{"message":"nope"}]}', { status: 500 }));
  await assert.rejects(() => putPlan('abc', { id: 'abc' }, 3600), /KV put failed/);
});

test('getPlan returns parsed JSON on 200', async () => {
  stubFetch(() => new Response(JSON.stringify({ id: 'abc', crewName: 'Crew' }), { status: 200 }));
  const plan = await getPlan('abc');
  assert.deepEqual(plan, { id: 'abc', crewName: 'Crew' });
});

test('getPlan returns null on 404', async () => {
  stubFetch(() => new Response('{"success":false}', { status: 404 }));
  const plan = await getPlan('abc');
  assert.equal(plan, null);
});

test('getPlan throws on other non-2xx', async () => {
  stubFetch(() => new Response('{"success":false}', { status: 500 }));
  await assert.rejects(() => getPlan('abc'), /KV get failed/);
});
```

- [ ] **Step 3: Run the tests and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: FAIL — `Cannot find module '../kvStore'`.

- [ ] **Step 4: Implement `kvStore.js`**

Create `/Users/everettsteele/PROJECTS/sorted-api/kvStore.js`:

```js
const ACCOUNT = () => process.env.CLOUDFLARE_ACCOUNT_ID;
const NAMESPACE = () => process.env.CLOUDFLARE_KV_NAMESPACE_ID;
const TOKEN = () => process.env.CLOUDFLARE_API_TOKEN;

function base(key) {
  return `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT()}/storage/kv/namespaces/${NAMESPACE()}/values/${encodeURIComponent(key)}`;
}

async function putPlan(id, plan, ttlSeconds) {
  const res = await fetch(`${base(id)}?expiration_ttl=${ttlSeconds}`, {
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${TOKEN()}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(plan)
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`KV put failed (${res.status}): ${body}`);
  }
}

async function getPlan(id) {
  const res = await fetch(base(id), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${TOKEN()}` }
  });
  if (res.status === 404) return null;
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`KV get failed (${res.status}): ${body}`);
  }
  return res.json();
}

module.exports = { putPlan, getPlan };
```

- [ ] **Step 5: Run the tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: all 5 kvStore tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add kvStore.js tests/kvStore.test.js package.json
git commit -m "feat: Cloudflare KV helper for plan persistence"
```

---

## Task 2: Consensus prompt + response parser

**Files:**
- Create: `/Users/everettsteele/PROJECTS/sorted-api/consensus.js`
- Create: `/Users/everettsteele/PROJECTS/sorted-api/tests/consensus.test.js`

- [ ] **Step 1: Write the failing tests**

Create `/Users/everettsteele/PROJECTS/sorted-api/tests/consensus.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildConsensusPrompt, parseConsensusResponse } = require('../consensus');

test('buildConsensusPrompt includes today, crew names, and every availability string', () => {
  const plan = {
    crewName: 'ABC Dads',
    votes: [
      { name: 'Mark', availability: 'any Saturday after 1pm', at: 0 },
      { name: 'Dave', availability: 'not 4/25, otherwise weekends work', at: 0 }
    ],
    activity: { name: 'Skeet shooting' },
    city: 'Atlanta'
  };
  const prompt = buildConsensusPrompt(plan, '2026-04-12');

  assert.match(prompt, /2026-04-12/);
  assert.match(prompt, /Mark: any Saturday after 1pm/);
  assert.match(prompt, /Dave: not 4\/25, otherwise weekends work/);
  assert.match(prompt, /Skeet shooting/);
  assert.match(prompt, /Atlanta/);
  assert.match(prompt, /"date"/);
  assert.match(prompt, /"reasoning"/);
});

test('parseConsensusResponse parses clean JSON', () => {
  const raw = '{"date":"2026-04-18","reasoning":"Only Saturday everyone can make."}';
  assert.deepEqual(parseConsensusResponse(raw), { date: '2026-04-18', reasoning: 'Only Saturday everyone can make.' });
});

test('parseConsensusResponse strips ```json fences', () => {
  const raw = '```json\n{"date":"2026-04-18","reasoning":"Good."}\n```';
  assert.deepEqual(parseConsensusResponse(raw), { date: '2026-04-18', reasoning: 'Good.' });
});

test('parseConsensusResponse throws on invalid JSON', () => {
  assert.throws(() => parseConsensusResponse('not json'), /consensus: invalid JSON/);
});

test('parseConsensusResponse throws on wrong date shape', () => {
  assert.throws(() => parseConsensusResponse('{"date":"next Saturday","reasoning":"x"}'), /consensus: bad date format/);
});

test('parseConsensusResponse throws on missing reasoning', () => {
  assert.throws(() => parseConsensusResponse('{"date":"2026-04-18"}'), /consensus: missing reasoning/);
});
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test -- --test-name-pattern='buildConsensusPrompt|parseConsensusResponse'
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement `consensus.js`**

Create `/Users/everettsteele/PROJECTS/sorted-api/consensus.js`:

```js
function buildConsensusPrompt(plan, todayISO) {
  const crewLines = plan.votes
    .map(v => `- ${v.name}: ${v.availability}`)
    .join('\n');
  return `Today's date is ${todayISO}. A crew is planning "${plan.activity.name}" in ${plan.city}. Pick one specific calendar date (YYYY-MM-DD) that maximizes attendance based on each person's availability. If nothing aligns perfectly, pick the best compromise and say why in one sentence.

Crew availability:
${crewLines}

Return ONLY a JSON object, no prose, no fences:
{"date":"YYYY-MM-DD","reasoning":"<one sentence>"}`;
}

function parseConsensusResponse(rawText) {
  const cleaned = rawText.replace(/```json|```/g, '').trim();
  let obj;
  try { obj = JSON.parse(cleaned); }
  catch { throw new Error('consensus: invalid JSON'); }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(obj.date || '')) throw new Error('consensus: bad date format');
  if (!obj.reasoning || typeof obj.reasoning !== 'string') throw new Error('consensus: missing reasoning');
  return { date: obj.date, reasoning: obj.reasoning };
}

module.exports = { buildConsensusPrompt, parseConsensusResponse };
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: all consensus tests pass (plus prior kvStore tests still green).

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add consensus.js tests/consensus.test.js
git commit -m "feat: consensus prompt builder and response parser"
```

---

## Task 3: Plan-builder prompt + response parser

**Files:**
- Create: `/Users/everettsteele/PROJECTS/sorted-api/planBuilder.js`
- Create: `/Users/everettsteele/PROJECTS/sorted-api/tests/planBuilder.test.js`

- [ ] **Step 1: Write the failing tests**

Create `/Users/everettsteele/PROJECTS/sorted-api/tests/planBuilder.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildPlanPrompt, parsePlanResponse } = require('../planBuilder');

const plan = {
  crewName: 'ABC Dads',
  crew: [{ name: 'Mark' }, { name: 'Dave' }],
  city: 'Atlanta',
  driveDistance: 2,
  vibe: { adventure: 3, risk: 2, cost: 2 },
  activity: { name: 'Skeet shooting', blurb: 'Shoot clays at Big Red Oak.' }
};

test('buildPlanPrompt bakes in the locked date, crew names, activity, and city', () => {
  const prompt = buildPlanPrompt(plan, '2026-04-18');
  assert.match(prompt, /2026-04-18/);
  assert.match(prompt, /Mark/);
  assert.match(prompt, /Dave/);
  assert.match(prompt, /Skeet shooting/);
  assert.match(prompt, /Atlanta/);
});

test('parsePlanResponse parses an array of per-person plans', () => {
  const raw = '[{"name":"Mark","driveTime":"20 min","bring":"eye pro","notes":"meet at 1pm"},{"name":"Dave","driveTime":"35 min","bring":"cash","notes":"drive north"}]';
  const parsed = parsePlanResponse(raw);
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0].name, 'Mark');
  assert.equal(parsed[1].driveTime, '35 min');
});

test('parsePlanResponse strips code fences', () => {
  const raw = '```json\n[{"name":"Mark"}]\n```';
  assert.deepEqual(parsePlanResponse(raw), [{ name: 'Mark' }]);
});

test('parsePlanResponse throws on non-array result', () => {
  assert.throws(() => parsePlanResponse('{"name":"Mark"}'), /planBuilder: expected array/);
});

test('parsePlanResponse throws on invalid JSON', () => {
  assert.throws(() => parsePlanResponse('nope'), /planBuilder: invalid JSON/);
});
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: FAIL — `Cannot find module '../planBuilder'`.

- [ ] **Step 3: Implement `planBuilder.js`**

Create `/Users/everettsteele/PROJECTS/sorted-api/planBuilder.js`:

```js
function buildPlanPrompt(plan, lockedDate) {
  const names = plan.crew.map(p => p.name).join(', ');
  return `Build per-person logistics for a crew day out.

Activity: ${plan.activity.name}
Pitch: ${plan.activity.blurb || ''}
City: ${plan.city}
Date: ${lockedDate}
Crew: ${names}
Drive-distance preference (1-5, 5 = longer): ${plan.driveDistance}
Vibe — adventure ${plan.vibe.adventure}/5, risk ${plan.vibe.risk}/5, cost ${plan.vibe.cost}/5

For each person, return:
- name
- driveTime (rough estimate, e.g. "25 min")
- bring (what to bring, ~1 short line)
- notes (weather, timing, anything practical, ~1–2 lines)

Return ONLY a JSON array (no prose, no fences) of objects with keys: name, driveTime, bring, notes.`;
}

function parsePlanResponse(rawText) {
  const cleaned = rawText.replace(/```json|```/g, '').trim();
  let obj;
  try { obj = JSON.parse(cleaned); }
  catch { throw new Error('planBuilder: invalid JSON'); }
  if (!Array.isArray(obj)) throw new Error('planBuilder: expected array');
  return obj;
}

module.exports = { buildPlanPrompt, parsePlanResponse };
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: all planBuilder tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add planBuilder.js tests/planBuilder.test.js
git commit -m "feat: plan-builder prompt and response parser"
```

---

## Task 4: Plan routes — create + get

**Files:**
- Create: `/Users/everettsteele/PROJECTS/sorted-api/planRoutes.js`
- Create: `/Users/everettsteele/PROJECTS/sorted-api/tests/planRoutes.test.js`

- [ ] **Step 1: Write the failing tests**

Create `/Users/everettsteele/PROJECTS/sorted-api/tests/planRoutes.test.js`:

```js
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const http = require('node:http');

// In-memory KV double, injected before requiring planRoutes.
const store = new Map();
require.cache[require.resolve('../kvStore')] = {
  exports: {
    putPlan: async (id, plan) => { store.set(id, plan); },
    getPlan: async (id) => store.get(id) || null
  }
};

const planRoutes = require('../planRoutes');

function startApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/plan', planRoutes);
  return new Promise(resolve => {
    const server = app.listen(0, () => resolve({ server, port: server.address().port }));
  });
}

async function request(port, method, path, body) {
  const res = await fetch(`http://localhost:${port}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, body: json };
}

test('POST /api/plan creates a plan, seeds organizer vote, returns id + url', async () => {
  store.clear();
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/', {
      crewName: 'ABC Dads',
      crew: [{ name: 'Mark', phone: '+15551111' }, { name: 'Dave', phone: '+15552222' }],
      city: 'Atlanta',
      driveDistance: 2,
      vibe: { adventure: 3, risk: 2, cost: 2 },
      activity: { name: 'Skeet shooting', blurb: 'Bang bang.' },
      organizerAvailability: 'any Saturday after 1pm'
    });
    assert.equal(r.status, 200);
    assert.ok(r.body.id && r.body.id.length >= 8);
    assert.ok(r.body.url.includes('?p=' + r.body.id));

    const stored = store.get(r.body.id);
    assert.equal(stored.crewName, 'ABC Dads');
    assert.equal(stored.votes.length, 1);
    assert.equal(stored.votes[0].name, 'Mark');
    assert.equal(stored.votes[0].availability, 'any Saturday after 1pm');
    assert.equal(stored.locked, false);
  } finally { server.close(); }
});

test('POST /api/plan rejects missing phone on a crew row', async () => {
  store.clear();
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/', {
      crewName: 'x',
      crew: [{ name: 'Mark', phone: '' }],
      city: 'Atlanta',
      driveDistance: 2,
      vibe: { adventure: 3, risk: 2, cost: 2 },
      activity: { name: 'x' },
      organizerAvailability: 'any time'
    });
    assert.equal(r.status, 400);
    assert.match(r.body.error, /phone/i);
  } finally { server.close(); }
});

test('GET /api/plan/:id returns the plan with phone numbers stripped', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc',
    crew: [{ name: 'Mark', phone: '+15551111' }, { name: 'Dave', phone: '+15552222' }],
    crewName: 'x', votes: [], locked: false,
    city: 'Atlanta', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' }, finalDate: null, finalReason: null, finalPlan: null
  });
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'GET', '/abc');
    assert.equal(r.status, 200);
    assert.equal(r.body.crew.length, 2);
    assert.equal(r.body.crew[0].phone, undefined);
    assert.equal(r.body.crew[0].name, 'Mark');
  } finally { server.close(); }
});

test('GET /api/plan/:id returns 404 when not found', async () => {
  store.clear();
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'GET', '/nope');
    assert.equal(r.status, 404);
  } finally { server.close(); }
});
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: FAIL — `Cannot find module '../planRoutes'`.

- [ ] **Step 3: Implement create + get in `planRoutes.js`**

Create `/Users/everettsteele/PROJECTS/sorted-api/planRoutes.js`:

```js
const express = require('express');
const crypto = require('node:crypto');
const { putPlan, getPlan } = require('./kvStore');

const router = express.Router();
const TTL_SECONDS = 60 * 60 * 24 * 30; // 30 days

function newId() {
  // 13-char base32-ish: 10 random bytes, base64url, lowercased, alphanumeric-only, first 13 chars
  return crypto.randomBytes(10).toString('base64url').replace(/[^a-zA-Z0-9]/g, '').toLowerCase().slice(0, 13);
}

function publicUrl(req, id) {
  const origin = req.headers.origin || 'https://sorted.neverstill.llc';
  return `${origin}/?p=${id}`;
}

function stripPhones(plan) {
  return { ...plan, crew: plan.crew.map(({ name }) => ({ name })) };
}

router.post('/', async (req, res) => {
  const { crewName, crew, city, driveDistance, vibe, activity, organizerAvailability } = req.body || {};
  if (!Array.isArray(crew) || crew.length === 0) return res.status(400).json({ error: 'crew required' });
  for (const p of crew) {
    if (!p.name || !p.name.trim()) return res.status(400).json({ error: 'every crew row needs a name' });
    if (!p.phone || !p.phone.trim()) return res.status(400).json({ error: 'every crew row needs a phone' });
  }
  if (!city || !activity || !vibe) return res.status(400).json({ error: 'city, activity, vibe required' });
  if (!organizerAvailability || !organizerAvailability.trim()) return res.status(400).json({ error: 'organizerAvailability required' });

  const id = newId();
  const now = Date.now();
  const plan = {
    id, createdAt: now, crewName: crewName || '',
    crew: crew.map(p => ({ name: p.name.trim(), phone: p.phone.trim() })),
    city, driveDistance, vibe, activity,
    votes: [{ name: crew[0].name.trim(), availability: organizerAvailability.trim(), at: now }],
    locked: false, finalDate: null, finalReason: null, finalPlan: null
  };
  await putPlan(id, plan, TTL_SECONDS);
  res.json({ id, url: publicUrl(req, id) });
});

router.get('/:id', async (req, res) => {
  const plan = await getPlan(req.params.id);
  if (!plan) return res.status(404).json({ error: 'plan not found' });
  res.json(stripPhones(plan));
});

module.exports = router;
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm test
```

Expected: all planRoutes create/get tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add planRoutes.js tests/planRoutes.test.js
git commit -m "feat: plan create + get routes"
```

---

## Task 5: Vote route (upsert-by-name)

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/planRoutes.js`
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/tests/planRoutes.test.js`

- [ ] **Step 1: Add failing tests** — append to `tests/planRoutes.test.js`:

```js
test('POST /api/plan/:id/vote inserts a new voter', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }, { name: 'Dave', phone: '+2' }],
    crewName: 'x', city: 'x', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' },
    votes: [{ name: 'Mark', availability: 'any Sat', at: 1 }],
    locked: false, finalDate: null, finalReason: null, finalPlan: null
  });
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/abc/vote', { name: 'Dave', availability: '4/18 works' });
    assert.equal(r.status, 200);
    const stored = store.get('abc');
    assert.equal(stored.votes.length, 2);
    assert.equal(stored.votes[1].name, 'Dave');
    assert.equal(stored.votes[1].availability, '4/18 works');
  } finally { server.close(); }
});

test('POST /api/plan/:id/vote updates an existing voter (upsert by name)', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }],
    crewName: 'x', city: 'x', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' },
    votes: [{ name: 'Mark', availability: 'any Sat', at: 1 }],
    locked: false, finalDate: null, finalReason: null, finalPlan: null
  });
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/abc/vote', { name: 'Mark', availability: 'actually, Sundays work too' });
    assert.equal(r.status, 200);
    const stored = store.get('abc');
    assert.equal(stored.votes.length, 1);
    assert.equal(stored.votes[0].availability, 'actually, Sundays work too');
  } finally { server.close(); }
});

test('POST /api/plan/:id/vote rejects voter name not on crew roster', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }],
    crewName: 'x', city: 'x', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' }, votes: [], locked: false,
    finalDate: null, finalReason: null, finalPlan: null
  });
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/abc/vote', { name: 'Stranger', availability: 'x' });
    assert.equal(r.status, 400);
    assert.match(r.body.error, /not on the crew/i);
  } finally { server.close(); }
});

test('POST /api/plan/:id/vote returns 409 when plan is locked', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }],
    crewName: 'x', city: 'x', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' }, votes: [], locked: true,
    finalDate: '2026-04-18', finalReason: 'x', finalPlan: []
  });
  const { server, port } = await startApp();
  try {
    const r = await request(port, 'POST', '/abc/vote', { name: 'Mark', availability: 'x' });
    assert.equal(r.status, 409);
  } finally { server.close(); }
});
```

- [ ] **Step 2: Run and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: the four new tests fail with 404 (route doesn't exist).

- [ ] **Step 3: Add the vote route** — in `planRoutes.js`, add before `module.exports`:

```js
router.post('/:id/vote', async (req, res) => {
  const { name, availability } = req.body || {};
  if (!name || !availability) return res.status(400).json({ error: 'name and availability required' });

  const plan = await getPlan(req.params.id);
  if (!plan) return res.status(404).json({ error: 'plan not found' });
  if (plan.locked) return res.status(409).json({ error: 'plan is locked' });

  const onRoster = plan.crew.some(p => p.name === name);
  if (!onRoster) return res.status(400).json({ error: 'name is not on the crew' });

  const existing = plan.votes.findIndex(v => v.name === name);
  const record = { name, availability: availability.trim(), at: Date.now() };
  if (existing >= 0) plan.votes[existing] = record;
  else plan.votes.push(record);

  await putPlan(plan.id, plan, 60 * 60 * 24 * 30);
  res.json({ ok: true });
});
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: all tests green.

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add planRoutes.js tests/planRoutes.test.js
git commit -m "feat: vote upsert route"
```

---

## Task 6: Lock route (consensus + plan-build)

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/planRoutes.js`
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/tests/planRoutes.test.js`

We need the route to call Anthropic. We inject `callClaude` as a dependency so tests don't hit the network.

- [ ] **Step 1: Add failing tests** — append to `tests/planRoutes.test.js`:

```js
test('POST /api/plan/:id/lock runs consensus then plan-build, writes finalDate/finalReason/finalPlan, sets locked', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }, { name: 'Dave', phone: '+2' }],
    crewName: 'x', city: 'Atlanta', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'Skeet', blurb: 'bang' },
    votes: [
      { name: 'Mark', availability: 'any Saturday after 1pm', at: 1 },
      { name: 'Dave', availability: 'not 4/25, otherwise weekends', at: 2 }
    ],
    locked: false, finalDate: null, finalReason: null, finalPlan: null
  });

  // Stub the Claude callers that planRoutes imports
  const callClaudeStub = require.cache[require.resolve('../claudeClient')] = {
    exports: {
      callClaude: async (prompt) => {
        if (prompt.includes('Crew availability')) {
          return '{"date":"2026-04-18","reasoning":"Only Saturday everyone can make."}';
        }
        return '[{"name":"Mark","driveTime":"20 min","bring":"eye pro","notes":"meet 1pm"},{"name":"Dave","driveTime":"35 min","bring":"cash","notes":"drive north"}]';
      }
    }
  };

  // planRoutes is already required above; re-require is not easy with node:test. Instead, reset the module cache and re-require here.
  delete require.cache[require.resolve('../planRoutes')];
  const routes = require('../planRoutes');
  const app = express(); app.use(express.json()); app.use('/api/plan', routes);
  const server = await new Promise(r => { const s = app.listen(0, () => r(s)); });
  const port = server.address().port;

  try {
    const r = await request(port, 'POST', '/abc/lock');
    assert.equal(r.status, 200);
    const stored = store.get('abc');
    assert.equal(stored.finalDate, '2026-04-18');
    assert.match(stored.finalReason, /Saturday/);
    assert.equal(stored.finalPlan.length, 2);
    assert.equal(stored.locked, true);
  } finally { server.close(); }
});

test('POST /api/plan/:id/lock retries plan-build only if already locked but finalPlan is null', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }],
    crewName: 'x', city: 'Atlanta', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'Skeet', blurb: 'bang' },
    votes: [{ name: 'Mark', availability: 'Sat', at: 1 }],
    locked: true, finalDate: '2026-04-18', finalReason: 'already picked', finalPlan: null
  });

  let consensusCalled = false;
  require.cache[require.resolve('../claudeClient')] = {
    exports: {
      callClaude: async (prompt) => {
        if (prompt.includes('Crew availability')) { consensusCalled = true; return '{"date":"X","reasoning":"x"}'; }
        return '[{"name":"Mark","driveTime":"10 min","bring":"x","notes":"x"}]';
      }
    }
  };

  delete require.cache[require.resolve('../planRoutes')];
  const routes = require('../planRoutes');
  const app = express(); app.use(express.json()); app.use('/api/plan', routes);
  const server = await new Promise(r => { const s = app.listen(0, () => r(s)); });
  const port = server.address().port;

  try {
    const r = await request(port, 'POST', '/abc/lock');
    assert.equal(r.status, 200);
    assert.equal(consensusCalled, false);
    const stored = store.get('abc');
    assert.equal(stored.finalDate, '2026-04-18'); // unchanged
    assert.equal(stored.finalPlan.length, 1);     // filled in
  } finally { server.close(); }
});

test('POST /api/plan/:id/lock returns 409 when fully locked (finalPlan present)', async () => {
  store.clear();
  store.set('abc', {
    id: 'abc', crew: [{ name: 'Mark', phone: '+1' }],
    crewName: 'x', city: 'x', driveDistance: 2, vibe: { adventure: 3, risk: 2, cost: 2 },
    activity: { name: 'x' }, votes: [{ name: 'Mark', availability: 'x', at: 1 }],
    locked: true, finalDate: '2026-04-18', finalReason: 'x', finalPlan: [{ name: 'Mark' }]
  });

  delete require.cache[require.resolve('../planRoutes')];
  const routes = require('../planRoutes');
  const app = express(); app.use(express.json()); app.use('/api/plan', routes);
  const server = await new Promise(r => { const s = app.listen(0, () => r(s)); });
  const port = server.address().port;

  try {
    const r = await request(port, 'POST', '/abc/lock');
    assert.equal(r.status, 409);
  } finally { server.close(); }
});
```

- [ ] **Step 2: Run tests and verify they fail**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: new lock tests fail (route missing or `claudeClient` module missing).

- [ ] **Step 3: Create `claudeClient.js` for DI** — `/Users/everettsteele/PROJECTS/sorted-api/claudeClient.js`:

```js
async function callClaude(prompt, maxTokens = 1024) {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) throw new Error('ANTHROPIC_API_KEY not configured');
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: maxTokens,
      messages: [{ role: 'user', content: prompt }]
    })
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error?.message || `anthropic ${res.status}`);
  return data.content[0].text;
}

module.exports = { callClaude };
```

- [ ] **Step 4: Add the lock route** — in `planRoutes.js`:

At the top, add:

```js
const { callClaude } = require('./claudeClient');
const { buildConsensusPrompt, parseConsensusResponse } = require('./consensus');
const { buildPlanPrompt, parsePlanResponse } = require('./planBuilder');
```

Add the route before `module.exports`:

```js
router.post('/:id/lock', async (req, res) => {
  const plan = await getPlan(req.params.id);
  if (!plan) return res.status(404).json({ error: 'plan not found' });
  if (plan.locked && plan.finalPlan) return res.status(409).json({ error: 'plan already locked' });

  try {
    // Step A: consensus (skip if we already have finalDate from a prior partial run)
    if (!plan.finalDate) {
      const todayISO = new Date().toISOString().slice(0, 10);
      let consensusRaw;
      try {
        consensusRaw = await callClaude(buildConsensusPrompt(plan, todayISO), 400);
      } catch (e) {
        consensusRaw = await callClaude(buildConsensusPrompt(plan, todayISO), 400); // one retry
      }
      const { date, reasoning } = parseConsensusResponse(consensusRaw);
      plan.finalDate = date;
      plan.finalReason = reasoning;
      await putPlan(plan.id, plan, 60 * 60 * 24 * 30);
    }

    // Step B: plan build
    const planRaw = await callClaude(buildPlanPrompt(plan, plan.finalDate), 2000);
    plan.finalPlan = parsePlanResponse(planRaw);
    plan.locked = true;
    await putPlan(plan.id, plan, 60 * 60 * 24 * 30);

    res.json({ ok: true, finalDate: plan.finalDate, finalReason: plan.finalReason, finalPlan: plan.finalPlan });
  } catch (err) {
    console.error('[planRoutes] lock failed:', err.message);
    res.status(500).json({ error: err.message });
  }
});
```

- [ ] **Step 5: Run tests and verify they pass**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: all tests green.

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add claudeClient.js planRoutes.js tests/planRoutes.test.js
git commit -m "feat: lock route (consensus + plan-build with retry)"
```

---

## Task 7: Mount plan routes + smoke script

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/index.js`
- Create: `/Users/everettsteele/PROJECTS/sorted-api/scripts/smoke-plan.sh`

- [ ] **Step 1: Mount the router** — in `/Users/everettsteele/PROJECTS/sorted-api/index.js`, add near the top after `app.use(express.json());`:

```js
app.use('/api/plan', require('./planRoutes'));
```

Also update the `Access-Control-Allow-Methods` header to include GET:

```js
res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
```

- [ ] **Step 2: Add startup env-var sanity logging** — in `index.js`, near the bottom before `app.listen`:

```js
['CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_KV_NAMESPACE_ID', 'CLOUDFLARE_API_TOKEN'].forEach(k => {
  if (!process.env[k]) console.warn(`[sorted-api] warning: ${k} is not set — /api/plan will fail`);
});
```

- [ ] **Step 3: Create the smoke script** — `/Users/everettsteele/PROJECTS/sorted-api/scripts/smoke-plan.sh`:

```bash
#!/usr/bin/env bash
# End-to-end smoke test against a running sorted-api.
# Usage: API=http://localhost:3003 bash scripts/smoke-plan.sh
set -eu
API="${API:-http://localhost:3003}"

echo "==> create"
CREATE=$(curl -sS -X POST "$API/api/plan" -H 'Content-Type: application/json' -d '{
  "crewName":"Smoke Test Crew",
  "crew":[{"name":"Org","phone":"+15551110000"},{"name":"Dave","phone":"+15552220000"}],
  "city":"Atlanta",
  "driveDistance":2,
  "vibe":{"adventure":3,"risk":2,"cost":2},
  "activity":{"name":"Skeet","blurb":"bang"},
  "organizerAvailability":"any Saturday after 1pm"
}')
echo "$CREATE"
ID=$(printf '%s' "$CREATE" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).id))')
echo "id=$ID"

echo "==> get (phones should be absent)"
curl -sS "$API/api/plan/$ID" | head -c 600; echo

echo "==> vote (Dave)"
curl -sS -X POST "$API/api/plan/$ID/vote" -H 'Content-Type: application/json' -d '{"name":"Dave","availability":"4/18 works"}'; echo

echo "==> lock"
curl -sS -X POST "$API/api/plan/$ID/lock" | head -c 800; echo

echo "==> get after lock"
curl -sS "$API/api/plan/$ID" | head -c 800; echo

echo "smoke test complete."
```

```bash
chmod +x /Users/everettsteele/PROJECTS/sorted-api/scripts/smoke-plan.sh
```

- [ ] **Step 4: Run unit tests to make sure nothing regressed**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: all green.

- [ ] **Step 5: Manual smoke (optional, requires real env vars + running server)**

Set `ANTHROPIC_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_KV_NAMESPACE_ID`, `CLOUDFLARE_API_TOKEN` in a local `.env` (or export them), then:

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
npm start &
sleep 2
bash scripts/smoke-plan.sh
```

Expected: every step returns 200 JSON, the lock step returns `finalDate`, `finalReason`, and `finalPlan[]`.

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git add index.js scripts/smoke-plan.sh
git commit -m "feat: mount plan routes, smoke script, env-var warning"
```

- [ ] **Step 7: Push & set Railway env vars**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api
git push
```

Then in Railway: add `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_KV_NAMESPACE_ID`, `CLOUDFLARE_API_TOKEN` to the `sorted-api` service Variables. Confirm the service restarts and `/health` still returns `{ ok: true }`.

---

## Task 8: Frontend — add phone input to crew rows

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Locate `addPerson()` in `index.html` (around line 373-378)**

Current shape:

```js
const list=$('crew-list'),idx=list.children.length;
const row=document.createElement('div');row.className='crew-row';
// ... creates one input for name
```

- [ ] **Step 2: Update `addPerson()` to render name + phone**

Replace the body of `addPerson()` with:

```js
function addPerson(){
  const list=$('crew-list');
  const row=document.createElement('div');row.className='crew-row';
  row.innerHTML=`
    <input type="text" class="crew-name" placeholder="Name" autocomplete="off">
    <input type="tel" class="crew-phone" placeholder="Phone" autocomplete="off" inputmode="tel">
    <button class="crew-del" type="button" onclick="removePerson(this)">✕</button>
  `;
  list.appendChild(row);
}
```

- [ ] **Step 3: Update `syncPeople()` to also populate `phones[]`**

Find the existing `syncPeople` function and replace with:

```js
function syncPeople(){
  people=[]; phones=[];
  $('crew-list').querySelectorAll('.crew-row').forEach(r=>{
    const n=r.querySelector('.crew-name');
    const p=r.querySelector('.crew-phone');
    people.push(n ? n.value.trim() : '');
    phones.push(p ? p.value.trim() : '');
  });
}
```

- [ ] **Step 4: Add `phones` to the globals line**

Find `let timer,acts=[],people=[],chosen=null,voteMode=false,allRecaps=[],crewName='';` and change to:

```js
let timer,acts=[],people=[],phones=[],chosen=null,allRecaps=[],crewName='',availability='',planId='';
```

(We drop `voteMode` here — it's going away in Task 9.)

- [ ] **Step 5: Update `nextFromCrew()` to require phone on every filled row**

Replace with:

```js
function nextFromCrew(){
  syncPeople();
  const err=$('crew-err');
  const rows=[];
  for (let i=0;i<people.length;i++){
    if (people[i] || phones[i]) rows.push({name:people[i],phone:phones[i]});
  }
  if (!rows.length){err.textContent='⚠ Add at least one name + phone to continue.';err.style.display='block';return;}
  for (const r of rows){
    if (!r.name||!r.phone){err.textContent='⚠ Every crew row needs both a name and a phone.';err.style.display='block';return;}
  }
  people=rows.map(r=>r.name);
  phones=rows.map(r=>r.phone);
  err.style.display='none';
  crewName=$('crew-name-input').value.trim();
  goTo('s-loc');
}
```

- [ ] **Step 6: Add minimal CSS for the phone input & delete button**

In the `<style>` block, find the `.crew-row input` rule and replace it with:

```css
.crew-row{display:flex;gap:8px;align-items:center}
.crew-row input{flex:1;background:var(--navy2);border:1px solid rgba(255,255,255,0.12);border-radius:var(--radius);padding:13px 15px;color:var(--white);font-family:'Outfit',sans-serif;font-size:15px;font-weight:500;outline:none;transition:all 0.15s}
.crew-row input.crew-phone{flex:0 0 46%}
.crew-row input:focus{border-color:var(--cyan);box-shadow:0 0 0 2px rgba(0,240,255,0.15),var(--glow-cyan)}
.crew-row input::placeholder{color:rgba(255,255,255,0.2);font-weight:400}
.crew-del{background:transparent;color:var(--dim);border:1px solid rgba(255,255,255,0.1);border-radius:var(--radius);width:40px;height:44px;font-size:14px;cursor:pointer}
.crew-del:hover{color:var(--pink);border-color:var(--pink)}
```

- [ ] **Step 7: Manual smoke**

```bash
cd /Users/everettsteele/PROJECTS/sorted
python3 -m http.server 8081 &
# open http://localhost:8081 — fill crew step with names + phones, try missing one, confirm error
```

Expected: can't advance past crew step without both fields per row; "+" still adds rows; "✕" removes them.

- [ ] **Step 8: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(crew): add phone input per row; require phone to continue"
```

---

## Task 9: Frontend — replace date picker with availability textbox

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Remove the old date UI from `s-loc`**

Inside `<div class="screen" id="s-loc">`, find and delete the entire date block: the `<input type="date" id="date-input">`, the `date-toggle` span, and the full `<div class="date-options" id="date-options">` block with `date-opt-1/2/3`.

- [ ] **Step 2: Insert the new availability textbox** in the same spot:

```html
<div class="field">
  <label class="field-label">When are YOU available?</label>
  <textarea class="field-input" id="avail-input" rows="3" placeholder='A date, a few dates, or a slot that works — e.g. "4/18", "any Sat after 1pm", "weekends in May but not the 25th"'></textarea>
</div>
```

- [ ] **Step 3: Add textarea styling** — near existing `.field-input` CSS, add:

```css
textarea.field-input{resize:vertical;min-height:64px;font-family:'Outfit',sans-serif}
```

- [ ] **Step 4: Remove dead code**

Delete the JS functions `toggleDateOptions()` and any references to `voteMode`, `date-input`, `date-opt-1`, `date-opt-2`, `date-opt-3`. In `goTo('s-loc')` callers and `s-loc`'s Next handler, capture `availability` from the new input:

Update the "Next" button on `s-loc` to call a new `nextFromLoc()` function:

```html
<button class="btn btn-primary" onclick="nextFromLoc()">NEXT →</button>
```

(If that button was previously wired to `goTo('s-vibe')`, swap it for the new call.)

Add the function:

```js
function nextFromLoc(){
  const city=$('city-input').value.trim();
  const avail=$('avail-input').value.trim();
  const err=$('loc-err');
  if (!city){err.textContent='⚠ Enter your city to continue.';err.style.display='block';return;}
  if (!avail){err.textContent='⚠ Enter your availability to continue.';err.style.display='block';return;}
  err.style.display='none';
  availability=avail;
  goTo('s-vibe');
}
```

- [ ] **Step 5: Also remove the old "Suggest 3 dates" logic in the recap-rendering path**

Search the file for `voteMode` and remove any remaining references (likely inside `buildRecap`, `copyAll`, or similar). The final plan renderer will no longer emit a "vote on dates" block — the new `s-final` screen replaces that concept.

- [ ] **Step 6: Manual smoke**

Reload `http://localhost:8081`, advance past crew step, fill city + availability textarea, confirm the Next button works and errors show for blank values.

- [ ] **Step 7: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(loc): replace date picker with free-text availability"
```

---

## Task 10: Frontend — wire activity pick to POST /api/plan, navigate to share screen

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Find `pickActivity(idx)`** (around line 451). Today it loads `s-recap-load` and calls the recap-builder endpoint. Replace its body with:

```js
async function pickActivity(idx){
  chosen=acts[idx];
  goTo('s-share-load'); // brief loading while we create the plan
  try {
    const res=await fetch(`${API}/api/plan`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({
        crewName,
        crew: people.map((n,i)=>({name:n,phone:phones[i]})),
        city: $('city-input').value.trim(),
        driveDistance: parseInt($('sl-dist').value,10),
        vibe: {
          adventure: parseInt($('sl-adv').value,10),
          risk: parseInt($('sl-risk').value,10),
          cost: parseInt($('sl-cost').value,10)
        },
        activity: chosen,
        organizerAvailability: availability
      })
    });
    if (!res.ok) throw new Error(`create failed ${res.status}`);
    const data=await res.json();
    planId=data.id;
    renderShare();
    goTo('s-share');
    startPolling();
  } catch (err) {
    console.error('[sorted] create plan failed:', err);
    alert('Could not create the plan. Try again.');
    goTo('s-results');
  }
}
```

- [ ] **Step 2: Add a tiny loading screen `s-share-load` modeled on `s-load`**

Next to the existing `s-load` markup, add:

```html
<div class="screen loading-screen" id="s-share-load">
  <div class="load-spinner"></div>
  <div class="load-word">LOCKING IT IN...</div>
  <div class="load-sub">Creating the crew page</div>
</div>
```

- [ ] **Step 3: Stub `renderShare()`, `startPolling()`, `stopPolling()` — filled in Task 11**

Add these stubs just above `pickActivity`:

```js
let pollHandle=null;
function renderShare(){ /* filled in Task 11 */ }
function startPolling(){ /* filled in Task 11 */ }
function stopPolling(){ if (pollHandle) { clearInterval(pollHandle); pollHandle=null; } }
```

- [ ] **Step 4: Manual smoke**

Reload. Complete the flow through to activity selection. Clicking an activity should briefly show `s-share-load`, attempt `POST /api/plan`, and show an empty `s-share` screen (no markup yet — that comes next task) or alert on failure. Check DevTools Network to confirm the request fired.

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(share): wire activity pick to POST /api/plan"
```

---

## Task 11: Frontend — share screen markup, SMS helper, polling, dashboard

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Add the `s-share` screen markup** near the existing `s-recap` screen:

```html
<div class="screen" id="s-share">
  <div class="nav"><div class="logo">GRIP IT 'N <em>RIP IT</em></div></div>
  <div class="step-body">
    <h2 class="step-head">IT'S ON.</h2>
    <div class="share-pitch" id="share-pitch"></div>

    <div class="share-actions">
      <button class="btn btn-primary" id="send-btn">📲 SEND TO GROUP TEXT</button>
      <button class="btn btn-secondary" id="copy-msg-btn">📋 COPY MESSAGE</button>
    </div>

    <h3 class="step-sub" style="margin-top:24px">Crew's weighing in…</h3>
    <div class="waiting-list" id="waiting-list"></div>

    <button class="btn btn-cyan" id="lock-btn">⚡ LOCK IT IN →</button>
  </div>
</div>
```

- [ ] **Step 2: Add CSS** — append to the `<style>` block:

```css
.share-pitch{background:var(--navy2);border:var(--border-light);border-radius:var(--radius);padding:16px;margin:12px 0 16px;line-height:1.4}
.share-pitch h4{font-family:'Bebas Neue',cursive;font-size:22px;letter-spacing:0.04em;color:var(--cyan);margin-bottom:6px}
.share-actions{display:flex;gap:8px;flex-direction:column}
.waiting-list{display:flex;flex-direction:column;gap:8px;margin:8px 0 20px}
.waiting-row{display:flex;justify-content:space-between;align-items:center;background:var(--navy2);border:1px solid rgba(255,255,255,0.08);border-radius:var(--radius);padding:10px 12px}
.waiting-row .vote-name{font-weight:600}
.waiting-row .vote-avail{color:var(--dim);font-size:13px;max-width:60%;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.waiting-row.voted{border-color:rgba(0,240,255,0.4)}
.waiting-row.voted .vote-name::before{content:'✓ ';color:var(--cyan)}
.waiting-row.pending .vote-name::before{content:'— ';color:var(--dim)}
```

- [ ] **Step 3: Implement `smsHref()` and `shareMessage()` helpers**

Add near the other utility JS:

```js
function smsHref(phoneList, body){
  const to = phoneList.join(',');
  // Single URI that works on modern iOS and Android
  return `sms:${to}?&body=${encodeURIComponent(body)}`;
}

function shareInviteMessage(plan){
  const url = `${location.origin}${location.pathname}?p=${plan.id}`;
  return `${plan.crewName || 'Crew'}: ${plan.activity.name} in ${plan.city}. Weigh in on dates: ${url}`;
}

function shareFinalMessage(plan){
  const url = `${location.origin}${location.pathname}?p=${plan.id}`;
  return `${plan.crewName || 'Crew'}: LOCKED IN — ${plan.activity.name} in ${plan.city}, ${plan.finalDate}. Plan: ${url}`;
}
```

- [ ] **Step 4: Fill in `renderShare()` and `startPolling()`**

Replace the stubs:

```js
function renderShare(){
  $('share-pitch').innerHTML = `<h4>${chosen.name}</h4><div>${chosen.blurb||''}</div>`;
  const msg = shareInviteMessage({ id: planId, crewName, activity: chosen, city: $('city-input').value.trim() });
  $('send-btn').onclick = () => { window.location.href = smsHref(phones, msg); };
  $('copy-msg-btn').onclick = async () => {
    await navigator.clipboard.writeText(msg);
    showToast('Copied. Paste into your group text.');
  };
  $('lock-btn').onclick = lockItIn;
  renderDashboard({ crew: people.map(n=>({name:n})), votes: [{ name: people[0], availability }] });
}

function startPolling(){
  stopPolling();
  pollHandle = setInterval(async () => {
    try {
      const res = await fetch(`${API}/api/plan/${planId}`);
      if (!res.ok) return;
      const plan = await res.json();
      renderDashboard(plan);
      if (plan.locked && plan.finalPlan) { stopPolling(); /* user will have pressed Lock themselves, or someone else did; reflect it */ renderFinal(plan); goTo('s-final'); }
    } catch(e) { /* swallow */ }
  }, 10000);
}

function renderDashboard(plan){
  const host = $('waiting-list'); if (!host) return;
  const votedNames = new Set((plan.votes||[]).map(v=>v.name));
  const byName = Object.fromEntries((plan.votes||[]).map(v=>[v.name, v.availability]));
  host.innerHTML = plan.crew.map(p => {
    const voted = votedNames.has(p.name);
    const avail = byName[p.name] || '';
    return `<div class="waiting-row ${voted?'voted':'pending'}">
      <span class="vote-name">${escapeHtml(p.name)}</span>
      <span class="vote-avail">${voted ? escapeHtml(avail) : 'waiting…'}</span>
    </div>`;
  }).join('');
}

function escapeHtml(s){return (s||'').replace(/[&<>"']/g, c=>({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));}
```

- [ ] **Step 5: Manual smoke**

Reload. Complete the wizard → pick an activity → confirm:
- Share screen renders with the activity pitch.
- Tapping "Copy Message" copies the expected URL + message.
- On a real phone, tapping "Send to group text" opens the SMS app prefilled.
- Dashboard shows the organizer as ✓ and the other crew member as pending.
- Re-open the organizer's own `?p=ID` URL in a second tab and confirm the plan loads (voter flow not built yet; just check the network call).

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(share): share screen with SMS helper, dashboard, polling"
```

---

## Task 12: Frontend — Lock it in + final plan screen

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Add the `s-final` screen markup** (near `s-share`):

```html
<div class="screen" id="s-final">
  <div class="nav"><div class="logo">GRIP IT 'N <em>RIP IT</em></div></div>
  <div class="step-body">
    <h2 class="step-head">LOCKED IN.</h2>
    <div class="final-date" id="final-date"></div>
    <div class="final-reason" id="final-reason"></div>
    <div class="crew-plans" id="final-crew-plans"></div>
    <div class="share-actions" style="margin-top:16px">
      <button class="btn btn-primary" id="final-send-btn">📲 SEND PLAN TO GROUP TEXT</button>
      <button class="btn btn-secondary" id="final-copy-btn">📋 COPY PLAN</button>
    </div>
  </div>
</div>
```

Plus a simple locking-screen while the two Claude calls run:

```html
<div class="screen loading-screen" id="s-lock-load">
  <div class="load-spinner"></div>
  <div class="load-word" id="lock-word">LOCKING...</div>
  <div class="load-sub">Picking the date &amp; building the plan</div>
</div>
```

- [ ] **Step 2: CSS**

```css
.final-date{font-family:'Bebas Neue',cursive;font-size:44px;letter-spacing:0.04em;color:var(--cyan);text-shadow:var(--glow-cyan);margin:8px 0}
.final-reason{color:var(--dim);font-size:14px;margin-bottom:16px;line-height:1.4}
```

- [ ] **Step 3: Implement `lockItIn()` and `renderFinal()`**

```js
async function lockItIn(){
  stopPolling();
  goTo('s-lock-load');
  try {
    const res = await fetch(`${API}/api/plan/${planId}/lock`, { method: 'POST' });
    if (!res.ok) throw new Error(`lock failed ${res.status}`);
    // Re-fetch canonical plan (guarantees we have the full shape)
    const plan = await (await fetch(`${API}/api/plan/${planId}`)).json();
    renderFinal(plan);
    goTo('s-final');
  } catch (err) {
    console.error('[sorted] lock failed:', err);
    alert('Lock-in failed. Try again.');
    goTo('s-share');
    startPolling();
  }
}

function renderFinal(plan){
  $('final-date').textContent = plan.finalDate || '';
  $('final-reason').textContent = plan.finalReason || '';
  const host = $('final-crew-plans'); host.innerHTML = '';
  (plan.finalPlan || []).forEach(p => {
    const card = document.createElement('div');
    card.className = 'crew-plan-card';
    card.innerHTML = `
      <h4 class="plan-person-name">${escapeHtml(p.name)}</h4>
      <div class="plan-line"><span>Drive:</span> ${escapeHtml(p.driveTime||'')}</div>
      <div class="plan-line"><span>Bring:</span> ${escapeHtml(p.bring||'')}</div>
      <div class="plan-line"><span>Notes:</span> ${escapeHtml(p.notes||'')}</div>
    `;
    host.appendChild(card);
  });

  const msg = shareFinalMessage(plan);
  $('final-send-btn').onclick = () => { window.location.href = smsHref(phones, msg); };
  $('final-copy-btn').onclick = async () => {
    const body = msg + '\n\n' + (plan.finalPlan||[]).map(p=>`${p.name} — drive ${p.driveTime} · bring ${p.bring} · ${p.notes}`).join('\n');
    await navigator.clipboard.writeText(body);
    showToast('Plan copied.');
  };
}
```

- [ ] **Step 4: Add CSS for `.crew-plan-card` and `.plan-line`** if those classes aren't already present — if they exist (reused from old recap), skip. Otherwise:

```css
.crew-plan-card{background:var(--navy2);border:var(--border-light);border-radius:var(--radius);padding:14px;margin-bottom:10px}
.plan-person-name{font-family:'Bebas Neue',cursive;font-size:20px;color:var(--cyan);letter-spacing:0.04em;margin-bottom:6px}
.plan-line{font-size:14px;line-height:1.5}
.plan-line span{color:var(--dim);display:inline-block;width:62px}
```

- [ ] **Step 5: Manual smoke**

Reload, walk through to the share screen, press Lock It In. Should see lock-load → final screen with date + reasoning + per-person cards. Copy Plan and Send Plan work.

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(final): lock-it-in + final plan screen with send/copy"
```

---

## Task 13: Frontend — voter flow routing + vote screen

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html`

- [ ] **Step 1: Add voter screens' markup** — near the other screens:

```html
<div class="screen" id="v-vote">
  <div class="nav"><div class="logo">GRIP IT 'N <em>RIP IT</em></div></div>
  <div class="step-body">
    <h2 class="step-head" id="v-crew-name">CREW</h2>
    <div class="share-pitch" id="v-pitch"></div>
    <div class="field">
      <label class="field-label">Who are you?</label>
      <select class="field-input" id="v-name-select"></select>
    </div>
    <div class="field">
      <label class="field-label">When works for you?</label>
      <textarea class="field-input" id="v-avail" rows="3" placeholder='A date, a few dates, or a slot that works — e.g. "4/18", "any Sat after 1pm", "weekends in May but not the 25th"'></textarea>
    </div>
    <div class="err" id="v-err"></div>
    <button class="btn btn-primary" id="v-submit">SUBMIT →</button>
  </div>
</div>

<div class="screen" id="v-thanks">
  <div class="nav"><div class="logo">GRIP IT 'N <em>RIP IT</em></div></div>
  <div class="step-body">
    <h2 class="step-head">LOCKED IN.</h2>
    <p id="v-thanks-copy">You'll get the plan in the group text once the organizer pulls the trigger.</p>
  </div>
</div>

<div class="screen" id="v-final">
  <div class="nav"><div class="logo">GRIP IT 'N <em>RIP IT</em></div></div>
  <div class="step-body">
    <h2 class="step-head">PLAN IS LIVE.</h2>
    <div class="final-date" id="v-final-date"></div>
    <div class="final-reason" id="v-final-reason"></div>
    <div class="crew-plans" id="v-final-crew-plans"></div>
  </div>
</div>
```

- [ ] **Step 2: Add URL-param router on load**

Find the existing init block (near the bottom of the script, where `addPerson()` is called on first load). Replace with:

```js
(async function init(){
  const url = new URL(location.href);
  const p = url.searchParams.get('p');
  if (p) {
    await bootVoter(p);
  } else {
    addPerson(); // organizer wizard default
  }
})();
```

- [ ] **Step 3: Implement `bootVoter()` and supporting handlers**

```js
async function bootVoter(id){
  planId = id;
  try {
    const res = await fetch(`${API}/api/plan/${id}`);
    if (!res.ok) { showVoterError('This plan isn\'t available anymore.'); return; }
    const plan = await res.json();

    if (plan.locked && plan.finalPlan) {
      renderVoterFinal(plan);
      goTo('v-final');
      return;
    }

    $('v-crew-name').textContent = plan.crewName || 'CREW';
    $('v-pitch').innerHTML = `<h4>${escapeHtml(plan.activity.name)}</h4><div>${escapeHtml(plan.activity.blurb||'')}</div><div style="margin-top:6px;color:var(--dim);font-size:13px">${escapeHtml(plan.city)}</div>`;

    const votedNames = new Set((plan.votes||[]).map(v=>v.name));
    const byName = Object.fromEntries((plan.votes||[]).map(v=>[v.name, v.availability]));
    const sel = $('v-name-select');
    sel.innerHTML = '<option value="">— pick your name —</option>' + plan.crew.map(p => {
      const mark = votedNames.has(p.name) ? ' ✓' : '';
      return `<option value="${escapeHtml(p.name)}">${escapeHtml(p.name)}${mark}</option>`;
    }).join('');

    sel.onchange = () => {
      const chosenName = sel.value;
      $('v-avail').value = byName[chosenName] || '';
    };

    $('v-submit').onclick = () => submitVote(plan);
    goTo('v-vote');
  } catch (e) {
    console.error('[sorted] voter boot failed:', e);
    showVoterError('Could not load the plan. Try again later.');
  }
}

async function submitVote(plan){
  const name = $('v-name-select').value;
  const avail = $('v-avail').value.trim();
  const err = $('v-err');
  if (!name) { err.textContent='⚠ Pick your name.'; err.style.display='block'; return; }
  if (!avail) { err.textContent='⚠ Tell us when works.'; err.style.display='block'; return; }
  err.style.display='none';
  try {
    const res = await fetch(`${API}/api/plan/${planId}/vote`, {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ name, availability: avail })
    });
    if (!res.ok) {
      const body = await res.json().catch(()=>({error:'vote failed'}));
      err.textContent='⚠ '+(body.error||'vote failed'); err.style.display='block';
      return;
    }
    goTo('v-thanks');
  } catch(e) {
    err.textContent='⚠ Network error. Try again.'; err.style.display='block';
  }
}

function renderVoterFinal(plan){
  $('v-final-date').textContent = plan.finalDate || '';
  $('v-final-reason').textContent = plan.finalReason || '';
  const host = $('v-final-crew-plans'); host.innerHTML = '';
  (plan.finalPlan || []).forEach(p => {
    const card = document.createElement('div');
    card.className = 'crew-plan-card';
    card.innerHTML = `
      <h4 class="plan-person-name">${escapeHtml(p.name)}</h4>
      <div class="plan-line"><span>Drive:</span> ${escapeHtml(p.driveTime||'')}</div>
      <div class="plan-line"><span>Bring:</span> ${escapeHtml(p.bring||'')}</div>
      <div class="plan-line"><span>Notes:</span> ${escapeHtml(p.notes||'')}</div>
    `;
    host.appendChild(card);
  });
}

function showVoterError(msg){
  document.body.innerHTML = `<div style="padding:40px;font-family:'Outfit',sans-serif;color:#fff;background:#080e2b;min-height:100vh">
    <h2 style="font-family:'Bebas Neue';letter-spacing:0.04em;margin-bottom:8px">Oof.</h2>
    <p style="color:rgba(255,255,255,0.6)">${escapeHtml(msg)}</p>
  </div>`;
}
```

- [ ] **Step 4: Manual smoke — two-tab test**

1. Start the frontend server (`python3 -m http.server 8081`) and backend (`npm start` in sorted-api) with real env vars.
2. Tab A: complete the wizard, pick activity, copy the URL from the "Copy Message" button (extract the `?p=…` part).
3. Tab B (or mobile device): open that URL, confirm voter screen loads with the activity pitch and name dropdown.
4. Pick a non-organizer name, enter availability, submit → thank-you screen.
5. Tab A dashboard: wait ≤10s for the polled update to show the new voter as ✓ with their availability.
6. Go back to Tab B, reload the same URL, pick the same name again — previous availability should pre-fill (editable).
7. Tab A: press Lock It In → final screen.
8. Tab B: reload → voter now sees final plan screen.

- [ ] **Step 5: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add index.html
git commit -m "feat(voter): voting flow — name dropdown, availability, locked view"
```

---

## Task 14: Final sweep — CORS, SMS prefill check, error states, README

**Files:**
- Modify: `/Users/everettsteele/PROJECTS/sorted-api/index.js` (already updated in Task 7 — verify)
- Modify: `/Users/everettsteele/PROJECTS/sorted/index.html` (polish only)
- Modify: `/Users/everettsteele/PROJECTS/sorted/README.md`

- [ ] **Step 1: Verify CORS allows GET + POST from the Pages origin**

In `/Users/everettsteele/PROJECTS/sorted-api/index.js`, confirm the header line is:

```js
res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
```

And the allowed origins still include both `sorted.neverstill.llc` and the Pages preview.

- [ ] **Step 2: SMS prefill check matrix**

On a real iPhone (Safari) and a real Android (Chrome):
1. Open the app on a laptop, build a plan with two valid phone numbers.
2. Transfer the URL (AirDrop/paste) to the phones.
3. Tap "Send to group text" on each — verify prefill shows addresses + body.
4. If either fails to prefill (iOS sometimes ignores `?&body=` for multi-recipient), confirm the "Copy Message" fallback is visible and works.

Document the result in `docs/superpowers/specs/2026-04-12-crew-date-voting-design.md` under a new "Verified" section (append — don't rewrite the spec).

- [ ] **Step 3: Error-state polish**

In `index.html`, confirm these surfaces exist and render correctly:
- Expired/unknown `?p=` link → "This plan isn't available anymore" message.
- Lock failure mid-flow → alert + return to share screen + polling resumes.
- Vote after lock (organizer hits Lock while voter is composing) → voter sees the 409 error in-line, then reloading the page shows the final-plan view.

Test each manually. If any surface is missing copy or renders awkwardly, tighten it — no new features.

- [ ] **Step 4: Update `README.md`** — add a paragraph above "Running Your Own Instance":

```markdown
## Backend env vars

Beyond the existing `ANTHROPIC_API_KEY`, `sorted-api` now needs:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_KV_NAMESPACE_ID` — create a KV namespace and paste its ID here
- `CLOUDFLARE_API_TOKEN` — scoped: `Account → Workers KV Storage → Edit`

Set these as Railway Variables, not in source.
```

- [ ] **Step 5: Run all backend tests one more time**

```bash
cd /Users/everettsteele/PROJECTS/sorted-api && npm test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
cd /Users/everettsteele/PROJECTS/sorted
git add README.md index.html
git commit -m "chore: env var docs, error-state polish, SMS prefill notes"
git push

cd /Users/everettsteele/PROJECTS/sorted-api
git add index.js
git commit -m "chore: CORS GET allowed; env-var sanity" || echo "nothing to commit"
git push
```

---

## Self-review notes

- **Spec coverage:** every section of `2026-04-12-crew-date-voting-design.md` maps to at least one task — data model (Task 4), four API routes (Tasks 4–6), phone-number roster (Task 8), repurposed date step (Task 9), share screen + SMS + dashboard (Tasks 10–11), lock & final plan (Task 12), voter flow (Task 13), error handling and verification (Task 14). The explicit non-goals (Twilio, accounts, activity voting) stay non-goals.
- **No placeholders:** each code step includes the actual code; no "TBD" or "add error handling" gestures. The one intentional cross-task reference is the `phones[]` global introduced in Task 8 and used in Tasks 11/12/13 — all definitions match.
- **Type/name consistency:** `planId`, `phones`, `availability`, `renderShare`, `renderFinal`, `startPolling`, `stopPolling`, `smsHref`, `shareInviteMessage`, `shareFinalMessage`, `escapeHtml` all defined once and used with matching names downstream. Backend: `putPlan`/`getPlan`/`callClaude`/`buildConsensusPrompt`/`parseConsensusResponse`/`buildPlanPrompt`/`parsePlanResponse` consistent across `kvStore.js`, `consensus.js`, `planBuilder.js`, `planRoutes.js`.
