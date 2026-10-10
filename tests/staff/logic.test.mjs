// The staff dashboard's rules (docs/staff/logic.js, actions.js).
// Run from the repo root: node --test tests/staff
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  groupReports, queue, topReason, removalPlan, buildSnapshot, SNAPSHOT_LIMIT, actionFields,
  filterByAuthor, countRecent, activity, DAY, parseWaypoints, routePath, describeError, isGone,
  isNotAllowed, describeItem, typeOfRecordType, reasonLabel,
} from '../../docs/staff/logic.js';
import { removeItem, dismissItem } from '../../docs/staff/actions.js';
import { plain } from '../../docs/staff/ck.js';

const report = (target, created, fields = {}) => ({
  recordName: `report.${target}.${created}`, recordType: 'CommunityReport', created,
  fields: { targetRecordName: target, targetType: 'post', reason: 'spam', ...fields },
});
const action = (target, created, kind = 'dismissed') => ({
  recordName: `act.${target}.${created}`, recordType: 'ModerationAction', created,
  fields: { targetRecordName: target, action: kind },
});
const utf8 = (s) => new TextEncoder().encode(s).length;

// MARK: Grouping

test('reports group by item, with reason counts, newest note first', () => {
  const groups = groupReports([
    report('a', 100, { reason: 'spam' }),
    report('a', 300, { reason: 'offensive', note: '  rude  ' }),
    report('a', 200, { reason: 'spam', note: 'ads' }),
    report('b', 150),
  ]);
  const a = groups.find((g) => g.target === 'a');
  assert.equal(a.count, 3);
  assert.equal(a.latestAt, 300);
  assert.equal(a.firstAt, 100);
  assert.deepEqual(a.reasons, [{ reason: 'spam', count: 2 }, { reason: 'offensive', count: 1 }]);
  assert.deepEqual(a.notes.map((n) => n.note), ['rude', 'ads']);
  assert.equal(groups.length, 2);
});

test('the item summary and author are the newest report\'s', () => {
  const [g] = groupReports([
    report('a', 300, { targetSummary: 'new', targetAuthorName: 'B' }),
    report('a', 100, { targetSummary: 'old', targetAuthorName: 'A' }),
  ]);
  assert.equal(g.summary, 'new');
  assert.equal(g.authorName, 'B');
});

test('an item is open until acted on, and opens again on a newer report', () => {
  const reports = [report('a', 100), report('b', 100), report('b', 500)];
  const groups = groupReports(reports, [action('a', 200), action('b', 50), action('b', 200)]);
  const a = groups.find((g) => g.target === 'a');
  const b = groups.find((g) => g.target === 'b');
  assert.equal(a.open, false);
  assert.equal(b.open, true);
  assert.equal(b.newCount, 1, 'only the report after the action is new');
  assert.equal(b.lastAction.created, 200, 'the latest action, not the first found');
  assert.deepEqual(queue(groups).map((g) => g.target), ['b']);
});

test('the queue orders by newest report, or by most reported', () => {
  const groups = groupReports([
    report('few', 900), report('many', 100), report('many', 200), report('many', 300),
  ]);
  assert.deepEqual(queue(groups, 'newest').map((g) => g.target), ['few', 'many']);
  assert.deepEqual(queue(groups, 'most').map((g) => g.target), ['many', 'few']);
});

test('the default removal reason is the commonest one reported', () => {
  const [g] = groupReports([report('a', 1, { reason: 'unsafe' }), report('a', 2, { reason: 'unsafe' }), report('a', 3, { reason: 'spam' })]);
  assert.equal(topReason(g), 'unsafe');
  assert.equal(topReason(null), 'other');
});

// MARK: Removal

test('removing deletes the item, then a challenge\'s entries or the votes on it', () => {
  assert.deepEqual(removalPlan('challenge', 'c1'), {
    item: { recordType: 'Challenge', recordName: 'c1' },
    related: [{ recordType: 'ChallengeEntry', field: 'challengeRecordName', value: 'c1' }],
  });
  assert.deepEqual(removalPlan('route', 'r1').related, [{ recordType: 'CommunityVote', field: 'targetRecordName', value: 'r1' }]);
  assert.deepEqual(removalPlan('post', 'p1').related, [{ recordType: 'CommunityVote', field: 'targetRecordName', value: 'p1' }]);
  assert.deepEqual(removalPlan('name', 'name.x').related, []);
  assert.throws(() => removalPlan('nope', 'x'));
});

