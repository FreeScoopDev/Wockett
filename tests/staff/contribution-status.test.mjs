// Contribution status on the staff dashboard (spec feat/contribution-status, C1).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import {
  CONTRIBUTION_KINDS, STATUS_RECORD_PREFIX, isClaimToken, contributionStatusName, isContributionStatusName,
  knownContribution, contributionStatusFields, nominationStatusNames, statusDecidedAt, statusesToWithdraw,
  groupReports, queue, groupNominations, NON_ITEM_TARGETS, actionFields, isUnknownRecordType,
  unfeatureLookup, toldText, featureTellText,
} from '../../docs/staff/logic.js';
import {
  publishNominationStatuses, findNominationStatuses, withdrawNominationStatuses,
  featureTrailAndTell, unfeatureTrailAndWithdraw, countNominationsToTell,
} from '../../docs/staff/actions.js';
import { plain, pagedQuery, nominationStatusName, connect, fetchExisting } from '../../docs/staff/ck.js';

const NOW = Date.UTC(2026, 9, 16, 12, 0, 0);
const TOKEN = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';
// shasum -a 256 of the token's exact text, computed outside this code.
const TOKEN_NAME = 'status.949960179bb0c122dce42afa24e79611f32cbea403a75ffe8b4d5c07e73ed951';
const TOKEN2 = '0B4E1D7A-2F3C-4A5B-8C9D-AEBFC0D1E2F3';
// The same person's second device (or a reinstall): a token of its own.
const TOKEN3 = '5D2C9A41-7E6B-4F80-9A1C-3B2D4E5F6A7B';
const CREATOR = '_a1b2c3d4e5f60718293a4b5c6d7e8f90';
const trail = { trailKey: 'nc:w1', trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400 };
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

/** A nomination as ck.js hands it to the page: `statusName` instead of the token. */
const nom = (recordName, statusName, trailKey = 'nc:w1') => ({
  recordName, recordType: 'TrailNomination', created: 1, ...(statusName ? { statusName } : {}),
  fields: { trailKey, trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64 },
});
const NAME_A = `status.${'a'.repeat(64)}`;
const NAME_B = `status.${'b'.repeat(64)}`;
const NAME_C = `status.${'c'.repeat(64)}`;

/**
 * A store like ck.js's `connect()`: `nominations` and `statuses` answer
 * queries; `existing` maps record names to what `fetch` finds; `failWriteAt`
 * fails the Nth status write and every one after; `failWriteNames` fails
 * those names; `failDeleteAt` the Nth delete that isn't History or a
 * feature; `failFeature` the FeaturedTrail write; `failFeaturedDelete` the
 * FeaturedTrail delete; `failStatusQuery` is thrown by ContributionStatus
 * queries. Each History record gets its own name (`act1`, `act2`, …).
 */
function fakeStore({ nominations = [], statuses = [], existing = new Map(), failWriteAt = null, failWriteNames = [], failDeleteAt = null, partly,
  failFeature = false, failFeaturedDelete = false, failStatusQuery = null } = {}) {
  const calls = [];
  let writes = 0;
  let deletes = 0;
  let acts = 0;
  const write = (kind) => async (recordType, recordName, fields) => {
    calls.push([kind, recordType, recordName, fields]);
    if (recordType === 'FeaturedTrail' && failFeature) throw { ckErrorCode: 'ACCESS_DENIED' };
    if (recordType !== 'ContributionStatus') return;
    writes += 1;
    if (failWriteNames.includes(recordName)) throw { ckErrorCode: 'SERVER_RECORD_CHANGED' };
    if (failWriteAt !== null && writes >= failWriteAt) throw { ckErrorCode: 'NETWORK_ERROR' };
  };
  return {
    calls,
    async query(recordType, options) {
      calls.push(['query', recordType, options]);
      if (recordType === 'ContributionStatus' && failStatusQuery) throw failStatusQuery;
      return { records: recordType === 'ContributionStatus' ? statuses : nominations, more: false };
    },
    async fetch(names) { calls.push(['fetch', names]); return new Map(names.filter((n) => existing.has(n)).map((n) => [n, existing.get(n)])); },
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: `act${++acts}`, recordType, created: 1, fields: {} }; },
    createNamed: write('createNamed'),
    replaceNamed: write('replaceNamed'),
    async delete(names) {
      calls.push(['delete', names]);
      if (/^act\d+$/.test(names[0])) return;
      if (names[0].startsWith('featured.')) {
        if (failFeaturedDelete) throw { ckErrorCode: 'NETWORK_ERROR' };
        return;
      }
      deletes += 1;
      if (failDeleteAt !== null && deletes >= failDeleteAt) throw { ckErrorCode: 'NETWORK_ERROR', ...(partly === undefined ? {} : { deleted: partly }) };
    },
  };
}
/** An existing status record as `fetch` returns it. */
const stored = (recordName, fields = {}) => ({ recordName, recordType: 'ContributionStatus', created: 1,
  fields: { kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'Lake Loop', decidedAt: 5, ...fields } });
const statusWrites = (store) => store.calls.filter((c) => (c[0] === 'createNamed' || c[0] === 'replaceNamed') && c[1] === 'ContributionStatus');
const history = (store) => store.calls.filter((c) => c[0] === 'create' && c[1] === 'ModerationAction').map((c) => c[2]);

// MARK: The vocabulary

test('the closed vocabulary is exactly nomination/featured and suggestion/added, with nothing negative', () => {
  // The app mirrors this; changing it is a spec change, not a refactor.
  assert.equal(STATUS_RECORD_PREFIX, 'status.');
  assert.deepEqual(Object.fromEntries(Object.entries(CONTRIBUTION_KINDS).map(([k, v]) => [k, Object.keys(v.statuses)])), {
    nomination: ['featured'],
    suggestion: ['added'],
  });
  assert.ok(Object.isFrozen(CONTRIBUTION_KINDS));
  for (const kind of Object.values(CONTRIBUTION_KINDS)) assert.ok(Object.isFrozen(kind) && Object.isFrozen(kind.statuses));
});

