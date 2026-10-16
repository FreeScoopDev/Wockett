// Walker reports on the staff dashboard (spec feat/trail-walker-reports).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  WALKER_FACTS, MIN_AGREEING, AGREEMENT, verdictText, RETENTION_MONTHS, walkerVerdict, tallyWalkerReports, summaryRecordName,
  summaryFields, summaryStanding, summaryRows, retentionCutoff, expiredReports, isPublishableFact, countsOf,
  groupReports, queue, ACTIVITY_KINDS, DAY, walkerId,
} from '../../docs/staff/logic.js';
import {
  publishSummary, unpublishSummary, findExpiredReports, deleteExpiredReports, findReportsBy, deleteReportsBy,
} from '../../docs/staff/actions.js';
import { pagedQuery, buildQuery, plain, reporterToken, deleteAll, connect } from '../../docs/staff/ck.js';

const NOW = Date.UTC(2026, 9, 15, 12, 0, 0);
let seq = 0;
const rep = (reporter, value, { fact = 'dogs', trailKey = 'nc:w1', created } = {}) => {
  const n = ++seq;
  return {
    recordName: `report.${n}`, recordType: 'TrailFactReport', created: created ?? n, reporter,
    fields: { trailKey, region: trailKey.slice(0, 2), fact, value },
  };
};
const counts = (obj) => obj;

function fakeStore({ exists = false, failSave = false, failDeleteAt = null, partly = undefined, found = [] } = {}) {
  const calls = [];
  let deletes = 0;
  return {
    calls,
    // Like a save response that leaves fields out: History must be rebuilt from what was sent.
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: 'act1', recordType, created: 1, fields: {} }; },
    // `exists` is the one record name that exists (or true for any).
    async fetch(names) {
      calls.push(['fetch', names]);
      return new Map(names.filter((n) => exists === true || n === exists).map((n) => [n, { fields: {} }]));
    },
    async createNamed(recordType, recordName, fields) { calls.push(['createNamed', recordType, recordName, fields]); if (failSave) throw { ckErrorCode: 'ACCESS_DENIED' }; },
    async replaceNamed(recordType, recordName, fields) { calls.push(['replaceNamed', recordType, recordName, fields]); if (failSave) throw { ckErrorCode: 'ACCESS_DENIED' }; },
    async query(recordType, options) { calls.push(['query', recordType, options]); return { records: found, more: false }; },
    async queryByCreator(recordType, account, options) { calls.push(['queryByCreator', recordType, account, options]); return { records: found, more: false }; },
    async delete(names) {
      calls.push(['delete', names]);
      if (names[0] === 'act1') return;
      deletes += 1;
      if (failDeleteAt !== null && deletes >= failDeleteAt) throw { ckErrorCode: 'NETWORK_ERROR', ...(partly === undefined ? {} : { deleted: partly }) };
    },
  };
}

// MARK: The vocabulary

test('the closed vocabulary is exactly the confirmed facts and answers', () => {
  // The app mirrors this; changing it is a spec change, not a refactor.
  assert.deepEqual(Object.fromEntries(Object.entries(WALKER_FACTS).map(([k, f]) => [k, Object.keys(f.values)])), {
    dogs: ['leashRequired', 'offLeashOK', 'noDogs'],
    stroller: ['yes', 'no'],
    wheelchair: ['yes', 'no'],
    surface: ['paved', 'packedDirt', 'rockyOrRooty'],
    liked: ['up', 'down'],
  });
  assert.deepEqual(Object.keys(WALKER_FACTS).filter(isPublishableFact), ['dogs', 'stroller', 'wheelchair', 'surface']);
  assert.ok(Object.isFrozen(WALKER_FACTS) && Object.isFrozen(WALKER_FACTS.dogs.values));
});

// MARK: The rule

test('the rule\'s constants are Joe\'s: 3 walkers agreeing, 2 in 3 of those who answered, 12 months', () => {
  assert.equal(MIN_AGREEING, 3);
  assert.deepEqual({ ...AGREEMENT }, { numerator: 2, denominator: 3 });
  assert.equal(RETENTION_MONTHS, 12);
});

test('fewer than 3 walkers giving the same answer publish nothing, however much they agree', () => {
  assert.equal(walkerVerdict('dogs', counts({ leashRequired: 2 })).status, 'tooFew', '2 of 2');
  assert.equal(walkerVerdict('dogs', counts({ leashRequired: 1 })).status, 'tooFew', '1 of 1');
  const twoOfThree = walkerVerdict('surface', counts({ paved: 2, packedDirt: 1 }));
  assert.deepEqual([twoOfThree.status, twoOfThree.agreeing, twoOfThree.walkers], ['tooFew', 2, 3],
    '2 of 3 is two in three, but only 2 said so (Joe, 2026-10-15)');
  const three = walkerVerdict('dogs', counts({ leashRequired: 3 }));
  assert.deepEqual([three.status, three.value, three.agreeing, three.walkers], ['ready', 'leashRequired', 3, 3], '3 of 3');
});