test('a snapshot that fits is the whole record', () => {
  const rec = { recordType: 'WocketAchievement', recordName: 'p1', created: 5, fields: { message: 'hi', likes: 2 } };
  assert.deepEqual(JSON.parse(buildSnapshot(rec)), { ...rec });
});

test('a snapshot is never over 4 KB, and says what it cut', () => {
  const points = Array.from({ length: 2000 }, (_, i) => ({ latitude: 35 + i / 1e4, longitude: -78 }));
  const rec = { recordType: 'SharedRoute', recordName: 'r1', created: 5,
                fields: { name: 'Lake loop', waypointsJSON: JSON.stringify(points), authorName: 'Ann' } };
  const json = buildSnapshot(rec);
  assert.ok(utf8(json) <= SNAPSHOT_LIMIT, `${utf8(json)} bytes`);
  const snap = JSON.parse(json);
  assert.deepEqual(snap.cut, ['waypointsJSON']);
  assert.equal(snap.fields.name, 'Lake loop', 'short fields are kept');
  assert.ok(snap.fields.waypointsJSON.endsWith('…[cut]'));
});

test('the cap counts bytes, not characters', () => {
  const rec = { recordType: 'WocketAchievement', recordName: 'p', created: 1, fields: { message: '🥾'.repeat(3000) } };
  assert.ok(utf8(buildSnapshot(rec)) <= SNAPSHOT_LIMIT);
  assert.ok(utf8(buildSnapshot(rec, 1000)) <= 1000);
});

test('a removal can\'t be recorded without its snapshot', () => {
  assert.throws(() => actionFields({ target: 't', type: 'post', action: 'removed', snapshot: '' }));
  assert.throws(() => actionFields({ target: 't', type: 'post', action: 'deleted', snapshot: '{}' }));
  assert.equal(actionFields({ target: 't', type: 'post', action: 'dismissed', note: ' ok ' }).note, 'ok');
});

/** A store that records the order of calls. */
function fakeStore({ related = [], failCreate = false } = {}) {
  const calls = [];
  return {
    calls,
    async create(recordType, fields) {
      calls.push(['create', recordType, fields]);
      if (failCreate) throw { ckErrorCode: 'NETWORK_ERROR' };
      return { recordName: 'new', recordType, created: 1, fields };
    },
    async delete(names) { calls.push(['delete', names]); },
    async query(recordType, opts) { calls.push(['query', recordType, opts.equals]); return { records: related, more: false }; },
  };
}

test('Remove writes the action with its snapshot before deleting anything', async () => {
  const votes = [{ recordName: 'v1' }, { recordName: 'v2' }];
  const store = fakeStore({ related: votes });
  const record = { recordType: 'WocketAchievement', recordName: 'p1', created: 1, fields: { message: 'x' } };
  const n = await removeItem(store, { type: 'post', record, reason: 'spam', reportCount: 3 });
  assert.equal(n, 2);
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'delete', 'query', 'delete']);
  const [, type, fields] = store.calls[0];
  assert.equal(type, 'ModerationAction');
  assert.equal(fields.action, 'removed');
  assert.equal(fields.reportCount, 3);
  assert.equal(JSON.parse(fields.snapshot).recordName, 'p1');
  assert.deepEqual(store.calls[1][1], ['p1']);
  assert.deepEqual(store.calls[2], ['query', 'CommunityVote', ['targetRecordName', 'p1']]);
  assert.deepEqual(store.calls[3][1], ['v1', 'v2']);
});

test('if the action can\'t be written, nothing is deleted', async () => {
  const store = fakeStore({ failCreate: true });
  const record = { recordType: 'Challenge', recordName: 'c1', created: 1, fields: {} };
  await assert.rejects(removeItem(store, { type: 'challenge', record, reason: 'spam' }));
  assert.equal(store.calls.filter((c) => c[0] === 'delete').length, 0);
});

test('Dismiss writes a dismissed action and deletes nothing', async () => {
  const store = fakeStore();
  await dismissItem(store, { target: 'p1', type: 'post', note: 'fine', reportCount: 1 });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create']);
  assert.equal(store.calls[0][2].action, 'dismissed');
});

// MARK: Browse and activity

test('the author filter ignores case and outer spaces, across name fields', () => {
  const rs = [
    { fields: { authorName: 'MistyOak' } }, { fields: { displayName: 'misty fern' } },
    { fields: { name: 'QuietPine' } }, { fields: {} },
  ];
  assert.equal(filterByAuthor(rs, '  MISTY ').length, 2);
  assert.equal(filterByAuthor(rs, '').length, 4);
  assert.equal(filterByAuthor(rs, 'pine').length, 1);
});