test('a kind and status must both be known, and belong together', () => {
  assert.ok(knownContribution('nomination', 'featured'));
  assert.ok(knownContribution('suggestion', 'added'));
  assert.ok(!knownContribution('nomination', 'added'));
  assert.ok(!knownContribution('suggestion', 'featured'));
  assert.ok(!knownContribution('nomination', 'rejected'));
  assert.ok(!knownContribution('Nomination', 'featured'), 'case matters');
  assert.ok(!knownContribution(['nomination'], 'featured'), 'only strings');
  assert.ok(!knownContribution('nomination', ['featured']), 'only strings');
  for (const odd of ['toString', '__proto__', 'constructor', 'hasOwnProperty']) {
    assert.ok(!knownContribution(odd, 'featured'), odd);
    assert.ok(!knownContribution('nomination', odd), odd);
  }
});

// MARK: The record name

test('the status name is status.<sha256 hex of the token as written>', async () => {
  assert.equal(await contributionStatusName(TOKEN), TOKEN_NAME);
  assert.equal(TOKEN_NAME, `status.${sha(TOKEN)}`);
  // As written: the lowercase spelling is a different token to hash.
  assert.equal(await contributionStatusName(TOKEN.toLowerCase()), `status.${sha(TOKEN.toLowerCase())}`);
  assert.notEqual(await contributionStatusName(TOKEN.toLowerCase()), TOKEN_NAME);
  assert.ok(isContributionStatusName(TOKEN_NAME));
});

test('the name comes from the token alone: nothing public about the trail or the nominator recreates it', async () => {
  const name = await contributionStatusName(TOKEN);
  const hex = name.slice('status.'.length);
  // What anyone could compute: the trail key and the nominator's public id, in any arrangement.
  for (const guess of [`${trail.trailKey}\n${CREATOR}`, `${CREATOR}\n${trail.trailKey}`, trail.trailKey, CREATOR,
    `${trail.trailKey}${CREATOR}`, `${trail.trailKey}\n${CREATOR}\n${TOKEN}`, `${trail.trailKey}\n${TOKEN}`]) {
    assert.notEqual(hex, sha(guess), guess);
  }
  // The nomination's own record name (the app's) is a different thing.
  assert.notEqual(name, `nomination.${sha(`${trail.trailKey}\n${CREATOR}`)}`);
  // Two nominations by one person, or on one trail, get unrelated names.
  assert.notEqual(await contributionStatusName(TOKEN2), name);
});

test('only a UUID is a claim token; a bad one is refused without repeating it', async () => {
  assert.ok(isClaimToken(TOKEN) && isClaimToken(TOKEN.toLowerCase()));
  for (const bad of ['', 'nc:w1', `${TOKEN} `, ` ${TOKEN}`, `x${TOKEN}`, `${TOKEN}0`, `0${TOKEN}`, TOKEN.replace(/-/g, ''), 'E621E1F8-C36-495A-93FC-0C247A3E6E5F', 'G621E1F8-C36C-495A-93FC-0C247A3E6E5F', null, 42, {}]) {
    assert.ok(!isClaimToken(bad), String(bad));
  }
  const secret = 'not-a-uuid-but-secret-ish';
  await assert.rejects(contributionStatusName(secret), (e) => !String(e.message).includes(secret));
});

test('only status.<64 lowercase hex> is a status name', () => {
  assert.ok(isContributionStatusName(NAME_A));
  for (const bad of [`status.${'A'.repeat(64)}`, `status.${'a'.repeat(63)}`, `status.${'a'.repeat(65)}`, `x${NAME_A}`, `xtatus.${'a'.repeat(64)}`, `featured.${'a'.repeat(64)}`, undefined]) {
    assert.ok(!isContributionStatusName(bad), String(bad));
  }
});

// MARK: The record

test('a status record holds exactly kind, status, trailKey, trailName and decidedAt', () => {
  const fields = contributionStatusFields({
    kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: '  Lake Loop ', decidedAt: NOW,
    claimToken: TOKEN, creator: CREATOR, note: 'x', statusName: NAME_A,
  });
  assert.deepEqual(fields, { kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'Lake Loop', decidedAt: { value: NOW, type: 'TIMESTAMP' } });
  assert.throws(() => contributionStatusFields({ kind: 'nomination', status: 'rejected', trailKey: 'nc:w1', trailName: 'L', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'nomination', status: 'featured', trailKey: 'route-1', trailName: 'L', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: '  ', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'L', decidedAt: NaN }));
});

// MARK: ck.js keeps the token

const rawNom = (recordName, token, { who = CREATOR, key = 'nc:w1', created = 1 } = {}) => ({
  recordName, recordType: 'TrailNomination', created: { timestamp: created, userRecordName: who },
  fields: { trailKey: { value: key }, trailName: { value: 'Lake Loop' }, latitude: { value: 35.78 }, longitude: { value: -78.64 },
            ...(token === undefined ? {} : { claimToken: { value: token } }) },
});

test('a nomination reaches the page with its status name, never its token or its nominator', async () => {
  const db = { async performQuery() {
    return { records: [rawNom('n1', TOKEN), rawNom('n2', undefined, { who: '_b0000000000000000' }), rawNom('n3', 'junk', { who: '_c0000000000000000' })], moreComing: false };
  } };
  const { records } = await pagedQuery(db, { recordType: 'TrailNomination' });
  assert.equal(records.length, 3);
  assert.equal(records[0].statusName, TOKEN_NAME);
  assert.equal(records[1].statusName, undefined, 'no token: nothing to write');
  assert.equal(records[2].statusName, undefined, 'not a UUID: ignored');
  const page = JSON.stringify(records);
  assert.ok(!page.includes(TOKEN), 'the token never leaves ck.js');
  assert.ok(!page.includes('claimToken'));
  assert.ok(!page.includes(CREATOR), 'nor the nominator');
  assert.equal(await nominationStatusName(rawNom('n', TOKEN)), TOKEN_NAME);
});