test('3 or more agreeing must also be at least 2 in 3 of those who answered; just under is a split', () => {
  const threeOfFour = walkerVerdict('surface', counts({ paved: 3, packedDirt: 1 }));
  assert.deepEqual([threeOfFour.status, threeOfFour.value, threeOfFour.agreeing, threeOfFour.walkers], ['ready', 'paved', 3, 4]);
  assert.equal(walkerVerdict('surface', counts({ paved: 4, packedDirt: 2 })).status, 'ready', '4 of 6 is exactly 2 in 3');
  assert.equal(walkerVerdict('surface', counts({ paved: 3, packedDirt: 2 })).status, 'split', '3 of 5 is 0.6');
  assert.equal(walkerVerdict('surface', counts({ paved: 3, packedDirt: 1, rockyOrRooty: 1 })).status, 'split', '3 of 5, three answers');
  assert.equal(walkerVerdict('surface', counts({ paved: 5, packedDirt: 3 })).status, 'split', '5 of 8 is 0.625');
  assert.equal(walkerVerdict('surface', counts({ paved: 6, packedDirt: 3 })).status, 'ready', '6 of 9');
  assert.equal(walkerVerdict('surface', counts({ paved: 2, packedDirt: 1, rockyOrRooty: 1 })).status, 'tooFew', '2 of 4');
});

test('the verdict in words gives the numbers the rule used', () => {
  const words = (counts) => verdictText('surface', walkerVerdict('surface', counts));
  assert.equal(words({ paved: 2, packedDirt: 1 }), 'Not enough walkers agree yet: 2 gave the same answer, 3 needed');
  assert.equal(words({ paved: 3, packedDirt: 2 }), 'Walkers disagree: the most given answer has 3 of 5, under 2 in 3');
  assert.equal(words({ paved: 3, packedDirt: 1 }), 'Ready to publish: Paved (3 of 4 walkers agree)');
  assert.equal(words({ paved: 2, packedDirt: 2 }), 'Walkers are tied, so nothing is published');
  assert.match(verdictText('liked', walkerVerdict('liked', { up: 9 })), /^Counted only\. No summary is published/);
});

test('a tie publishes nothing', () => {
  assert.equal(walkerVerdict('stroller', counts({ yes: 2, no: 2 })).status, 'tie');
  assert.equal(walkerVerdict('stroller', counts({ yes: 5, no: 5 })).status, 'tie');
  assert.equal(walkerVerdict('dogs', counts({ leashRequired: 3, noDogs: 3, offLeashOK: 1 })).status, 'tie');
});

test('answers outside the vocabulary never count toward the rule', () => {
  // Each case changes the verdict if the crafted answer counts: a crafted
  // answer alone would publish, and next to real ones it would make a split.
  for (const bad of ['bogus', 'toString', 'constructor', '__proto__', 'hasOwnProperty']) {
    assert.equal(walkerVerdict('dogs', { [bad]: 3 }).status, 'tooFew', `${bad} alone`);
    assert.equal(walkerVerdict('dogs', { leashRequired: 3, [bad]: 2 }).status, 'ready', `${bad} next to 3 real answers`);
  }
});

// MARK: Counting walkers

test('a walker counts once per trail and fact, with their newest answer', () => {
  const { trails } = tallyWalkerReports([
    rep('walker-1', 'noDogs', { created: 1 }), rep('walker-1', 'noDogs', { created: 2 }), rep('walker-1', 'leashRequired', { created: 3 }),
    rep('walker-2', 'leashRequired', { created: 4 }),
  ]);
  const dogs = trails[0].facts[0];
  assert.equal(dogs.verdict.walkers, 2, 'four records, two walkers');
  assert.deepEqual(countsOf(dogs), { leashRequired: 2, offLeashOK: 0, noDogs: 0 });
  assert.equal(dogs.verdict.status, 'tooFew');
});

test('one walker making many records can\'t reach the threshold alone', () => {
  const flood = Array.from({ length: 10 }, (_, i) => rep('walker-9', 'offLeashOK', { created: 100 + i }));
  const { trails } = tallyWalkerReports(flood);
  assert.equal(trails[0].facts[0].verdict.walkers, 1);
  assert.equal(trails[0].facts[0].verdict.publish, false);
});

test('the same walker counts on each trail and each fact they answered', () => {
  const { trails } = tallyWalkerReports([
    rep('walker-1', 'yes', { fact: 'stroller' }), rep('walker-1', 'noDogs'), rep('walker-1', 'noDogs', { trailKey: 'nc:w2' }),
  ]);
  assert.equal(trails.length, 2);
  const w1 = trails.find((t) => t.trailKey === 'nc:w1');
  assert.deepEqual(w1.facts.map((f) => [f.fact, f.verdict.walkers]), [['dogs', 1], ['stroller', 1]], 'in vocabulary order');
});

test('reports with an unknown fact, answer or trail key are ignored; with no walker, left out', () => {
  const out = tallyWalkerReports([
    rep('walker-1', 'muddy', { fact: 'conditions' }), rep('walker-1', 'muddy', { fact: 'surface' }),
    rep('walker-1', 'yes', { fact: 'stroller', trailKey: 'route-1' }), rep(undefined, 'yes', { fact: 'stroller' }),
    rep('walker-1', 'yes', { fact: 'stroller' }),
  ]);
  assert.equal(out.ignored, 3);
  assert.equal(out.unattributed, 1);
  assert.equal(out.trails.length, 1);
  assert.equal(out.trails[0].reports, 1);
});

