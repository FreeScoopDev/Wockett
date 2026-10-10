// Trail nominations and featured trails on the staff dashboard.
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  groupNominations, nominationQueue, featureUntil, featuredRecordName, featuredFields, mapsLink, featuredRows,
  BLURB_LIMIT, DAY, ACTIVITY_KINDS, groupReports, queue, isTrailKey,
} from '../../docs/staff/logic.js';
import { featureTrail, unfeatureTrail, dismissNominations } from '../../docs/staff/actions.js';
import { plain, onePerNominator, pagedQuery } from '../../docs/staff/ck.js';

const NOW = 1_800_000_000_000;
const trail = { trailKey: 'nc:w1', trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400 };
const nom = (key, created, fields = {}) => ({
  recordName: `nomination.${key}.${created}`, recordType: 'TrailNomination', created,
  fields: { trailKey: key, trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400, ...fields },
});
const act = (key, created, action = 'dismissed', targetType = 'trail') => ({ created, fields: { targetRecordName: key, action, targetType } });

function fakeStore({ exists = false, failSave = false, failDelete = false } = {}) {
  const calls = [];
  return {
    calls,
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: 'act1', recordType, created: 1, fields }; },
    async fetch(names) { calls.push(['fetch', names]); return new Map(exists ? [[names[0], { fields: exists === true ? {} : exists }]] : []); },
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
    nom('nc:busy', 10), nom('nc:busy', 11), nom('nc:busy', 12), nom('nc:busy', 500), nom('nc:new', 300), nom('nc:new', 301),
  ], [act('nc:busy', 100)]);
  assert.deepEqual(nominationQueue(groups, 'most').map((g) => g.trailKey), ['nc:new', 'nc:busy']);
  assert.deepEqual(nominationQueue(groups, 'newest').map((g) => g.trailKey), ['nc:busy', 'nc:new']);
  assert.deepEqual(nominationQueue(groups, 'most', new Map([['nc:new', 400]])).map((g) => g.trailKey), ['nc:busy']);
  assert.deepEqual(nominationQueue(groups, 'most', new Map([['nc:new', 250]])).map((g) => g.trailKey), ['nc:new', 'nc:busy'],
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
  // Reading the current feature first is fine: History is still written before the record.
  assert.deepEqual(fresh.calls.map((c) => c[0]), ['fetch', 'create', 'createNamed']);
  assert.equal(fresh.calls[1][2].action, 'featured');
  assert.equal(fresh.calls[1][2].targetType, 'trail');
  assert.equal(fresh.calls[1][2].targetRecordName, 'nc:w1');
  const again = fakeStore({ exists: true });
  await featureTrail(again, { trail, blurb: 'Shadier', length: 'open', now: NOW });
  assert.deepEqual(again.calls.map((c) => c[0]), ['fetch', 'create', 'replaceNamed']);
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

// MARK: Second round (critic run 1)

test('a trail action never closes reports on an item with the same name, and the reverse', () => {
  const report = { recordName: 'r', recordType: 'CommunityReport', created: 100, fields: { targetRecordName: 'route-1', targetType: 'route', reason: 'spam' } };
  const trailAction = act('route-1', 200, 'dismissed', 'trail');
  assert.equal(queue(groupReports([report], [trailAction])).length, 1, 'the route stays reported');
  const accountAction = act('route-1', 200, 'suspended', 'account');
  assert.equal(queue(groupReports([report], [accountAction])).length, 1);
  const itemAction = { created: 200, fields: { targetRecordName: 'nc:w1', action: 'removed', targetType: 'route' } };
  assert.equal(nominationQueue(groupNominations([nom('nc:w1', 100)], [itemAction])).length, 1, 'the trail stays nominated');
});

test('one crafted nomination can\'t rename or move a trail; disagreement is flagged', () => {
  const honest = [nom('nc:w1', 100), nom('nc:w1', 101), nom('nc:w1', 102)];
  const outlier = nom('nc:w1', 999, { trailName: 'Totally Different', latitude: 10, longitude: 10 });
  const [g] = groupNominations([...honest, outlier]);
  assert.equal(g.trail.trailName, 'Lake Loop');
  assert.equal(g.trail.latitude, 35.78);
  assert.equal(g.disagree, true);
  assert.deepEqual(g.names, ['Lake Loop', 'Totally Different']);
  assert.equal(groupNominations(honest)[0].disagree, false);
});

test('a tie keeps the description that came first, and the region comes from the key', () => {
  // Newest first, as the query returns them: without the tie-break the later one would win.
  const [g] = groupNominations([nom('nc:w1', 200, { trailName: 'Late Name', latitude: 36 }), nom('nc:w1', 100, { region: 'zz' })]);
  assert.equal(g.trail.trailName, 'Lake Loop');
  assert.equal(g.trail.region, 'nc');
});

test('nominations with an impossible key, no name or no point are ignored', () => {
  assert.ok(isTrailKey('nc:w123'));
  assert.ok(!isTrailKey('route-1'));
  assert.ok(!isTrailKey('NC:w1'));
  assert.ok(!isTrailKey('nc:' + 'x'.repeat(81)));
  const groups = groupNominations([
    nom('route-1', 1), nom('nc:w2', 2, { trailName: '  ' }), nom('nc:w3', 3, { latitude: undefined }), nom('nc:w4', 4, { longitude: 500 }),
  ]);
  assert.equal(groups.length, 0);
});

test('a trail with no usable point or name can\'t be featured', () => {
  assert.throws(() => featuredFields({ trailKey: 'nc:w9', trailName: 'X' }, 'note', null));
  assert.throws(() => featuredFields({ ...trail, trailName: ' ' }, 'note', null));
  assert.throws(() => featuredFields({ ...trail, trailKey: 'route-1' }, 'note', null));
});

test('featuring again keeps the trail as first featured; only the note and the end change', async () => {
  const existing = { trailKey: 'nc:w1', trailName: 'Lake Loop', region: 'nc', latitude: 35.78, longitude: -78.64, lengthMeters: 2400, until: NOW };
  const store = fakeStore({ exists: existing });
  const later = { ...trail, trailName: 'Renamed By Someone', latitude: 10, longitude: 10 };
  await featureTrail(store, { trail: later, blurb: 'New note', keepUntil: NOW });
  const fields = store.calls.find((c) => c[0] === 'replaceNamed')[3];
  assert.equal(fields.trailName, 'Lake Loop');
  assert.equal(fields.latitude, 35.78);
  assert.equal(fields.blurb, 'New note');
  assert.deepEqual(fields.until, { value: NOW, type: 'TIMESTAMP' }, 'the end kept');
});

// MARK: Third round (critic run 2)

const raw = (who, key, created) => ({
  recordName: `n.${who}.${key}.${created}`, recordType: 'TrailNomination',
  created: { timestamp: created, userRecordName: who }, fields: { trailKey: { value: key } },
});

test('one nomination per person per trail, the newest, however many records they make', () => {
  const kept = onePerNominator([raw('_a', 'nc:w1', 300), raw('_a', 'nc:w1', 200), raw('_a', 'nc:w1', 100), raw('_b', 'nc:w1', 150), raw('_a', 'nc:w2', 50)]);
  assert.deepEqual(kept.map((r) => r.created.timestamp), [300, 150, 50]);
});

test('the query collapses nominations before the page sees them, and drops who made them', async () => {
  const db = { async performQuery() { return { records: [raw('_a', 'nc:w1', 3), raw('_a', 'nc:w1', 2)], moreComing: false }; } };
  const { records } = await pagedQuery(db, { recordType: 'TrailNomination' });
  assert.equal(records.length, 1);
  assert.equal(records[0].creator, undefined);
  const other = await pagedQuery(db, { recordType: 'CommunityReport' });
  assert.equal(other.records.length, 2, 'only nominations are collapsed');
});

test('every description is listed with its count, so a moved point shows even with one name', () => {
  const [g] = groupNominations([nom('nc:w1', 1), nom('nc:w1', 2), nom('nc:w1', 3, { latitude: 36.5 })]);
  assert.equal(g.disagree, true);
  assert.deepEqual(g.variants.map((v) => [v.trail.trailName, v.trail.latitude, v.count]), [['Lake Loop', 35.78, 2], ['Lake Loop', 36.5, 1]]);
});