test('every nomination of one person reaches the status path, each with its own name; the queue still counts the person once', async () => {
  // One person, one trail: a phone (newest), an older device, and a nomination sent before tokens existed.
  const raws = [rawNom('n1', TOKEN3, { created: 3 }), rawNom('n2', TOKEN, { created: 2 }), rawNom('n3', undefined, { created: 1 })];
  const db = { async performQuery() { return { records: raws, moreComing: false }; } };
  const every = await pagedQuery(db, { recordType: 'TrailNomination' }, { everyNomination: true });
  assert.deepEqual(every.records.map((r) => r.statusName), [`status.${sha(TOKEN3)}`, TOKEN_NAME, undefined]);
  assert.deepEqual(nominationStatusNames(every.records, 'nc:w1'), { names: [`status.${sha(TOKEN3)}`, TOKEN_NAME].sort(), withoutToken: 1 });
  const queue = await pagedQuery(db, { recordType: 'TrailNomination' });
  assert.deepEqual(queue.records.map((r) => r.recordName), ['n1'], 'the nomination queue still keeps the newest per person');
  for (const secret of [TOKEN, TOKEN3, CREATOR, 'claimToken']) assert.ok(!JSON.stringify(every.records).includes(secret), secret);
});

test('plain() drops a claim token from any record, however it is fetched', async () => {
  for (const recordType of ['TrailNomination', 'ContributionStatus', 'WocketAchievement']) {
    const out = plain({ recordName: 'x', recordType, created: { timestamp: 1 }, fields: { claimToken: { value: TOKEN }, note: { value: 'hi' } } });
    assert.deepEqual(out.fields, { note: 'hi' }, recordType);
  }
  const db = { async fetchRecords() { return { records: [rawNom('n1', TOKEN)] }; } };
  const found = await fetchExisting(db, ['n1']);
  assert.ok(!JSON.stringify([...found.values()]).includes(TOKEN));
});

// MARK: Which statuses

test('statuses are planned only for this trail\'s nominations that carry a token, once each, in a fixed order', () => {
  const out = nominationStatusNames([
    nom('n1', NAME_B), nom('n2', NAME_A), nom('n3', undefined), nom('n4', NAME_A), nom('n5', NAME_C, 'nc:w2'), nom('n6', 'status.short'),
  ], 'nc:w1');
  assert.deepEqual(out.names, [NAME_A, NAME_B]);
  assert.equal(out.withoutToken, 2, 'no token, and a name that is not a status name');
  assert.deepEqual(nominationStatusNames([], 'nc:w1'), { names: [], withoutToken: 0 });
});

test('featuring a trail with no tokened nominations writes nothing at all, and is not an error', async () => {
  const store = fakeStore({ nominations: [nom('n1'), nom('n2')] });
  const out = await publishNominationStatuses(store, { trail, now: NOW });
  assert.deepEqual(out, { written: 0, planned: 0, blocked: 0, withoutToken: 2, error: null });
  assert.deepEqual(store.calls, [['query', 'TrailNomination', { equals: ['trailKey', 'nc:w1'], max: 5000, everyNomination: true }]],
    'asks for every nomination of this trail, not one per person');
});

test('telling nominators writes History first, then one status per token, for this trail only', async () => {
  const store = fakeStore({ nominations: [nom('n1', NAME_B), nom('n2', NAME_A), nom('n3'), nom('n9', NAME_C, 'nc:w2')] });
  const out = await publishNominationStatuses(store, { trail, now: NOW });
  assert.deepEqual(out, { written: 2, planned: 2, blocked: 0, withoutToken: 1, error: null });
  assert.deepEqual(store.calls.map((c) => c[0]), ['query', 'query', 'fetch', 'create', 'createNamed', 'createNamed']);
  assert.deepEqual(store.calls[1], ['query', 'ContributionStatus', { equals: ['trailKey', 'nc:w1'], max: 1 }], 'the schema check');
  const [h] = history(store);
  assert.equal(h.action, 'statusPublished');
  assert.equal(h.targetType, 'contribution');
  assert.equal(h.targetRecordName, 'nc:w1');
  assert.equal(h.reportCount, 2);
  assert.deepEqual(JSON.parse(h.snapshot), { trailKey: 'nc:w1', trailName: 'Lake Loop', kind: 'nomination', status: 'featured', count: 2, blocked: 0 });
  assert.deepEqual(statusWrites(store).map((c) => c[2]), [NAME_A, NAME_B]);
  for (const c of statusWrites(store)) {
    assert.deepEqual(c[3], { kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'Lake Loop', decidedAt: { value: NOW, type: 'TIMESTAMP' } });
  }
});

test('publishing again replaces the same records with the same fields: no duplicates, no newer date', async () => {
  // Run once, remember what was written, then run again against it.
  const first = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B)] });
  await publishNominationStatuses(first, { trail, now: NOW });
  const existing = new Map(statusWrites(first).map((c) => [c[2], { recordName: c[2], recordType: 'ContributionStatus', fields: { ...c[3], decidedAt: c[3].decidedAt.value } }]));
  const again = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B)], existing });
  await publishNominationStatuses(again, { trail, now: NOW + 86_400_000 });
  assert.deepEqual(statusWrites(again).map((c) => c[0]), ['replaceNamed', 'replaceNamed']);
  assert.deepEqual(statusWrites(again).map((c) => [c[2], c[3]]), statusWrites(first).map((c) => [c[2], c[3]]));
  // A record that said something else, or has no usable date, is brought up to date.
  const same = { kind: 'nomination', status: 'featured', trailKey: 'nc:w1' };
  assert.equal(statusDecidedAt({ fields: { ...same, decidedAt: 5 } }, same, NOW), 5);
  assert.equal(statusDecidedAt({ fields: { ...same, kind: 'suggestion', decidedAt: 5 } }, same, NOW), NOW, 'kind differs');
  assert.equal(statusDecidedAt({ fields: { ...same, status: 'added', decidedAt: 5 } }, same, NOW), NOW, 'status differs');
  assert.equal(statusDecidedAt({ fields: { ...same, trailKey: 'nc:w2', decidedAt: 5 } }, same, NOW), NOW, 'trail differs');
  assert.equal(statusDecidedAt({ fields: { ...same } }, same, NOW), NOW, 'no date');
  assert.equal(statusDecidedAt({ fields: { ...same, decidedAt: '5' } }, same, NOW), NOW, 'not a number');
  assert.equal(statusDecidedAt(undefined, same, NOW), NOW);
});