test('a trail\'s region comes from its key, never the report', () => {
  const r = rep('walker-1', 'yes', { fact: 'stroller' });
  r.fields.region = 'zz';
  assert.equal(tallyWalkerReports([r]).trails[0].region, 'nc');
});

// MARK: `liked`

test('liked is counted and shown, but its verdict is never publishable', () => {
  const ten = Array.from({ length: 10 }, (_, i) => rep(`walker-${i}`, 'up', { fact: 'liked' }));
  const [trail] = tallyWalkerReports(ten).trails;
  const liked = trail.facts[0];
  assert.equal(liked.fact, 'liked');
  assert.deepEqual(countsOf(liked), { up: 10, down: 0 });
  assert.equal(liked.verdict.status, 'countedOnly');
  assert.equal(liked.verdict.publish, false);
  // Its own refusal, not only the verdict's: either alone keeps liked out.
  assert.throws(() => summaryFields('nc:w1', 'liked', { up: 10 }, NOW), { message: 'No summary is published for "How was it?".' });
});

test('publishing liked writes nothing at all', async () => {
  const store = fakeStore();
  await assert.rejects(publishSummary(store, { trailKey: 'nc:w1', fact: 'liked', counts: { up: 10 }, now: NOW }));
  assert.deepEqual(store.calls, []);
});

// MARK: The summary

test('one summary per trail and fact, named the same every time', () => {
  assert.equal(summaryRecordName('nc:w123', 'dogs'), 'factsummary.dogs.nc.w123');
  assert.equal(summaryRecordName('nc:w123', 'dogs'), summaryRecordName('nc:w123', 'dogs'));
  assert.notEqual(summaryRecordName('nc:w123', 'dogs'), summaryRecordName('nc:w123', 'surface'));
  assert.notEqual(summaryRecordName('nc:w123', 'dogs'), summaryRecordName('va:w123', 'dogs'));
  // Keys that could share a name once the colon is a dot are refused, not guessed.
  assert.throws(() => summaryRecordName('nc:a.b', 'dogs'));
  assert.throws(() => summaryRecordName('nc:a:b', 'dogs'));
  assert.throws(() => summaryRecordName('nc:a/b', 'dogs'));
  assert.throws(() => summaryRecordName('nc:w1', 'conditions'));
  assert.throws(() => summaryRecordName('', 'dogs'));
});

test('the summary holds only the trail, fact, answer, walkers and when; walkers is how many gave the answer', () => {
  const f = summaryFields('nc:w1', 'surface', { paved: 3, packedDirt: 1 }, NOW);
  assert.deepEqual(f, {
    trailKey: 'nc:w1', region: 'nc', fact: 'surface', value: 'paved', walkers: 3,
    computedAt: { value: NOW, type: 'TIMESTAMP' },
  });
  assert.equal(summaryFields('nc:w1', 'surface', { paved: 4, packedDirt: 2 }, NOW).walkers, 4, '4 of 6 states 4');
  assert.throws(() => summaryFields('nc:w1', 'surface', { paved: 2 }, NOW), /Not publishable/);
  assert.throws(() => summaryFields('nc:w1', 'surface', { paved: 2, packedDirt: 1 }, NOW), /Not publishable/, '2 of 3');
  assert.throws(() => summaryFields('nc:w1', 'stroller', { yes: 2, no: 2 }, NOW), /Not publishable/);
  assert.throws(() => summaryFields('nc:w1', 'surface', { paved: 3, packedDirt: 2 }, NOW), /Not publishable/);
});

test('no walker, token or account reaches a summary or its History entry', async () => {
  const accounts = ['_secretAlice', '_secretBob', '_secretCarol', '_secretDan'];
  const raw = accounts.map((who, i) => ({
    recordName: `report.${i}`, recordType: 'TrailFactReport',
    created: { timestamp: 1000 + i, userRecordName: who },
    fields: { trailKey: { value: 'nc:w7' }, region: { value: 'nc' }, fact: { value: 'dogs' }, value: { value: i === 3 ? 'noDogs' : 'leashRequired' } },
  }));
  const db = { async performQuery() { return { records: raw, moreComing: false }; } };
  const { records } = await pagedQuery(db, { recordType: 'TrailFactReport' });
  for (const r of records) {
    assert.equal(r.creator, undefined);
    assert.ok(/^walker-\d+$/.test(r.reporter), 'an opaque token, not the account');
  }
  assert.equal(new Set(records.map((r) => r.reporter)).size, 4);
  const [trail] = tallyWalkerReports(records).trails;
  const store = fakeStore();
  await publishSummary(store, { trailKey: trail.trailKey, fact: 'dogs', counts: countsOf(trail.facts[0]), now: NOW });
  const written = JSON.stringify(store.calls);
  for (const who of accounts) assert.ok(!written.includes(who), `${who} was written`);
  for (const r of records) assert.ok(!written.includes(r.reporter), `${r.reporter} was written`);
  const summary = store.calls.find((c) => c[0] === 'createNamed');
  assert.deepEqual(Object.keys(summary[3]).sort(), ['computedAt', 'fact', 'region', 'trailKey', 'value', 'walkers']);
  assert.equal(summary[3].walkers, 3, 'the three who said leash, not all four');
});

