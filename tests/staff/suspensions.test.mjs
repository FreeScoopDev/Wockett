// Suspensions on the staff dashboard (docs/staff/logic.js, actions.js, ck.js).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  suspensionUntil, suspensionRecordName, suspensionFields, ownedBy, shortAccount, suspensionRows, DAY, actionFields,
  canSuspend,
} from '../../docs/staff/logic.js';
import { suspendAccount, liftSuspension, itemsOf } from '../../docs/staff/actions.js';
import { plain, ckFields } from '../../docs/staff/ck.js';

const NOW = 1_800_000_000_000;

/** A store that records calls in order. `items` answers authorName queries by record type. */
function fakeStore({ items = {}, failCreateNamed = 0, failDeletes = 0, existing = null, failDeleteOf = null } = {}) {
  const calls = [];
  let deletesToFail = failDeletes;
  let namedToFail = failCreateNamed;
  return {
    calls,
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: `act${calls.length}`, recordType, created: 1, fields }; },
    async fetch(names) {
      calls.push(['fetch', names]);
      return new Map(existing ? [[existing.recordName, existing]] : []);
    },
    async createNamed(recordType, recordName, fields) {
      calls.push(['createNamed', recordType, recordName, fields]);
      if (namedToFail > 0) { namedToFail -= 1; throw { ckErrorCode: 'ACCESS_DENIED' }; }
    },
    async delete(names) {
      calls.push(['delete', names]);
      if (failDeleteOf && names.includes(failDeleteOf)) throw { ckErrorCode: 'THROTTLED' };
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
  assert.deepEqual(suspensionFields('_abc', 5), { accountRecordName: '_abc', until: { value: 5, type: 'TIMESTAMP' } });
  assert.deepEqual(suspensionFields('_abc', null), { accountRecordName: '_abc' });
});

test('Suspend writes the action first, then the Suspension', async () => {
  const store = fakeStore();
  const out = await suspendAccount(store, { account: '_bad', authorName: 'LoudCrow12', length: '7d', reason: 'spam', now: NOW });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'fetch', 'createNamed']);
  const [, type, fields] = store.calls[0];
  assert.equal(type, 'ModerationAction');
  assert.equal(fields.action, 'suspended');
  assert.equal(fields.targetType, 'account');
  assert.equal(fields.targetRecordName, '_bad');
  assert.deepEqual(JSON.parse(fields.snapshot), { account: '_bad', authorName: 'LoudCrow12', length: '7d', until: NOW + 7 * DAY });
  assert.deepEqual(store.calls[2].slice(1), ['Suspension', 'suspension._bad',
    { accountRecordName: '_bad', until: { value: NOW + 7 * DAY, type: 'TIMESTAMP' } }]);
  assert.equal(out.until, NOW + 7 * DAY);
});

test('if the Suspension can\'t be saved, the action is taken back', async () => {
  const store = fakeStore({ failCreateNamed: 1 });
  await assert.rejects(suspendAccount(store, { account: '_bad', length: 'permanent', reason: 'spam', now: NOW }), { ckErrorCode: 'ACCESS_DENIED' });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'fetch', 'createNamed', 'delete']);
  assert.deepEqual(store.calls[3][1], ['act1']);
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
  // Newest suspension first: _c's (9), _a's re-suspension (5), then _b (2).
  assert.deepEqual(rows.map((r) => [r.account, r.ended, r.authorName]), [['_c', false, ''], ['_a', true, 'New'], ['_b', false, '']]);
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

test('going permanent replaces the record, so no old end date survives', async () => {
  const existing = { recordName: 'suspension._bad', recordType: 'Suspension', created: 1, fields: { accountRecordName: '_bad', until: NOW + DAY } };
  const store = fakeStore({ existing });
  await suspendAccount(store, { account: '_bad', length: 'permanent', reason: 'spam', now: NOW });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'fetch', 'delete', 'createNamed']);
  assert.deepEqual(store.calls[2][1], ['suspension._bad']);
  assert.deepEqual(store.calls[3][3], { accountRecordName: '_bad' }, 'no until: permanent');
});

test('if the new suspension can\'t be made, the old one is put back and the action taken back', async () => {
  const existing = { recordName: 'suspension._bad', recordType: 'Suspension', created: 1, fields: { accountRecordName: '_bad', until: NOW + DAY } };
  const store = fakeStore({ existing, failCreateNamed: 1 });
  await assert.rejects(suspendAccount(store, { account: '_bad', length: '30d', reason: 'spam', now: NOW }));
  const named = store.calls.filter((c) => c[0] === 'createNamed');
  assert.equal(named.length, 2);
  assert.deepEqual(named[1][3], { accountRecordName: '_bad', until: { value: NOW + DAY, type: 'TIMESTAMP' } }, 'the old end restored');
  assert.deepEqual(store.calls.at(-1), ['delete', ['act1']]);
});

test('your own account, or CloudKit\'s own-records placeholder, can\'t be suspended', async () => {
  assert.ok(!canSuspend('_me', '_me'));
  assert.ok(!canSuspend('__defaultOwner__', '_me'));
  assert.ok(canSuspend('_bad', '_me'));
  for (const account of ['_me', '__defaultOwner__']) {
    const store = fakeStore();
    await assert.rejects(suspendAccount(store, { account, length: '7d', reason: 'spam', now: NOW, moderator: '_me' }));
    assert.equal(store.calls.length, 0, 'refused before anything is written');
  }
});

test('one item failing doesn\'t stop the rest, and is counted', async () => {
  const post = (n) => ({ recordType: 'WocketAchievement', recordName: `p${n}`, created: 1, creator: '_bad', fields: {} });
  const store = fakeStore({ items: { WocketAchievement: [post(1), post(2), post(3)] }, failDeleteOf: 'p2' });
  const out = await suspendAccount(store, { account: '_bad', authorName: 'LoudCrow12', length: '7d', reason: 'spam', now: NOW, removeItems: true });
  assert.equal(out.removed, 2);
  assert.equal(out.failed, 1);
  assert.deepEqual(out.firstError, { ckErrorCode: 'THROTTLED' });
});

test('typed fields are sent as they are; plain values are wrapped', () => {
  assert.deepEqual(ckFields({ a: 'x', until: { value: 5, type: 'TIMESTAMP' } }),
    { a: { value: 'x' }, until: { value: 5, type: 'TIMESTAMP' } });
});

test('the Suspensions list dates a re-suspended account by its latest suspension', () => {
  const rows = suspensionRows(
    [{ recordName: 'suspension._a', created: 1, fields: { accountRecordName: '_a' } },
     { recordName: 'suspension._b', created: 50, fields: { accountRecordName: '_b' } }],
    [{ created: 100, fields: { action: 'suspended', targetRecordName: '_a', snapshot: '{}' } }],
    NOW,
  );
  assert.deepEqual(rows.map((r) => [r.account, r.created]), [['_a', 100], ['_b', 50]]);
});
