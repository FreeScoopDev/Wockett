// Suspensions on the staff dashboard (docs/staff/logic.js, actions.js, ck.js).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  suspensionUntil, suspensionRecordName, suspensionFields, ownedBy, shortAccount, suspensionRows, DAY, actionFields,
} from '../../docs/staff/logic.js';
import { suspendAccount, liftSuspension, itemsOf } from '../../docs/staff/actions.js';
import { plain, upsertRecord } from '../../docs/staff/ck.js';

const NOW = 1_800_000_000_000;

/** A store that records calls in order. `items` answers authorName queries by record type. */
function fakeStore({ items = {}, failUpsert = false, failDeletes = 0 } = {}) {
  const calls = [];
  let deletesToFail = failDeletes;
  return {
    calls,
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: `act${calls.length}`, recordType, created: 1, fields }; },
    async upsert(recordType, recordName, fields) {
      calls.push(['upsert', recordType, recordName, fields]);
      if (failUpsert) throw { ckErrorCode: 'ACCESS_DENIED' };
    },
    async delete(names) {
      calls.push(['delete', names]);
      if (deletesToFail > 0) { deletesToFail -= 1; throw { ckErrorCode: 'ACCESS_DENIED' }; }
    },
    async query(recordType, opts) { calls.push(['query', recordType, opts.equals]); return { records: items[recordType] ?? [], more: false }; },
  };
}

test('a suspension ends 7 or 30 days on, or never', () => {
  assert.equal(suspensionUntil('7d', NOW), NOW + 7 * DAY);
  assert.equal(suspensionUntil('30d', NOW), NOW + 30 * DAY);
  assert.equal(suspensionUntil('permanent', NOW), null);
  assert.throws(() => suspensionUntil('toString', NOW));
});

test('one record per account, holding only the account and the end', () => {
  assert.equal(suspensionRecordName('_abc'), 'suspension._abc');
  assert.throws(() => suspensionRecordName(''));
  assert.throws(() => suspensionRecordName('has space'));
  assert.deepEqual(suspensionFields('_abc', 5), { accountRecordName: '_abc', until: 5 });
  assert.deepEqual(suspensionFields('_abc', null), { accountRecordName: '_abc' });
});

test('Suspend writes the action first, then the Suspension', async () => {
  const store = fakeStore();
  const out = await suspendAccount(store, { account: '_bad', authorName: 'LoudCrow12', length: '7d', reason: 'spam', now: NOW });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'upsert']);
  const [, type, fields] = store.calls[0];
  assert.equal(type, 'ModerationAction');
  assert.equal(fields.action, 'suspended');
  assert.equal(fields.targetType, 'account');
  assert.equal(fields.targetRecordName, '_bad');
  assert.deepEqual(JSON.parse(fields.snapshot), { account: '_bad', authorName: 'LoudCrow12', until: NOW + 7 * DAY });
  assert.deepEqual(store.calls[1].slice(1), ['Suspension', 'suspension._bad', { accountRecordName: '_bad', until: NOW + 7 * DAY }]);
  assert.equal(out.until, NOW + 7 * DAY);
});

test('if the Suspension can\'t be saved, the action is taken back', async () => {
  const store = fakeStore({ failUpsert: true });
  await assert.rejects(suspendAccount(store, { account: '_bad', length: 'permanent', reason: 'spam', now: NOW }), { ckErrorCode: 'ACCESS_DENIED' });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'upsert', 'delete']);
  assert.deepEqual(store.calls[2][1], ['act1']);
});

test('"also remove" removes only what the suspended account itself created', async () => {
  const mine = { recordType: 'WocketAchievement', recordName: 'p1', created: 1, creator: '_bad', fields: { authorName: 'LoudCrow12' } };
  const namesake = { recordType: 'WocketAchievement', recordName: 'p2', created: 1, creator: '_other', fields: { authorName: 'LoudCrow12' } };
  const store = fakeStore({ items: { WocketAchievement: [mine, namesake] } });
  const out = await suspendAccount(store, { account: '_bad', authorName: 'LoudCrow12', length: '30d', reason: 'spam', now: NOW, removeItems: true });
  assert.equal(out.removed, 1);
  const deleted = store.calls.filter((c) => c[0] === 'delete').flatMap((c) => c[1]);
  assert.ok(deleted.includes('p1'));
  assert.ok(!deleted.includes('p2'), 'another account using the same name keeps its post');
  assert.deepEqual(store.calls.filter((c) => c[0] === 'query' && c[2]?.[0] === 'authorName').map((c) => c[1]),
    ['WocketAchievement', 'SharedRoute', 'Challenge']);
  // Every removal still snapshots first.
  const removals = store.calls.filter((c) => c[0] === 'create' && c[2].action === 'removed');
  assert.equal(removals.length, 1);
});