test('the same account gets the same token for the page\'s life, and plain() never keeps it', () => {
  assert.equal(reporterToken('_x1'), reporterToken('_x1'));
  assert.notEqual(reporterToken('_x1'), reporterToken('_x2'));
  assert.equal(reporterToken(undefined), undefined);
  const raw = { recordName: 'r', recordType: 'TrailFactReport', created: { timestamp: 1, userRecordName: '_x1' }, fields: {} };
  assert.equal(plain(raw).creator, undefined);
  assert.equal(plain(raw).reporter, undefined);
});

test('Publish writes History first, then creates or replaces the summary; a failure takes History back', async () => {
  const fresh = fakeStore();
  const out = await publishSummary(fresh, { trailKey: 'nc:w1', fact: 'dogs', counts: { leashRequired: 3 }, now: NOW });
  assert.equal(out.recordName, 'factsummary.dogs.nc.w1');
  assert.deepEqual(fresh.calls.map((c) => c[0]), ['fetch', 'create', 'createNamed']);
  assert.equal(fresh.calls[1][2].action, 'published');
  assert.equal(fresh.calls[1][2].targetType, 'trailFact');
  assert.equal(fresh.calls[2][1], 'TrailFactSummary');
  const mixed = fakeStore();
  await publishSummary(mixed, { trailKey: 'nc:w1', fact: 'dogs', counts: { leashRequired: 3, noDogs: 1 }, now: NOW });
  assert.equal(mixed.calls[1][2].reportCount, 4, 'History counts every walker; the summary states the 3 who agree');
  assert.equal(mixed.calls[2][3].walkers, 3);
  const again = fakeStore({ exists: 'factsummary.dogs.nc.w1' });
  await publishSummary(again, { trailKey: 'nc:w1', fact: 'dogs', counts: { leashRequired: 4 }, now: NOW });
  assert.deepEqual(again.calls.map((c) => c[0]), ['fetch', 'create', 'replaceNamed']);
  assert.equal(again.calls[2][2], 'factsummary.dogs.nc.w1', 'republishing replaces the same record');
  const failing = fakeStore({ failSave: true });
  await assert.rejects(publishSummary(failing, { trailKey: 'nc:w1', fact: 'dogs', counts: { leashRequired: 3 }, now: NOW }));
  assert.deepEqual(failing.calls.at(-1), ['delete', ['act1']]);
  const tooFew = fakeStore();
  await assert.rejects(publishSummary(tooFew, { trailKey: 'nc:w1', fact: 'dogs', counts: { leashRequired: 2 }, now: NOW }));
  assert.deepEqual(tooFew.calls, [], 'nothing written when the rule says no');
});

test('Un-publish writes History, then deletes the summary; a failed delete takes History back', async () => {
  const ok = fakeStore();
  await unpublishSummary(ok, { trailKey: 'nc:w1', fact: 'dogs' });
  assert.deepEqual(ok.calls.map((c) => c[0]), ['create', 'delete']);
  assert.equal(ok.calls[0][2].action, 'unpublished');
  assert.equal(ok.calls[0][2].targetType, 'trailFact', 'never a trail action: that would close nominations');
  assert.deepEqual(ok.calls[1][1], ['factsummary.dogs.nc.w1']);
  const byName = fakeStore();
  await unpublishSummary(byName, { trailKey: 'nc:w1', fact: 'dogs', recordName: 'made-by-hand' });
  assert.deepEqual(byName.calls[1][1], ['made-by-hand']);
  const failing = fakeStore({ failDeleteAt: 1 });
  await assert.rejects(unpublishSummary(failing, { trailKey: 'nc:w1', fact: 'dogs' }));
  assert.deepEqual(failing.calls.at(-1), ['delete', ['act1']]);
});

test('a published summary is current, outdated or no longer supported', () => {
  const [row] = summaryRows([{ recordName: 's', created: 1, fields: { trailKey: 'nc:w1', fact: 'dogs', value: 'noDogs', walkers: 3 } }]);
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { noDogs: 3 })), 'current');
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { noDogs: 3, leashRequired: 1 })), 'current', 'still 3 saying no dogs');
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { noDogs: 4 })), 'outdated');
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { leashRequired: 3 })), 'outdated');
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { noDogs: 2, leashRequired: 2 })), 'unsupported');
  assert.equal(summaryStanding(null, walkerVerdict('dogs', { noDogs: 3 })), null);
});