test('a nominator who arrives after the first feature gets a new record; the existing one is replaced as it was', async () => {
  const store = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B)], existing: new Map([[NAME_A, stored(NAME_A)]]) });
  const out = await publishNominationStatuses(store, { trail, now: NOW });
  assert.equal(out.written, 2);
  const fields = (decidedAt) => ({ kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'Lake Loop', decidedAt: { value: decidedAt, type: 'TIMESTAMP' } });
  assert.deepEqual(statusWrites(store).map((c) => [c[0], c[2], c[3]]), [
    ['replaceNamed', NAME_A, fields(5)], ['createNamed', NAME_B, fields(NOW)],
  ]);
});

test('a status name already used by another record is skipped, and can\'t stop the others being told', async () => {
  // Anyone can create a nomination under a record name of their choosing, including a status name.
  const squatted = new Map([[NAME_A, { recordName: NAME_A, recordType: 'TrailNomination', fields: {} }]]);
  const store = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B), nom('n3', NAME_C)], existing: squatted });
  const out = await publishNominationStatuses(store, { trail, now: NOW });
  assert.deepEqual(out, { written: 2, planned: 2, blocked: 1, withoutToken: 0, error: null });
  assert.deepEqual(statusWrites(store).map((c) => [c[0], c[2]]), [['createNamed', NAME_B], ['createNamed', NAME_C]]);
  assert.equal(history(store)[0].reportCount, 2);
  assert.equal(JSON.parse(history(store)[0].snapshot).blocked, 1, 'History says one was skipped');

  const all = fakeStore({ nominations: [nom('n1', NAME_A)], existing: squatted });
  assert.deepEqual(await publishNominationStatuses(all, { trail, now: NOW }), { written: 0, planned: 0, blocked: 1, withoutToken: 0, error: null });
  assert.ok(!all.calls.some((c) => c[0] === 'create' || c[0] === 'createNamed' || c[0] === 'replaceNamed'), 'nothing written, no History');
});

test('when every writable status fails, the skipped count still reaches the page', async () => {
  const squatted = new Map([[NAME_A, { recordName: NAME_A, recordType: 'TrailNomination', fields: {} }]]);
  const store = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B)], existing: squatted, failWriteAt: 1 });
  const out = await featureTrailAndTell(store, { trail, blurb: 'Shady', length: '30d', now: NOW });
  assert.equal(out.told.blocked, 1);
  assert.equal(out.told.error.ckErrorCode, 'NETWORK_ERROR');
  assert.match(toldText(out.told), /1 couldn't be told/);
});

test('one status that fails doesn\'t stop the rest; History says how many were written', async () => {
  const store = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B), nom('n3', NAME_C)], failWriteNames: [NAME_A] });
  const out = await publishNominationStatuses(store, { trail, now: NOW });
  assert.equal(out.written, 2);
  assert.equal(out.planned, 3);
  assert.equal(out.error.ckErrorCode, 'SERVER_RECORD_CHANGED');
  assert.deepEqual(statusWrites(store).map((c) => c[2]), [NAME_A, NAME_B, NAME_C]);
  const fix = store.calls.find((c) => c[0] === 'replaceNamed' && c[1] === 'ModerationAction');
  assert.equal(fix[3].reportCount, 2);
  assert.equal(fix[3].note, 'Stopped part-way: 2 of 3 written.');
});

test('nothing is written where the schema has no ContributionStatus: CloudKit would create it with default grants', async () => {
  const missing = { serverErrorCode: 'BAD_REQUEST', reason: 'did not find record type: ContributionStatus' };
  const store = fakeStore({ nominations: [nom('n1', NAME_A)], failStatusQuery: missing });
  await assert.rejects(publishNominationStatuses(store, { trail, now: NOW }), missing);
  assert.ok(!store.calls.some((c) => ['create', 'createNamed', 'replaceNamed', 'fetch'].includes(c[0])));
  assert.ok(isUnknownRecordType(missing));
  assert.ok(isUnknownRecordType(new Error('Did not find record type: X')));
  assert.ok(!isUnknownRecordType({ ckErrorCode: 'NETWORK_ERROR' }));
  assert.ok(!isUnknownRecordType(undefined));
});

test('a failure on the first status takes History back; part-way, History says how many were written', async () => {
  const first = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B), nom('n3', NAME_C)], failWriteAt: 1 });
  await assert.rejects(publishNominationStatuses(first, { trail, now: NOW }), { ckErrorCode: 'NETWORK_ERROR' });
  assert.equal(statusWrites(first).length, 3, 'every one tried');
  assert.deepEqual(first.calls.at(-1), ['delete', ['act1']]);

  const later = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B), nom('n3', NAME_C)], failWriteAt: 3 });
  const out = await publishNominationStatuses(later, { trail, now: NOW });
  assert.equal(out.written, 2);
  assert.equal(out.planned, 3);
  assert.equal(out.error.ckErrorCode, 'NETWORK_ERROR');
  assert.ok(!later.calls.some((c) => c[0] === 'delete'), 'the action stays: two statuses were written');
  const fix = later.calls.find((c) => c[0] === 'replaceNamed' && c[1] === 'ModerationAction');
  assert.equal(fix[2], 'act1');
  // Rebuilt from what was sent: every field of the action is still there.
  assert.deepEqual(fix[3], {
    ...actionFields({ target: 'nc:w1', type: 'contribution', action: 'statusPublished', reportCount: 3, snapshot: '' }),
    reportCount: 2, note: 'Stopped part-way: 2 of 3 written.',
    snapshot: JSON.stringify({ trailKey: 'nc:w1', trailName: 'Lake Loop', kind: 'nomination', status: 'featured', count: 2, blocked: 0, planned: 3 }),
  });
});