test('without "also remove", nothing else is touched', async () => {
  const store = fakeStore({ items: { WocketAchievement: [{ recordName: 'p1', creator: '_bad', fields: {} }] } });
  await suspendAccount(store, { account: '_bad', authorName: 'LoudCrow12', length: '7d', reason: 'spam', now: NOW });
  assert.equal(store.calls.filter((c) => c[0] === 'query' || c[0] === 'delete').length, 0);
});

test('their items are only the account\'s own', async () => {
  const store = fakeStore({ items: { SharedRoute: [{ recordName: 'r1', creator: '_bad' }, { recordName: 'r2', creator: '_x' }] } });
  const found = await itemsOf(store, { account: '_bad', authorName: 'LoudCrow12' });
  assert.deepEqual(found.route.map((r) => r.recordName), ['r1']);
  assert.deepEqual(found.post, []);
  assert.deepEqual(ownedBy([{ creator: undefined }], undefined), [], 'no account matches nothing');
});

test('Lift writes "lifted", then deletes the Suspension; a failed delete takes the action back', async () => {
  const ok = fakeStore();
  await liftSuspension(ok, { account: '_bad', note: 'appealed' });
  assert.deepEqual(ok.calls.map((c) => c[0]), ['create', 'delete']);
  assert.equal(ok.calls[0][2].action, 'lifted');
  assert.deepEqual(ok.calls[1][1], ['suspension._bad']);
  const failing = fakeStore({ failDeletes: 1 });
  await assert.rejects(liftSuspension(failing, { account: '_bad' }));
  assert.deepEqual(failing.calls.map((c) => c[0]), ['create', 'delete', 'delete']);
  assert.deepEqual(failing.calls[2][1], ['act1']);
});

test('the new actions are allowed, made-up ones are not', () => {
  assert.equal(actionFields({ target: '_a', type: 'account', action: 'suspended' }).action, 'suspended');
  assert.equal(actionFields({ target: '_a', type: 'account', action: 'lifted' }).action, 'lifted');
  assert.throws(() => actionFields({ target: '_a', type: 'account', action: 'banned' }));
});

test('the Suspensions list names each account from its latest suspension, and says which have ended', () => {
  const susp = (account, until, created) => ({ recordName: `suspension.${account}`, created, fields: { accountRecordName: account, ...(until === null ? {} : { until }) } });
  const act = (account, name, created) => ({ created, fields: { action: 'suspended', targetRecordName: account, snapshot: JSON.stringify({ authorName: name }) } });
  const rows = suspensionRows(
    [susp('_a', NOW - 1, 1), susp('_b', null, 2), susp('_c', NOW + DAY, 3)],
    [act('_a', 'Old', 1), act('_a', 'New', 5), { created: 9, fields: { action: 'suspended', targetRecordName: '_c', snapshot: 'not json' } }],
    NOW,
  );
  assert.deepEqual(rows.map((r) => [r.account, r.ended, r.authorName]), [['_c', false, ''], ['_b', false, ''], ['_a', true, 'New']]);
  assert.equal(rows.find((r) => r.account === '_b').until, null);
});

test('an account shows shortened', () => {
  assert.equal(shortAccount('_87331bb15937659fc71ad69a97566e5a'), '_87331bb1…');
  assert.equal(shortAccount('_short'), '_short');
});

test('the creator is kept for community items, never for reports or actions', () => {
  const raw = (recordType) => ({ recordName: 'x', recordType, created: { timestamp: 1, userRecordName: '_who' }, fields: {} });
  assert.equal(plain(raw('WocketAchievement')).creator, '_who');
  assert.equal(plain(raw('SharedRoute')).creator, '_who');
  assert.equal(plain(raw('CommunityReport')).creator, undefined);
  assert.equal(plain(raw('ModerationAction')).creator, undefined);
  assert.equal(plain(raw('Suspension')).creator, undefined);
});

test('suspending again replaces the record, using its change tag', async () => {
  const saved = [];
  const db = {
    async fetchRecords(names) { return { records: [{ recordName: names[0], recordChangeTag: 'tag1', fields: {} }] }; },
    async saveRecords(records) { saved.push(...records); return { records: [{ ...records[0], created: { timestamp: 2 } }] }; },
  };
  await upsertRecord(db, 'Suspension', 'suspension._a', { accountRecordName: '_a' });
  assert.equal(saved[0].recordChangeTag, 'tag1');
  const fresh = { async fetchRecords() { return { records: [{ recordName: 'suspension._a', serverErrorCode: 'NOT_FOUND' }] }; }, saveRecords: db.saveRecords };
  saved.length = 0;
  await upsertRecord(fresh, 'Suspension', 'suspension._a', { accountRecordName: '_a' });
  assert.equal(saved[0].recordChangeTag, undefined, 'a new record has no tag');
  assert.deepEqual(saved[0].fields, { accountRecordName: { value: '_a' } });
});