test('walker-report actions never close a community report naming the same target', () => {
  // A report is written by any iCloud user, so it can name any target, including these.
  const cases = [
    { targetRecordName: 'factsummary.dogs.nc.w1', action: 'published', targetType: 'trailFact' },
    { targetRecordName: 'factsummary.dogs.nc.w1', action: 'unpublished', targetType: 'trailFact' },
    { targetRecordName: 'TrailFactReport', action: 'expired', targetType: 'walkerReports' },
    { targetRecordName: 'TrailFactReport', action: 'erased', targetType: 'walkerReports' },
  ];
  for (const fields of cases) {
    const report = { recordName: 'r', created: 100, fields: { targetRecordName: fields.targetRecordName, targetType: 'route', reason: 'spam' } };
    assert.equal(queue(groupReports([report], [{ created: 200, fields }])).length, 1, `${fields.action} closed a report`);
  }
});

// MARK: Retention

test('the cutoff is 12 calendar months before now, in UTC', () => {
  assert.equal(retentionCutoff(NOW), Date.UTC(2025, 9, 15, 12, 0, 0));
  assert.equal(retentionCutoff(Date.UTC(2028, 1, 29)), Date.UTC(2027, 2, 1), '29 Feb rolls to 1 Mar');
  assert.equal(retentionCutoff(Date.UTC(2026, 0, 1)), Date.UTC(2025, 0, 1));
  assert.equal(retentionCutoff(Date.UTC(2028, 2, 1)), Date.UTC(2027, 2, 1), 'months, not 365 days, across a leap day');
  assert.ok(NOW - retentionCutoff(NOW) >= 365 * DAY);
  assert.throws(() => retentionCutoff(NaN));
});

test('only reports made strictly before the cutoff are expired', () => {
  const cutoff = retentionCutoff(NOW);
  const r = (created) => ({ recordName: `r${created}`, created });
  assert.deepEqual(expiredReports([r(cutoff - 1), r(cutoff), r(cutoff + 1), r(NaN)], cutoff).map((x) => x.created), [cutoff - 1]);
});

test('finding old reports asks CloudKit for ones before the cutoff, and filters again itself', async () => {
  const cutoff = retentionCutoff(NOW);
  const store = fakeStore({ found: [{ recordName: 'old', created: cutoff - 5 }, { recordName: 'new', created: cutoff + 5 }] });
  const out = await findExpiredReports(store, { now: NOW });
  assert.equal(store.calls[0][1], 'TrailFactReport');
  assert.equal(store.calls[0][2].beforeMs, cutoff);
  assert.deepEqual(out.records.map((r) => r.recordName), ['old']);
  assert.equal(out.cutoff, cutoff);
  const q = buildQuery('TrailFactReport', { beforeMs: cutoff });
  assert.deepEqual(q.filterBy, [{ systemFieldName: 'createdTimestamp', comparator: 'LESS_THAN', fieldValue: { value: cutoff, type: 'TIMESTAMP' } }]);
});

test('deleting old reports writes History with the count, then deletes only expired reports, 200 at a time', async () => {
  const cutoff = retentionCutoff(NOW);
  const old = Array.from({ length: 450 }, (_, i) => ({ recordName: `old${i}`, created: cutoff - 1 - i }));
  const fresh = { recordName: 'fresh', created: cutoff + 1 };
  const store = fakeStore();
  const out = await deleteExpiredReports(store, { records: [...old, fresh], cutoff });
  assert.deepEqual(out, { deleted: 450, error: null });
  assert.equal(store.calls[0][0], 'create');
  assert.equal(store.calls[0][2].action, 'expired');
  assert.equal(store.calls[0][2].reportCount, 450);
  const deleted = store.calls.filter((c) => c[0] === 'delete').map((c) => c[1]);
  assert.deepEqual(deleted.map((names) => names.length), [200, 200, 50]);
  assert.ok(!deleted.flat().includes('fresh'), 'a report inside the window is never deleted');
  assert.ok(!deleted.flat().some((name) => name.startsWith('factsummary.')), 'summaries are never touched');
});

test('deleting nothing writes nothing; a first failure takes History back; a later one reports progress', async () => {
  const cutoff = retentionCutoff(NOW);
  const none = fakeStore();
  assert.deepEqual(await deleteExpiredReports(none, { records: [{ recordName: 'n', created: cutoff }], cutoff }), { deleted: 0, error: null });
  assert.deepEqual(none.calls, []);
  const old = Array.from({ length: 300 }, (_, i) => ({ recordName: `old${i}`, created: cutoff - 1 }));
  const first = fakeStore({ failDeleteAt: 1 });
  await assert.rejects(deleteExpiredReports(first, { records: old, cutoff }));
  assert.deepEqual(first.calls.at(-1), ['delete', ['act1']]);
  const later = fakeStore({ failDeleteAt: 2 });
  const out = await deleteExpiredReports(later, { records: old, cutoff });
  assert.equal(out.deleted, 200);
  assert.equal(out.error.ckErrorCode, 'NETWORK_ERROR');
  assert.ok(!later.calls.some((c) => c[0] === 'delete' && c[1][0] === 'act1'), 'History stays: 200 are gone');
  const fixed = later.calls.find((c) => c[0] === 'replaceNamed');
  assert.deepEqual([fixed[1], fixed[2], fixed[3].reportCount, JSON.parse(fixed[3].snapshot).count], ['ModerationAction', 'act1', 200, 200],
    'History corrected to what was really deleted');
  // A replace keeps nothing it isn't sent: the whole action must be there.
  assert.equal(fixed[3].action, 'expired');
  assert.equal(fixed[3].targetType, 'walkerReports');
  assert.equal(fixed[3].targetRecordName, 'TrailFactReport');
  assert.equal(JSON.parse(fixed[3].snapshot).cutoff, cutoff);
  assert.equal(JSON.parse(fixed[3].snapshot).planned, 300);
  assert.equal(fixed[3].note, 'Stopped part-way: 200 of 300 deleted.');
  await assert.rejects(deleteExpiredReports(fakeStore(), { records: old }), /No cutoff/);
});

