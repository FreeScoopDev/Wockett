// The staff dashboard's rules (docs/staff/logic.js, actions.js).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  groupReports, queue, topReason, removalPlan, buildSnapshot, SNAPSHOT_LIMIT, actionFields,
  filterByAuthor, countRecent, activity, DAY, parseWaypoints, routePath, describeError, isGone,
  isNotAllowed, describeItem, typeOfRecordType, reasonLabel, knownType, effectiveType, reopenFailedRemovals,
  targetsToCheck, isValidRecordName,
} from '../../docs/staff/logic.js';
import { removeItem, dismissItem } from '../../docs/staff/actions.js';
import { plain, pagedQuery, buildQuery, hasMorePages, fetchExisting } from '../../docs/staff/ck.js';

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
function fakeStore({ related = [], failCreate = false, failDeletes = 0 } = {}) {
  const calls = [];
  let deletesToFail = failDeletes;
  return {
    calls,
    async create(recordType, fields) {
      calls.push(['create', recordType, fields]);
      if (failCreate) throw { ckErrorCode: 'NETWORK_ERROR' };
      return { recordName: 'new', recordType, created: 1, fields };
    },
    async delete(names) {
      calls.push(['delete', names]);
      if (deletesToFail > 0) { deletesToFail -= 1; throw { ckErrorCode: 'ACCESS_DENIED' }; }
    },
    async query(recordType, opts) { calls.push(['query', recordType, opts.equals]); return { records: related, more: false }; },
  };
}

test('Remove writes the action with its snapshot before deleting anything', async () => {
  const votes = [{ recordName: 'v1' }, { recordName: 'v2' }];
  const store = fakeStore({ related: votes });
  const record = { recordType: 'WocketAchievement', recordName: 'p1', created: 1, fields: { message: 'x' } };
  const { related, relatedError } = await removeItem(store, { type: 'post', record, reason: 'spam', reportCount: 3 });
  assert.equal(related, 2);
  assert.equal(relatedError, null);
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

// MARK: Second critic run

test('report text is never trusted as a key', () => {
  assert.equal(reasonLabel('constructor'), 'constructor');
  assert.equal(reasonLabel('toString'), 'toString');
  assert.equal(knownType('toString'), undefined);
  assert.equal(knownType('__proto__'), undefined);
  assert.equal(knownType('route'), 'route');
});

test('what an item is comes from its record, not the report', () => {
  const group = { type: 'challenge' };
  assert.equal(effectiveType(group, { recordType: 'WocketAchievement' }), 'post');
  assert.equal(effectiveType(group, { recordType: 'ModerationAction' }), undefined, 'not community content: dismiss only');
  assert.equal(effectiveType({ type: 'toString' }, null), undefined);
  assert.equal(effectiveType({ type: 'route' }, null), 'route');
});

test('a failed delete takes back the removal record and rethrows', async () => {
  const store = fakeStore({ failDeletes: 1 });
  const record = { recordType: 'SharedRoute', recordName: 'r1', created: 1, fields: {} };
  await assert.rejects(removeItem(store, { type: 'route', record, reason: 'spam' }), { ckErrorCode: 'ACCESS_DENIED' });
  assert.deepEqual(store.calls.map((c) => c[0]), ['create', 'delete', 'delete']);
  assert.deepEqual(store.calls[2][1], ['new'], 'the ModerationAction just written');
  assert.equal(store.calls.filter((c) => c[0] === 'query').length, 0, 'nothing related is touched');
});

test('an item still up after a "removed" action goes back in the queue, flagged', () => {
  const groups = groupReports([report('a', 100), report('b', 100)], [action('a', 200, 'removed'), action('b', 200, 'removed')]);
  const reopened = reopenFailedRemovals(groups, new Map([['a', {}]]));
  assert.deepEqual(queue(reopened).map((g) => g.target), ['a']);
  assert.equal(reopened.find((g) => g.target === 'a').removalFailed, true);
  const dismissed = groupReports([report('c', 100)], [action('c', 200, 'dismissed')]);
  assert.equal(queue(reopenFailedRemovals(dismissed, new Map([['c', {}]]))).length, 0, 'a dismissed item stays up on purpose');
});

test('a re-opened item is judged on its new reports only', () => {
  const old = Array.from({ length: 5 }, (_, i) => report('a', 10 + i, { reason: 'spam', note: `old ${i}` }));
  const [g] = groupReports([...old, report('a', 500, { reason: 'offensive', note: 'new' })], [action('a', 100)]);
  assert.deepEqual(g.reasons, [{ reason: 'offensive', count: 1 }]);
  assert.deepEqual(g.notes.map((n) => n.note), ['new']);
  assert.equal(topReason(g), 'offensive');
  assert.equal(g.count, 6, 'the total still counts every report');
});

test('most reported ranks by reports since the last action', () => {
  const groups = groupReports([
    report('was-busy', 10), report('was-busy', 11), report('was-busy', 12), report('was-busy', 300),
    report('new', 200), report('new', 201),
  ], [action('was-busy', 100)]);
  assert.deepEqual(queue(groups, 'most').map((g) => g.target), ['new', 'was-busy']);
});

test('items acted on this session stay out of the queue until reported again', () => {
  const groups = groupReports([report('a', 1), report('b', 2)]);
  assert.deepEqual(queue(groups, 'newest', new Map([['b', 100]])).map((g) => g.target), ['a']);
  const again = groupReports([report('b', 2), report('b', 500)]);
  assert.deepEqual(queue(again, 'newest', new Map([['b', 100]])).map((g) => g.target), ['b'], 'a newer report brings it back');
});

test('a snapshot of many small fields still fits', () => {
  const fields = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`f${i}`, 'x'.repeat(100)]));
  const json = buildSnapshot({ recordType: 'T', recordName: 'n', created: 1, fields });
  assert.ok(utf8(json) <= SNAPSHOT_LIMIT, `${utf8(json)} bytes`);
  assert.equal(JSON.parse(json).recordName, 'n');
});