test('activity counts the last 7 and 30 days, edges excluded', () => {
  const now = 100 * DAY;
  const at = (daysAgo) => ({ created: now - daysAgo * DAY });
  assert.deepEqual(countRecent([at(0), at(6.9), at(7), at(29.9), at(30), at(-1)], now), { d7: 2, d30: 4 });
  const rows = activity({ WocketAchievement: [at(1)], CommunityReport: [at(10)] }, now);
  assert.deepEqual(rows.find((r) => r.key === 'post'), { key: 'post', label: 'Posts', recordType: 'WocketAchievement', d7: 1, d30: 1 });
  assert.equal(rows.find((r) => r.key === 'report').d30, 1);
  assert.equal(rows.find((r) => r.key === 'vote').d30, 0);
});

// MARK: Route line

test('waypoints parse safely', () => {
  assert.equal(parseWaypoints('not json').length, 0);
  assert.equal(parseWaypoints('{"a":1}').length, 0);
  assert.equal(parseWaypoints('[{"latitude":1,"longitude":2},{"latitude":"x"}]').length, 1);
});

test('the route line fills the box, north up, keeping its shape', () => {
  // A route running due north: one vertical line through the middle.
  const north = routePath([{ latitude: 35, longitude: -78 }, { latitude: 35.01, longitude: -78 }], 160, 120, 10);
  assert.equal(north, 'M80.0 110.0 L80.0 10.0');
  // Due east at 60° N: 0.02° of longitude is as long as 0.01° of latitude, so
  // a square of those sides keeps a 1:1 aspect.
  const sq = routePath([
    { latitude: 60, longitude: 0 }, { latitude: 60, longitude: 0.02 }, { latitude: 60.01, longitude: 0.02 },
  ], 120, 120, 0);
  const pts = sq.split(/[ML]/).filter(Boolean).map((p) => p.trim().split(' ').map(Number));
  const w = Math.abs(pts[1][0] - pts[0][0]);
  const h = Math.abs(pts[2][1] - pts[1][1]);
  assert.ok(Math.abs(w - h) < 1.5, `w ${w} h ${h}`);
  assert.equal(routePath([{ latitude: 1, longitude: 1 }]), '');
  assert.equal(routePath([{ latitude: 1, longitude: 1 }, { latitude: 1, longitude: 1 }]), '');
});

// MARK: Text and errors

test('errors read as sentences, and gone or not-allowed are recognised', () => {
  assert.match(describeError({ ckErrorCode: 'NETWORK_ERROR' }), /reach iCloud/);
  assert.match(describeError({ ckErrorCode: 'ZONE_BUSY', reason: 'busy' }), /ZONE_BUSY: busy/);
  assert.ok(isGone({ ckErrorCode: 'UNKNOWN_ITEM' }));
  assert.ok(!isGone({ ckErrorCode: 'NETWORK_ERROR' }));
  assert.ok(isNotAllowed({ ckErrorCode: 'NOT_AUTHORIZED' }));
  assert.ok(!isNotAllowed({ ckErrorCode: 'UNKNOWN_ITEM' }));
});

test('items read as users see them', () => {
  assert.deepEqual(describeItem('post', { fields: { badgeEmoji: '🥾', badgeName: 'Trailblazer', message: 'hi' } }),
    { title: '🥾 Trailblazer', lines: ['hi'] });
  assert.deepEqual(describeItem('route', { fields: { name: 'Lake', distanceMeters: 2400, difficultyTag: 'easy', isLoop: 1 } }),
    { title: 'Lake', lines: ['2.4 km (1.5 mi) · easy · loop'] });
  assert.equal(typeOfRecordType('Challenge'), 'challenge');
  assert.equal(reasonLabel('personalInfo'), 'Shares someone\'s personal info');
});

test('a plain record carries no creator', () => {
  const rec = plain({ recordName: 'r', recordType: 'CommunityReport', created: { timestamp: 9, userRecordName: '_abc' },
                      fields: { reason: { value: 'spam' } } });
  assert.deepEqual(rec, { recordName: 'r', recordType: 'CommunityReport', created: 9, fields: { reason: 'spam' } });
  assert.ok(!JSON.stringify(rec).includes('_abc'));
});