// MARK: Deleting one walker's reports on request

const ID = '_0123456789abcdef0123456789abcdef';

test('a walker\'s identifier is their user record name; anything else is refused', () => {
  assert.equal(walkerId(`  ${ID}\n`), ID);
  assert.equal(walkerId('__defaultOwner__'), null);
  assert.equal(walkerId('0123456789abcdef0123456789abcdef'), null, 'no leading underscore');
  assert.equal(walkerId('_short'), null);
  assert.equal(walkerId(`${ID} OR 1=1`), null);
  assert.equal(walkerId(undefined), null);
});

test('the creator query asks CloudKit for one account\'s records', () => {
  const q = buildQuery('TrailFactReport', { createdBy: ID });
  assert.deepEqual(q.filterBy, [{ systemFieldName: 'createdUserRecordName', comparator: 'EQUALS',
    fieldValue: { value: { recordName: ID }, type: 'REFERENCE' } }]);
});

test('records from anyone else never come back, even if CloudKit ignores the filter, and the account stays in ck.js', async () => {
  const raw = (name, who) => ({ recordName: name, recordType: 'TrailFactReport', created: { timestamp: 1, userRecordName: who },
    fields: { trailKey: { value: 'nc:w1' }, fact: { value: 'dogs' }, value: { value: 'noDogs' } } });
  const db = { async performQuery() { return { records: [raw('mine', ID), raw('theirs', '_someoneElse0000000'), raw('anon', undefined)], moreComing: false }; } };
  const { records } = await pagedQuery(db, buildQuery('TrailFactReport', { createdBy: ID }), { onlyCreator: ID });
  assert.deepEqual(records.map((r) => r.recordName), ['mine']);
  assert.equal(records[0].creator, undefined);
  assert.ok(!JSON.stringify(records).includes(ID));
  const blank = { async performQuery() { return { records: [raw('blank', '')], moreComing: false }; } };
  const none = await pagedQuery(blank, buildQuery('TrailFactReport', { createdBy: '' }), { onlyCreator: '' });
  assert.equal(none.records.length, 0, 'an empty account matches nothing, not even a record with an empty creator');
});