test('a trail with no usable name writes nothing, not even History', async () => {
  const store = fakeStore({ nominations: [nom('n1', NAME_A)] });
  await assert.rejects(publishNominationStatuses(store, { trail: { ...trail, trailName: ' ' }, now: NOW }));
  assert.ok(!store.calls.some((c) => c[0] === 'create' || c[0] === 'createNamed'));
});

test('Feature stands even when telling the nominators fails, and the status names the trail as featured', async () => {
  // The trail was featured before under its first name; a later nomination calls it something else.
  const existingFeature = { fields: { trailKey: 'nc:w1', trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400 } };
  const store = fakeStore({ nominations: [nom('n1', NAME_A)], existing: new Map([['featured.nc.w1', existingFeature]]), failWriteAt: 1 });
  const out = await featureTrailAndTell(store, { trail: { ...trail, trailName: 'Renamed By Someone' }, blurb: 'Shady', length: '30d', now: NOW });
  assert.equal(out.trail.trailName, 'Lake Loop');
  assert.equal(out.told.error.ckErrorCode, 'NETWORK_ERROR');
  assert.ok(store.calls.some((c) => c[0] === 'replaceNamed' && c[1] === 'FeaturedTrail'), 'the feature was written');
  assert.equal(statusWrites(store)[0][3].trailName, 'Lake Loop');
  // Feature's own History (act1) stays; only the status action (act2) was taken back.
  assert.deepEqual(history(store).map((h) => h.action), ['featured', 'statusPublished']);
  assert.deepEqual(store.calls.filter((c) => c[0] === 'delete'), [['delete', ['act2']]]);

  const ok = fakeStore({ nominations: [nom('n1', NAME_A)] });
  const done = await featureTrailAndTell(ok, { trail, blurb: 'Shady', length: '30d', now: NOW });
  assert.equal(done.told.written, 1);
  assert.deepEqual(ok.calls.map((c) => c[0]), ['fetch', 'create', 'createNamed', 'query', 'query', 'fetch', 'create', 'createNamed'],
    'featured first, then the statuses');
  assert.deepEqual(statusWrites(ok)[0][3].decidedAt, { value: NOW, type: 'TIMESTAMP' }, 'the time given');

  // A feature that fails tells no one.
  const failing = fakeStore({ nominations: [nom('n1', NAME_A)], failFeature: true });
  await assert.rejects(featureTrailAndTell(failing, { trail, blurb: 'Shady', length: '30d', now: NOW }));
  assert.equal(statusWrites(failing).length, 0);
  assert.ok(!history(failing).some((h) => h.action === 'statusPublished'));
});

// MARK: What the page says and offers

test('Unfeature proceeds when the count is known or the type does not exist yet; any other failure needs "anyway"', () => {
  assert.equal(unfeatureLookup(null), 'checked');
  assert.equal(unfeatureLookup({ serverErrorCode: 'BAD_REQUEST', reason: 'did not find record type: ContributionStatus' }), 'none');
  assert.equal(unfeatureLookup({ ckErrorCode: 'NETWORK_ERROR' }), 'unchecked');
  assert.equal(unfeatureLookup({ ckErrorCode: 'ACCESS_DENIED', reason: 'not allowed' }), 'unchecked');
});

test('the Feature confirm says how many nominations it tells, that other devices count, none, or that it tells them in general', () => {
  assert.equal(featureTellText(2), 'It also tells 2 nominations: each shows Featured in My contributions on the device that sent it, '
    + 'so someone who nominated it from two devices sees it on both.');
  assert.match(featureTellText(1), /^It also tells 1 nomination: /);
  assert.match(featureTellText(0), /^None of its nominations can be told yet/);
  assert.match(featureTellText(null), /^Its nominators are told too: .* on the device that sent it\.$/);
});

test('the Feature confirm counts every nomination of the trail, as Feature writes them', async () => {
  // Two nominations by one person (two devices) arrive as two records with two names.
  const store = fakeStore({ nominations: [nom('n1', NAME_A), nom('n2', NAME_B), nom('n3'), nom('n4', NAME_C, 'nc:w2')] });
  assert.equal(await countNominationsToTell(store, { trailKey: 'nc:w1' }), 2);
  assert.deepEqual(store.calls, [['query', 'TrailNomination', { equals: ['trailKey', 'nc:w1'], max: 5000, everyNomination: true }]]);
  assert.equal(await countNominationsToTell(fakeStore({ nominations: [nom('n1')] }), { trailKey: 'nc:w1' }), 0);
});

test('the message after Feature says who was told, who was skipped, and how to finish', () => {
  assert.equal(toldText({ written: 0, planned: 0, blocked: 0, error: null }), '');
  assert.equal(toldText({ written: 2, planned: 2, blocked: 0, error: null }), 'Told 2 nominations.');
  assert.equal(toldText({ written: 1, planned: 1, blocked: 1, error: null }),
    'Told 1 nomination. 1 couldn\'t be told: another record already has that name (a crafted nomination, most likely).');
  assert.equal(toldText({ written: 2, planned: 3, blocked: 0, error: { ckErrorCode: 'NETWORK_ERROR' } }),
    'Told 2 of 3 nominations; the rest failed: Couldn\'t reach iCloud. Check the connection and try again. To finish, open Featured, Change note or length, and Feature (Keep).');
  assert.match(toldText({ written: 0, planned: null, blocked: 0, error: { ckErrorCode: 'NETWORK_ERROR' } }), /^Couldn't tell its nominators: Couldn't reach iCloud/);
  // No token can be in the text: told carries counts and an error only.
  assert.ok(!toldText({ written: 1, planned: 1, blocked: 0, error: null }).includes('status.'));
});

