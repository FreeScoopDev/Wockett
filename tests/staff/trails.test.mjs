// Trail nominations and featured trails on the staff dashboard.
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  groupNominations, nominationQueue, featureUntil, featuredRecordName, featuredFields, mapsLink, featuredRows,
  BLURB_LIMIT, DAY, ACTIVITY_KINDS,
} from '../../docs/staff/logic.js';
import { featureTrail, unfeatureTrail, dismissNominations } from '../../docs/staff/actions.js';
import { plain } from '../../docs/staff/ck.js';

const NOW = 1_800_000_000_000;
const trail = { trailKey: 'nc:w1', trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400 };
const nom = (key, created, fields = {}) => ({
  recordName: `nomination.${key}.${created}`, recordType: 'TrailNomination', created,
  fields: { trailKey: key, trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400, ...fields },
});
const act = (key, created, action = 'dismissed') => ({ created, fields: { targetRecordName: key, action } });

function fakeStore({ exists = false, failSave = false, failDelete = false } = {}) {
  const calls = [];
  return {
    calls,
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: 'act1', recordType, created: 1, fields }; },
    async fetch(names) { calls.push(['fetch', names]); return new Map(exists ? [[names[0], {}]] : []); },
    async createNamed(recordType, recordName, fields) { calls.push(['createNamed', recordType, recordName, fields]); if (failSave) throw { ckErrorCode: 'ACCESS_DENIED' }; },
    async replaceNamed(recordType, recordName, fields) { calls.push(['replaceNamed', recordType, recordName, fields]); if (failSave) throw { ckErrorCode: 'ACCESS_DENIED' }; },
    async delete(names) {
      calls.push(['delete', names]);
      if (failDelete && names[0] !== 'act1') throw { ckErrorCode: 'NETWORK_ERROR' };
    },
  };
}

test('nominations group by trail, with notes since the last action', () => {
  const groups = groupNominations([
    nom('nc:w1', 100, { note: 'old' }), nom('nc:w1', 300, { note: ' shady ' }), nom('nc:w1', 400), nom('nc:w2', 200, { trailName: 'Creek Path' }),
  ], [act('nc:w1', 200)]);
  const a = groups.find((g) => g.trailKey === 'nc:w1');
  assert.equal(a.count, 3);
  assert.equal(a.newCount, 2);
  assert.deepEqual(a.notes.map((n) => n.note), ['shady']);
  assert.equal(a.open, true);
  assert.equal(groups.find((g) => g.trailKey === 'nc:w2').trail.trailName, 'Creek Path');
});

test('a trail acted on stays closed until nominated again', () => {
  const groups = groupNominations([nom('nc:w1', 100)], [act('nc:w1', 200, 'featured')]);
  assert.equal(groups[0].open, false);
  assert.equal(nominationQueue(groups).length, 0);
});

test('the queue ranks by nominations since the last action, or by newest', () => {
  const groups = groupNominations([
    nom('busy', 10), nom('busy', 11), nom('busy', 12), nom('busy', 500), nom('new', 300), nom('new', 301),
  ], [act('busy', 100)]);
  assert.deepEqual(nominationQueue(groups, 'most').map((g) => g.trailKey), ['new', 'busy']);
  assert.deepEqual(nominationQueue(groups, 'newest').map((g) => g.trailKey), ['busy', 'new']);
  assert.deepEqual(nominationQueue(groups, 'most', new Map([['new', 400]])).map((g) => g.trailKey), ['busy']);
  assert.deepEqual(nominationQueue(groups, 'most', new Map([['new', 250]])).map((g) => g.trailKey), ['new', 'busy'],
    'nominated again after it was acted on: back in the queue');
});

test('a feature lasts 30 or 90 days, or until unfeatured', () => {
  assert.equal(featureUntil('30d', NOW), NOW + 30 * DAY);
  assert.equal(featureUntil('90d', NOW), NOW + 90 * DAY);
  assert.equal(featureUntil('open', NOW), null);
  assert.throws(() => featureUntil('constructor', NOW));
});

test('one featured record per trail, named from its key', () => {
  assert.equal(featuredRecordName('nc:w1'), 'featured.nc.w1');
  assert.throws(() => featuredRecordName(''));
  assert.throws(() => featuredRecordName('has space'));
});