test('finding a walker\'s reports refuses a bad identifier before asking CloudKit', async () => {
  const bad = fakeStore();
  await assert.rejects(findReportsBy(bad, { identifier: 'bob@example.com' }), /isn't a Wockett identifier/);
  assert.deepEqual(bad.calls, []);
  const store = fakeStore({ found: [{ recordName: 'r1', recordType: 'TrailFactReport', created: 1 }] });
  const out = await findReportsBy(store, { identifier: ` ${ID} ` });
  assert.deepEqual(store.calls[0].slice(0, 3), ['queryByCreator', 'TrailFactReport', ID]);
  assert.equal(out.records.length, 1);
});

test('deleting a walker\'s reports writes History with the count only, then deletes them', async () => {
  const records = Array.from({ length: 250 }, (_, i) => ({ recordName: `r${i}`, recordType: 'TrailFactReport', created: i }));
  const store = fakeStore();
  // The page has the account in hand; it must not reach History.
  const out = await deleteReportsBy(store, { account: ID, records: [...records, { recordName: 'summary', recordType: 'TrailFactSummary' }] });
  assert.deepEqual(out, { deleted: 250, error: null });
  assert.equal(store.calls[0][0], 'create');
  assert.equal(store.calls[0][2].action, 'erased');
  assert.equal(store.calls[0][2].reportCount, 250);
  assert.ok(!JSON.stringify(store.calls).includes(ID), 'no identifier in History');
  const deleted = store.calls.filter((c) => c[0] === 'delete').map((c) => c[1]);
  assert.deepEqual(deleted.map((d) => d.length), [200, 50]);
  assert.ok(!deleted.flat().includes('summary'), 'only reports are deleted');
  const empty = fakeStore();
  assert.deepEqual(await deleteReportsBy(empty, { records: [] }), { deleted: 0, error: null });
  assert.deepEqual(empty.calls, []);
  const failing = fakeStore({ failDeleteAt: 1 });
  await assert.rejects(deleteReportsBy(failing, { records }));
  assert.deepEqual(failing.calls.at(-1), ['delete', ['act1']]);
});

test('a batch that fails part-way keeps History, with the number really deleted', async () => {
  const cutoff = retentionCutoff(NOW);
  const old = Array.from({ length: 200 }, (_, i) => ({ recordName: `old${i}`, recordType: 'TrailFactReport', created: cutoff - 1 }));
  const store = fakeStore({ failDeleteAt: 1, partly: 150 });
  const out = await deleteReportsBy(store, { records: old });
  assert.equal(out.deleted, 150);
  assert.ok(!store.calls.some((c) => c[0] === 'delete' && c[1][0] === 'act1'), '150 are gone: History must not be taken back');
  const fixed = store.calls.find((c) => c[0] === 'replaceNamed')[3];
  assert.deepEqual([fixed.reportCount, fixed.action, fixed.targetType], [150, 'erased', 'walkerReports']);
});

test('ck.js counts what a failed delete batch did delete; records already gone count as deleted', async () => {
  const names = Array.from({ length: 250 }, (_, i) => `r${i}`);
  let call = 0;
  const db = { async deleteRecords(chunk) {
    call += 1;
    if (call === 1) return { records: chunk.map((recordName) => ({ recordName })), errors: [{ ckErrorCode: 'NOT_FOUND', recordName: 'r0' }] };
    return { records: [], errors: [{ ckErrorCode: 'THROTTLED', recordName: 'r200' }, { ckErrorCode: 'THROTTLED', recordName: 'r201' }] };
  } };
  await assert.rejects(deleteAll(db, names), (error) => error.ckErrorCode === 'THROTTLED' && error.deleted === 248);
  // An error naming no record may be about the whole call: that call deleted nothing, as far as anyone can tell.
  const whole = { async deleteRecords() { return { records: [], errors: [{ ckErrorCode: 'SERVICE_UNAVAILABLE' }] }; } };
  await assert.rejects(deleteAll(whole, names.slice(0, 200)), (error) => error.deleted === 0);
  call = 0;
  const fine = { async deleteRecords() { return { records: [], errors: [{ ckErrorCode: 'UNKNOWN_ITEM' }] }; } };
  assert.equal(await deleteAll(fine, names), 250);
});

test('Activity counts walker reports', () => {
  assert.ok(ACTIVITY_KINDS.some((k) => k.recordType === 'TrailFactReport'));
});

// MARK: Schema

/** One record type's block from cloudkit/schema.ckdb. */
function schemaBlock(type) {
  const schema = readFileSync(new URL('../../cloudkit/schema.ckdb', import.meta.url), 'utf8');
  const match = schema.match(new RegExp(`RECORD TYPE ${type} \\(([\\s\\S]*?)\\n    \\);`));
  assert.ok(match, `${type} is in the schema`);
  return match[1];
}

test('walker reports are readable only by a Moderator; any signed-in user may create one', () => {
  const block = schemaBlock('TrailFactReport');
  const grants = block.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('GRANT'));
  assert.deepEqual(grants, ['GRANT READ, WRITE TO Moderator,', 'GRANT CREATE TO "_icloud"']);
  for (const field of ['fact', 'region', 'value']) assert.match(block, new RegExp(`\\n\\s+${field}\\s+STRING,`));
  assert.match(block, /trailKey\s+STRING QUERYABLE,/);
  assert.match(block, /"___createdBy"\s+REFERENCE QUERYABLE,/, 'a walker\'s reports can be found to delete them');
});

test('summaries are readable by everyone and written only by a Moderator', () => {
  const block = schemaBlock('TrailFactSummary');
  const grants = block.split('\n').map((l) => l.trim()).filter((l) => l.startsWith('GRANT'));
  assert.deepEqual(grants, ['GRANT READ, CREATE, WRITE TO Moderator,', 'GRANT READ TO "_world"']);
  assert.match(block, /walkers\s+INT64,/);
  assert.match(block, /computedAt\s+TIMESTAMP,/);
  assert.match(block, /trailKey\s+STRING QUERYABLE,/);
});

// MARK: Test-auditor run 1 (2026-10-15)

test('a report whose fact is a prototype name is ignored, not a crash', () => {
  for (const fact of ['toString', 'hasOwnProperty', '__proto__', 'constructor']) {
    const out = tallyWalkerReports([{ recordName: 'x', created: 1, reporter: 'walker-1', fields: { trailKey: 'nc:w1', fact, value: 'yes' } }]);
    assert.equal(out.ignored, 1, fact);
  }
  assert.throws(() => summaryRecordName('nc:w1', 'toString'));
});

test('one walker answering several facts on one trail keeps every answer', async () => {
  const raw = (n, t, fact, value) => ({ recordName: n, recordType: 'TrailFactReport', created: { timestamp: t, userRecordName: '_pW' },
    fields: { trailKey: { value: 'nc:w9' }, fact: { value: fact }, value: { value } } });
  const db = { async performQuery() { return { records: [raw('a', 2, 'dogs', 'noDogs'), raw('b', 1, 'stroller', 'yes')], moreComing: false }; } };
  const { records } = await pagedQuery(db, { recordType: 'TrailFactReport' });
  assert.deepEqual(tallyWalkerReports(records).trails[0].facts.map((f) => f.fact), ['dogs', 'stroller']);
});