// MARK: Paging (the property name itself is checked only against a live container)

function fakeDb(pages) {
  const sent = [];
  let i = 0;
  return {
    sent,
    async performQuery(q, opts) { sent.push([q, opts]); return pages[i++]; },
  };
}
const page = (names, more) => ({ records: names.map((n) => ({ recordName: n, recordType: 'T', fields: {} })), ...more });

test('a query follows every page while moreComing', async () => {
  const db = fakeDb([page(['a', 'b'], { moreComing: true }), page(['c'], { moreComing: true }), page(['d'], { moreComing: false })]);
  const { records, more } = await pagedQuery(db, buildQuery('T'), { max: 100, pageSize: 2 });
  assert.deepEqual(records.map((r) => r.recordName), ['a', 'b', 'c', 'd']);
  assert.equal(more, false);
  assert.equal(db.sent.length, 3);
  assert.equal(db.sent[1][0].moreComing, true, 'the next page is asked for with the previous response');
});

test('a query stops at max and says more were left', async () => {
  const db = fakeDb([page(['a', 'b'], { moreComing: true }), page(['c', 'd'], { moreComing: true })]);
  const { records, more } = await pagedQuery(db, buildQuery('T'), { max: 3, pageSize: 2 });
  assert.equal(records.length, 3);
  assert.equal(more, true);
});

test('a continuation marker alone also means more pages', () => {
  assert.ok(hasMorePages({ continuationMarker: 'xyz' }));
  assert.ok(!hasMorePages({ records: [] }));
});

test('a query with an error response throws it', async () => {
  const db = fakeDb([{ hasErrors: true, errors: [{ ckErrorCode: 'ACCESS_DENIED' }] }]);
  await assert.rejects(pagedQuery(db, buildQuery('T')), { ckErrorCode: 'ACCESS_DENIED' });
});

test('the age filter is a typed timestamp on the creation time, newest first', () => {
  const q = buildQuery('CommunityVote', { sinceMs: 1000, equals: ['targetRecordName', 'r1'] });
  assert.deepEqual(q.filterBy, [
    { fieldName: 'targetRecordName', comparator: 'EQUALS', fieldValue: { value: 'r1' } },
    { systemFieldName: 'createdTimestamp', comparator: 'GREATER_THAN_OR_EQUALS', fieldValue: { value: 1000, type: 'TIMESTAMP' } },
  ]);
  assert.deepEqual(q.sortBy, [{ systemFieldName: 'createdTimestamp', ascending: false }]);
});

// MARK: Third critic run

test('failed related deletes are reported, not thrown: the item is already gone', async () => {
  const store = fakeStore({ related: [{ recordName: 'v1' }] });
  const realDelete = store.delete;
  let n = 0;
  store.delete = async (names) => { n += 1; if (n === 2) throw { ckErrorCode: 'THROTTLED' }; return realDelete(names); };
  const record = { recordType: 'SharedRoute', recordName: 'r1', created: 1, fields: {} };
  const out = await removeItem(store, { type: 'route', record, reason: 'spam' });
  assert.deepEqual(out.relatedError, { ckErrorCode: 'THROTTLED' });
  assert.equal(out.related, 0);
});

test('lookups cover open items and past removals, open first, capped', () => {
  const groups = groupReports([report('open', 300), report('removed', 100), report('dismissed', 100)],
    [action('removed', 200, 'removed'), action('dismissed', 200, 'dismissed')]);
  assert.deepEqual(targetsToCheck(groups), ['open', 'removed']);
  assert.deepEqual(targetsToCheck(groups, 1), ['open']);
});

test('only names CloudKit could accept are looked up', () => {
  assert.ok(isValidRecordName('report.abc_123'));
  assert.ok(!isValidRecordName('x'.repeat(256)));
  assert.ok(!isValidRecordName('naïve'));
  assert.ok(!isValidRecordName('has space'));
  assert.ok(!isValidRecordName(''));
});

test('one bad name or record error leaves the rest of the lookup intact', async () => {
  const asked = [];
  const db = {
    async fetchRecords(names) {
      asked.push(...names);
      return { hasErrors: true, errors: [{ ckErrorCode: 'BAD_REQUEST', recordName: 'odd' }],
               records: [{ recordName: 'good', recordType: 'WocketAchievement', fields: {} }, { recordName: 'odd', serverErrorCode: 'BAD_REQUEST' }] };
    },
  };
  const found = await fetchExisting(db, ['good', 'odd', 'x'.repeat(300)]);
  assert.deepEqual([...found.keys()], ['good']);
  assert.ok(!asked.includes('x'.repeat(300)), 'an impossible name is never sent');
});

test('a challenge with an impossible date still reads', () => {
  const item = describeItem('challenge', { fields: { title: 'T', startDate: 1e16, endDate: 1e16 } });
  assert.match(item.lines[0], /\?/);
});