// MARK: Withdrawing

const status = (recordName, fields = {}) => ({
  recordName, recordType: 'ContributionStatus', created: 1,
  fields: { kind: 'nomination', status: 'featured', trailKey: 'nc:w1', trailName: 'Lake Loop', decidedAt: NOW, ...fields },
});

test('only this trail\'s nomination statuses, under a dashboard-made name, are withdrawn', async () => {
  const records = [status(NAME_A), status(NAME_B, { kind: 'suggestion', status: 'added' }), status(NAME_C, { trailKey: 'nc:w2' }),
    status('featured.nc.w1'), status(`status.${'d'.repeat(64)}`),
    status(`status.${'e'.repeat(64)}`, { kind: 'suggestion' }), status(`status.${'f'.repeat(64)}`, { status: 'added' })];
  assert.deepEqual(statusesToWithdraw(records, 'nc:w1').map((r) => r.recordName), [NAME_A, `status.${'d'.repeat(64)}`]);
  const store = fakeStore({ statuses: records });
  const found = await findNominationStatuses(store, { trailKey: 'nc:w1' });
  assert.deepEqual(store.calls[0], ['query', 'ContributionStatus', { equals: ['trailKey', 'nc:w1'], max: 5000 }]);
  assert.deepEqual(found.records.map((r) => r.recordName), [NAME_A, `status.${'d'.repeat(64)}`]);
});

test('withdrawing writes History with the count, then deletes only those; nothing to withdraw writes nothing', async () => {
  const store = fakeStore();
  // Whatever is passed, only this trail's nomination statuses are deleted.
  const out = await withdrawNominationStatuses(store, { trail, records: [status(NAME_A), status(NAME_B, { kind: 'suggestion', status: 'added' }),
    status(NAME_C, { trailKey: 'nc:w2' }), status('featured.nc.w1')] });
  assert.deepEqual(out, { deleted: 1, error: null });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'delete']);
  const [h] = history(store);
  assert.deepEqual(h, actionFields({
    target: 'nc:w1', type: 'contribution', action: 'statusWithdrawn', reportCount: 1,
    snapshot: JSON.stringify({ trailKey: 'nc:w1', trailName: 'Lake Loop', kind: 'nomination', status: 'featured', count: 1 }),
  }));
  assert.ok(!JSON.stringify(h).includes('status.'), 'no status name in History');
  assert.deepEqual(store.calls[1], ['delete', [NAME_A]]);

  const none = fakeStore();
  assert.deepEqual(await withdrawNominationStatuses(none, { trail, records: [] }), { deleted: 0, error: null });
  assert.equal(none.calls.length, 0);
});

test('Unfeature withdraws the statuses before the feature; a failure stops before the trail leaves Featured', async () => {
  const ok = fakeStore();
  const out = await unfeatureTrailAndWithdraw(ok, { trail, statuses: [status(NAME_A), status(NAME_B)] });
  assert.equal(out.unfeatured, true);
  assert.deepEqual(ok.calls.map((c) => [c[0], c[0] === 'create' ? c[2].action : c[1]]), [
    ['create', 'statusWithdrawn'], ['delete', [NAME_A, NAME_B]], ['create', 'unfeatured'], ['delete', ['featured.nc.w1']],
  ]);

  const first = fakeStore({ failDeleteAt: 1 });
  await assert.rejects(unfeatureTrailAndWithdraw(first, { trail, statuses: [status(NAME_A)] }));
  assert.ok(!first.calls.some((c) => c[0] === 'delete' && c[1][0] === 'featured.nc.w1'), 'still featured');
  assert.deepEqual(first.calls.at(-1), ['delete', ['act1']], 'History taken back');

  // 250 statuses: the second batch of 200 fails after deleting 10 of its 50.
  const many = Array.from({ length: 250 }, (_, i) => status(`status.${i.toString(16).padStart(64, '0')}`));
  const later = fakeStore({ failDeleteAt: 2, partly: 10 });
  const part = await unfeatureTrailAndWithdraw(later, { trail, statuses: many });
  assert.equal(part.unfeatured, false);
  assert.equal(part.withdrawn.deleted, 210);
  assert.ok(!later.calls.some((c) => c[0] === 'delete' && c[1][0] === 'featured.nc.w1'), 'still featured');
  const fix = later.calls.find((c) => c[0] === 'replaceNamed' && c[1] === 'ModerationAction');
  assert.equal(fix[3].reportCount, 210);
  assert.equal(fix[3].action, 'statusWithdrawn');

  // Withdrawn, then the unfeature itself fails: reported, not thrown, with the count.
  const after = fakeStore({ failFeaturedDelete: true });
  const stuck = await unfeatureTrailAndWithdraw(after, { trail, statuses: [status(NAME_A)] });
  assert.equal(stuck.unfeatured, false);
  assert.equal(stuck.withdrawn.deleted, 1);
  assert.equal(stuck.error.ckErrorCode, 'NETWORK_ERROR');
  assert.deepEqual(after.calls.filter((c) => c[0] === 'delete').map((c) => c[1]), [[NAME_A], ['featured.nc.w1'], ['act2']],
    'the statusWithdrawn action (act1) stays; only unfeature\'s own (act2) is taken back');

  // The note reaches the unfeatured action, with and without statuses to withdraw.
  for (const statuses of [[], [status(NAME_A)]]) {
    const noted = fakeStore();
    await unfeatureTrailAndWithdraw(noted, { trail, statuses, note: 'Unfeatured anyway' });
    assert.equal(history(noted).find((h) => h.action === 'unfeatured').note, 'Unfeatured anyway', `${statuses.length} statuses`);
  }

  const nothing = fakeStore();
  assert.equal((await unfeatureTrailAndWithdraw(nothing, { trail, statuses: [] })).unfeatured, true);
  assert.deepEqual(nothing.calls.map((c) => c[0]), ['create', 'delete'], 'no statuses: Unfeature as before');
});