test('only walker reports get a reporter token: a content report\'s filer is never linked to a walker', async () => {
  const db = { async performQuery() { return { records: [{ recordName: 'cr', recordType: 'CommunityReport', created: { timestamp: 1, userRecordName: '_pW' }, fields: {} }], moreComing: false }; } };
  const { records } = await pagedQuery(db, { recordType: 'CommunityReport' });
  assert.equal(records[0].reporter, undefined);
});

test('a failed take-back never hides the original error', async () => {
  const store = { async fetch() { return new Map(); }, async create() { return { recordName: 'act1' }; },
    async createNamed() { throw { ckErrorCode: 'ACCESS_DENIED' }; },
    async delete(n) { throw { ckErrorCode: n[0] === 'act1' ? 'NETWORK_ERROR' : 'ACCESS_DENIED' }; } };
  await assert.rejects(publishSummary(store, { trailKey: 'nc:w1', fact: 'dogs', counts: { noDogs: 3 }, now: 1 }), { ckErrorCode: 'ACCESS_DENIED' });
  await assert.rejects(unpublishSummary(store, { trailKey: 'nc:w1', fact: 'dogs' }), { ckErrorCode: 'ACCESS_DENIED' });
  await assert.rejects(deleteReportsBy(store, { records: [{ recordName: 'r', recordType: 'TrailFactReport' }] }), { ckErrorCode: 'ACCESS_DENIED' });
});

test('connect() sends the age and creator filters, and re-checks the creator', async () => {
  let sent;
  const recs = [{ recordName: 'theirs', recordType: 'TrailFactReport', created: { timestamp: 1, userRecordName: '_other' }, fields: {} }];
  const CloudKit = { configure() {}, getDefaultContainer() { return { publicCloudDatabase: { async performQuery(q) { sent = q; return { records: recs, moreComing: false }; } } }; } };
  const store = connect({ CloudKit });
  await store.query('TrailFactReport', { beforeMs: 123 });
  assert.equal(sent.filterBy[0].comparator, 'LESS_THAN');
  assert.equal(sent.filterBy[0].fieldValue.value, 123);
  const mine = await store.queryByCreator('TrailFactReport', '_me');
  assert.equal(sent.filterBy[0].systemFieldName, 'createdUserRecordName');
  assert.deepEqual(sent.filterBy[0].fieldValue.value, { recordName: '_me' });
  assert.equal(mine.records.length, 0, 'someone else\'s record is dropped even if CloudKit ignores the filter');
});

test('a key with a second colon anywhere is refused', () => {
  assert.throws(() => summaryRecordName('nc:ab:cd', 'dogs'));
  assert.throws(() => summaryRecordName('xnc:w1', 'dogs'));
});

test('a summary with an unknown value is unsupported', () => {
  const [row] = summaryRows([{ recordName: 's', created: 1, fields: { trailKey: 'nc:w1', fact: 'dogs', value: 'bogus', walkers: 3 } }]);
  assert.equal(row.known, false);
  assert.equal(summaryStanding(row, walkerVerdict('dogs', { noDogs: 3 })), 'unsupported');
});

/** A type's non-grant lines from the schema, spaces collapsed. */
function schemaLines(type) {
  return schemaBlock(type).split('\n').map((l) => l.trim().replace(/\s+/g, ' ')).filter((l) => l && !l.startsWith('GRANT'));
}

test('a walker report holds exactly these fields: no free text, no location, with the indexes the queries need', () => {
  assert.deepEqual(schemaLines('TrailFactReport'), [
    '"___createTime" TIMESTAMP QUERYABLE SORTABLE,', '"___createdBy" REFERENCE QUERYABLE,', '"___etag" STRING,',
    '"___modTime" TIMESTAMP,', '"___modifiedBy" REFERENCE,', '"___recordID" REFERENCE QUERYABLE,',
    'fact STRING,', 'region STRING,', 'trailKey STRING QUERYABLE,', 'value STRING,',
  ]);
});

test('a summary holds exactly these fields: nothing about who answered', () => {
  assert.deepEqual(schemaLines('TrailFactSummary'), [
    '"___createTime" TIMESTAMP SORTABLE,', '"___createdBy" REFERENCE,', '"___etag" STRING,',
    '"___modTime" TIMESTAMP,', '"___modifiedBy" REFERENCE,', '"___recordID" REFERENCE QUERYABLE,',
    'computedAt TIMESTAMP,', 'fact STRING,', 'region STRING,', 'trailKey STRING QUERYABLE,', 'value STRING,', 'walkers INT64,',
  ]);
});

test('a trail counts its walkers\' answers, newest trail first', () => {
  const r = (who, trailKey, created) => ({ recordName: `${who}${trailKey}`, created, reporter: who, fields: { trailKey, fact: 'dogs', value: 'noDogs' } });
  const { trails } = tallyWalkerReports([r('walker-1', 'nc:old', 1), r('walker-2', 'nc:old', 5), r('walker-1', 'nc:new', 3)]);
  assert.deepEqual(trails.map((t) => [t.trailKey, t.reports, t.latestAt]), [['nc:old', 2, 5], ['nc:new', 1, 3]]);
});