test('the featured record holds the trail, the note (capped, required) and a typed end', () => {
  const f = featuredFields(trail, '  Shady all afternoon  ', NOW);
  assert.equal(f.blurb, 'Shady all afternoon');
  assert.deepEqual(f.until, { value: NOW, type: 'TIMESTAMP' });
  assert.equal(f.trailKey, 'nc:w1');
  assert.equal(f.latitude, 35.78);
  assert.ok(!('until' in featuredFields(trail, 'x', null)));
  assert.equal(featuredFields(trail, 'y'.repeat(300), null).blurb.length, BLURB_LIMIT);
  assert.throws(() => featuredFields(trail, '   ', null));
});

test('Feature writes the action first, then creates or replaces the record; a failure takes the action back', async () => {
  const fresh = fakeStore();
  await featureTrail(fresh, { trail, blurb: 'Shady', length: '30d', now: NOW });
  assert.deepEqual(fresh.calls.map((c) => c[0]), ['create', 'fetch', 'createNamed']);
  assert.equal(fresh.calls[0][2].action, 'featured');
  assert.equal(fresh.calls[0][2].targetType, 'trail');
  assert.equal(fresh.calls[0][2].targetRecordName, 'nc:w1');
  const again = fakeStore({ exists: true });
  await featureTrail(again, { trail, blurb: 'Shadier', length: 'open', now: NOW });
  assert.deepEqual(again.calls.map((c) => c[0]), ['create', 'fetch', 'replaceNamed']);
  assert.ok(!('until' in again.calls[2][3]), 'open-ended drops the old end');
  const failing = fakeStore({ failSave: true });
  await assert.rejects(featureTrail(failing, { trail, blurb: 'x', length: '30d', now: NOW }));
  assert.deepEqual(failing.calls.at(-1), ['delete', ['act1']]);
});

test('Unfeature writes the action, then deletes the record; a failed delete takes the action back', async () => {
  const ok = fakeStore();
  await unfeatureTrail(ok, { trail });
  assert.deepEqual(ok.calls.map((c) => c[0]), ['create', 'delete']);
  assert.deepEqual(ok.calls[1][1], ['featured.nc.w1']);
  const failing = fakeStore({ failDelete: true });
  await assert.rejects(unfeatureTrail(failing, { trail }));
  assert.deepEqual(failing.calls.at(-1), ['delete', ['act1']]);
});

test('Dismiss writes a dismissed action and nothing else', async () => {
  const store = fakeStore();
  await dismissNominations(store, { trail, count: 3 });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create']);
  assert.equal(store.calls[0][2].action, 'dismissed');
  assert.equal(store.calls[0][2].reportCount, 3);
});

test('the Maps link is built only from numbers and the encoded name', () => {
  assert.equal(mapsLink(35.78, -78.64, 'Lake & "Loop"'), 'https://maps.apple.com/?ll=35.78000,-78.64000&q=Lake%20%26%20%22Loop%22');
  assert.equal(mapsLink('javascript:alert(1)', 1, 'x'), null);
  assert.equal(mapsLink(NaN, 1, 'x'), null);
  assert.equal(mapsLink(91, 1, 'x'), null);
});

test('the Featured tab lists newest first and marks ended ones', () => {
  const rec = (key, created, until) => ({ recordName: `featured.${key}`, created, fields: { trailKey: key, trailName: key, blurb: 'b', ...(until === undefined ? {} : { until }) } });
  const rows = featuredRows([rec('a', 1, NOW - 1), rec('b', 2), rec('c', 3, NOW + DAY)], NOW);
  assert.deepEqual(rows.map((r) => [r.trail.trailKey, r.ended, r.until]), [['c', false, NOW + DAY], ['b', false, null], ['a', true, NOW - 1]]);
});

test('Activity counts nominations', () => {
  assert.ok(ACTIVITY_KINDS.some((k) => k.recordType === 'TrailNomination'));
});

test('who nominated a trail never reaches the page', () => {
  const raw = { recordName: 'n', recordType: 'TrailNomination', created: { timestamp: 1, userRecordName: '_who' }, fields: {} };
  assert.equal(plain(raw).creator, undefined);
});