// MARK: Nothing secret reaches CloudKit, History or the page

/** CloudKit JS's public database, in memory, logging every save. A save of a name in `failNames` fails, as CloudKit JS reports it. */
function fakeCloudKit(records, { failNames = [] } = {}) {
  const byName = new Map(records.map((r) => [r.recordName, r]));
  const saved = [];
  let auto = 0;
  const save = (r) => {
    const rec = { ...r, recordName: r.recordName ?? `auto-${++auto}`, created: { timestamp: NOW, userRecordName: '_moderator0000000000' } };
    saved.push(rec);
    byName.set(rec.recordName, rec);
    return rec;
  };
  const db = {
    async performQuery(query) {
      const eq = query.filterBy?.find((f) => f.fieldName);
      const found = [...byName.values()].filter((r) => r.recordType === query.recordType
        && (!eq || r.fields?.[eq.fieldName]?.value === eq.fieldValue.value));
      return { records: found, moreComing: false };
    },
    async fetchRecords(names) { return { records: names.filter((n) => byName.has(n)).map((n) => byName.get(n)) }; },
    async saveRecords(list) {
      const failed = list.filter((r) => failNames.includes(r.recordName));
      if (failed.length) return { hasErrors: true, errors: failed.map((r) => ({ ckErrorCode: 'NETWORK_ERROR', recordName: r.recordName })), records: [] };
      return { records: list.map(save) };
    },
    newRecordsBatch() {
      let pending;
      return { forceReplace(r) { pending = r; return this; }, async commit() { return { records: [save(pending)] }; } };
    },
    async deleteRecords(names) { for (const n of names) byName.delete(n); return { records: names.map((recordName) => ({ recordName })) }; },
  };
  return { saved, byName, CloudKit: { configure() {}, getDefaultContainer() { return { publicCloudDatabase: db }; } } };
}

test('end to end through ck.js: no token, nominator or status name in History; no token or nominator in any status', async () => {
  const other = '_f9e8d7c6b5a4938271605f4e3d2c1b0a';
  // CREATOR nominated from two devices (nomination.w is the second, newer) and once more before tokens existed.
  const cloud = fakeCloudKit([rawNom('nomination.w', TOKEN3, { created: 3 }), rawNom('nomination.x', TOKEN, { created: 2 }),
    rawNom('nomination.v', undefined, { created: 1 }),
    rawNom('nomination.y', TOKEN2, { who: other }), rawNom('nomination.z', undefined, { who: '_z000000000000000' })]);
  const store = connect({ CloudKit: cloud.CloudKit });
  assert.equal(await countNominationsToTell(store, { trailKey: 'nc:w1' }), 3, 'the confirm counts both of one person\'s devices');
  const out = await featureTrailAndTell(store, { trail, blurb: 'Shady', length: '30d', now: NOW });
  assert.equal(out.told.written, 3, 'one status per token: both of CREATOR\'s devices, and the other nominator');
  assert.equal(out.told.withoutToken, 2, 'the two nominations without a token get nothing');
  const statuses = cloud.saved.filter((r) => r.recordType === 'ContributionStatus');
  assert.deepEqual(statuses.map((r) => r.recordName).sort(), [TOKEN_NAME, `status.${sha(TOKEN2)}`, `status.${sha(TOKEN3)}`].sort());
  const actions = cloud.saved.filter((r) => r.recordType === 'ModerationAction');
  for (const secret of [TOKEN, TOKEN2, TOKEN3, TOKEN.toLowerCase(), TOKEN3.toLowerCase(), CREATOR, other, 'claimToken']) {
    assert.ok(!JSON.stringify(cloud.saved).includes(secret), `${secret} reached CloudKit`);
  }
  for (const name of [TOKEN_NAME, `status.${sha(TOKEN2)}`, `status.${sha(TOKEN3)}`, sha(TOKEN), sha(TOKEN2), sha(TOKEN3)]) {
    assert.ok(!JSON.stringify(actions).includes(name), 'History holds the count, not the names');
  }
  for (const r of statuses) assert.deepEqual(Object.keys(r.fields).sort(), ['decidedAt', 'kind', 'status', 'trailKey', 'trailName']);
  // What the page itself holds after loading nominations.
  const { records } = await store.query('TrailNomination');
  for (const secret of [TOKEN, TOKEN2, TOKEN3, CREATOR, other, 'claimToken']) assert.ok(!JSON.stringify(records).includes(secret));
  assert.equal(JSON.parse(cloud.saved.find((r) => r.fields?.action?.value === 'statusPublished').fields.snapshot.value).count, 3);

  // Featuring again (Change note or length) rewrites the same three records, and nothing new.
  const before = new Set(cloud.byName.keys());
  await featureTrailAndTell(store, { trail, blurb: 'Shadier', keepUntil: null, now: NOW + 1000 });
  assert.deepEqual([...cloud.byName.keys()].filter((k) => !before.has(k) && !k.startsWith('auto-')), []);
  assert.equal([...cloud.byName.values()].filter((r) => r.recordType === 'ContributionStatus').length, 3);

  // Unfeature withdraws all three, both of CREATOR's devices included, through the same store.
  const { records: found } = await findNominationStatuses(store, { trailKey: 'nc:w1' });
  const done = await unfeatureTrailAndWithdraw(store, { trail, statuses: found });
  assert.equal(done.withdrawn.deleted, 3);
  assert.equal([...cloud.byName.values()].filter((r) => r.recordType === 'ContributionStatus').length, 0);
  assert.ok(!cloud.byName.has('featured.nc.w1'));
  // Every History record of the whole run, Unfeature's included.
  const allActions = cloud.saved.filter((r) => r.recordType === 'ModerationAction');
  assert.deepEqual(allActions.map((r) => r.fields.action.value),
    ['featured', 'statusPublished', 'featured', 'statusPublished', 'statusWithdrawn', 'unfeatured']);
  for (const secret of [TOKEN, TOKEN2, TOKEN3, CREATOR, other, 'claimToken', TOKEN_NAME, `status.${sha(TOKEN2)}`, `status.${sha(TOKEN3)}`,
    sha(TOKEN), sha(TOKEN2), sha(TOKEN3)]) {
    assert.ok(!JSON.stringify(allActions).includes(secret), `${secret} reached History`);
  }
});

test('end to end through ck.js: one of a person\'s two devices failing still tells the other, and History says 1 of 2', async () => {
  const cloud = fakeCloudKit([rawNom('nomination.w', TOKEN3, { created: 3 }), rawNom('nomination.x', TOKEN, { created: 2 })],
    { failNames: [`status.${sha(TOKEN3)}`] });
  const store = connect({ CloudKit: cloud.CloudKit });
  const out = await featureTrailAndTell(store, { trail, blurb: 'Shady', length: '30d', now: NOW });
  assert.deepEqual([out.told.written, out.told.planned, out.told.error?.ckErrorCode], [1, 2, 'NETWORK_ERROR']);
  assert.deepEqual([...cloud.byName.values()].filter((r) => r.recordType === 'ContributionStatus').map((r) => r.recordName), [TOKEN_NAME]);
  const told = cloud.byName.get(cloud.saved.find((r) => r.fields?.action?.value === 'statusPublished').recordName);
  assert.equal(told.fields.reportCount.value, 1, 'History corrected to the number written');
  assert.equal(told.fields.note.value, 'Stopped part-way: 1 of 2 written.');
  assert.deepEqual(JSON.parse(told.fields.snapshot.value), { trailKey: 'nc:w1', trailName: 'Lake Loop', kind: 'nomination', status: 'featured', count: 1, blocked: 0, planned: 2 });
  for (const secret of [TOKEN, TOKEN3, CREATOR, sha(TOKEN), sha(TOKEN3)]) assert.ok(!JSON.stringify(told).includes(secret), secret);
});

// MARK: History and the queues

test('a contribution action never closes a community report or a nomination with the same name', () => {
  assert.ok(NON_ITEM_TARGETS.includes('contribution'));
  const report = { recordName: 'r1', created: 1, fields: { targetRecordName: 'nc:w1', targetType: 'post', reason: 'spam' } };
  const action = { created: 5, fields: { targetRecordName: 'nc:w1', targetType: 'contribution', action: 'statusPublished' } };
  assert.equal(queue(groupReports([report], [action])).length, 1);
  const [g] = groupNominations([nom('n1', NAME_A)], [action]);
  assert.equal(g.open, true);
});

test('the page counts nominations to tell from the every-nomination query, never from the per-person queue', () => {
  // The Nominations tab's groups hold one nomination per person, so a count
  // taken from them would leave out a person's other devices.
  const app = readFileSync(new URL('../../docs/staff/app.js', import.meta.url), 'utf8');
  assert.ok(!/nominationStatusNames\(/.test(app), 'app.js counts statuses from loaded nominations');
  assert.match(app, /canTell = await countNominationsToTell\(store, \{ trailKey: trail\.trailKey \}\)/);
});

test('the two new History actions are known actions', () => {
  for (const action of ['statusPublished', 'statusWithdrawn']) {
    assert.equal(actionFields({ target: 'nc:w1', type: 'contribution', action }).action, action);
  }
});

test('no dialog reads its "length" select as form.elements.length, which is the number of controls', () => {
  // Feature and Suspend both did until this PR, so both always failed with "Unknown length: undefined".
  const app = readFileSync(new URL('../../docs/staff/app.js', import.meta.url), 'utf8');
  assert.doesNotMatch(app, /elements\.length\.value/);
  assert.equal((app.match(/elements\.namedItem\('length'\)\.value/g) ?? []).length, 2, 'Feature and Suspend');
});

// MARK: Schema

function schemaBlock(type) {
  const schema = readFileSync(new URL('../../cloudkit/schema.ckdb', import.meta.url), 'utf8');
  const match = schema.match(new RegExp(`RECORD TYPE ${type} \\(([\\s\\S]*?)\\n    \\);`));
  assert.ok(match, `${type} is in the schema`);
  return match[1];
}
const lines = (type) => schemaBlock(type).split('\n').map((l) => l.trim().replace(/\s+/g, ' ')).filter(Boolean);

test('a status is readable by everyone, written only by a Moderator, and holds exactly these fields', () => {
  assert.deepEqual(lines('ContributionStatus'), [
    '"___createTime" TIMESTAMP SORTABLE,', '"___createdBy" REFERENCE,', '"___etag" STRING,',
    '"___modTime" TIMESTAMP,', '"___modifiedBy" REFERENCE,', '"___recordID" REFERENCE QUERYABLE,',
    'decidedAt TIMESTAMP,', 'kind STRING,', 'status STRING,', 'trailKey STRING QUERYABLE,', 'trailName STRING,',
    'GRANT READ, CREATE, WRITE TO Moderator,', 'GRANT READ TO "_world"',
  ]);
});

test('a nomination gains claimToken and stays readable only by a Moderator', () => {
  assert.deepEqual(lines('TrailNomination'), [
    '"___createTime" TIMESTAMP SORTABLE,', '"___createdBy" REFERENCE,', '"___etag" STRING,',
    '"___modTime" TIMESTAMP,', '"___modifiedBy" REFERENCE,', '"___recordID" REFERENCE QUERYABLE,',
    'claimToken STRING,', 'latitude DOUBLE,', 'lengthMeters DOUBLE,', 'longitude DOUBLE,', 'note STRING,',
    'region STRING,', 'trailKey STRING QUERYABLE,', 'trailName STRING,',
    'GRANT READ, WRITE TO Moderator,', 'GRANT CREATE TO "_icloud"',
  ]);
});
