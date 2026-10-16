// One report per person per item (fix/community-report-random-names): the app
// names reports randomly, so CloudKit no longer refuses a second one, and the
// Reports queue must count each reporter once.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { groupReports } from '../../docs/staff/logic.js';
import { onePerReporter, pagedQuery, reportedByAuthor } from '../../docs/staff/ck.js';

const DAY = 86_400_000;
const T0 = Date.UTC(2026, 9, 16, 12);

/** A raw CloudKit JS report, as `performQuery` returns it. */
const raw = (name, who, target, created, reason = 'spam', note = '') => ({
  recordName: name, recordType: 'CommunityReport',
  created: { timestamp: created, userRecordName: who },
  fields: {
    targetRecordName: { value: target }, targetType: { value: 'post' },
    reason: { value: reason }, note: { value: note },
  },
});

/** A fake database returning `records` newest first, as `buildQuery` asks. */
const db = (records) => ({
  async performQuery() {
    return { records: [...records].sort((a, b) => b.created.timestamp - a.created.timestamp), moreComing: false };
  },
});

const dismissal = (target, created) => ({ recordName: `a${created}`, created, fields: { targetRecordName: target, targetType: 'post', action: 'dismissed' } });

test('one person reporting an item from two devices counts once', async () => {
  const { records } = await pagedQuery(db([
    raw('report.aaaa', '_a', 'p1', T0, 'spam'),
    raw('report.bbbb', '_a', 'p1', T0 + 1000, 'offensive'),
    raw('report.cccc', '_b', 'p1', T0 + 2000, 'spam'),
  ]), { recordType: 'CommunityReport' });
  const [g] = groupReports(records);
  assert.equal(g.count, 2);
  assert.equal(g.newCount, 2);
  assert.deepEqual(g.reasons, [{ reason: 'spam', count: 2 }], 'the oldest report of each person is the one counted');
});

test('one account cannot outvote everyone by creating many reports', () => {
  const flood = Array.from({ length: 50 }, (_, i) => raw(`report.${i}`, '_x', 'p1', T0 + i));
  assert.equal(onePerReporter(flood).length, 1);
});

test('a person who reported before a dismissal cannot reopen the item by reporting again', async () => {
  const { records } = await pagedQuery(db([
    raw('report.old', '_a', 'p1', T0),
    raw('report.new', '_a', 'p1', T0 + 2 * DAY),
  ]), { recordType: 'CommunityReport' });
  const [g] = groupReports(records, [dismissal('p1', T0 + DAY)]);
  assert.equal(g.open, false);
});

test('a new person reporting after a dismissal still reopens it', async () => {
  const { records } = await pagedQuery(db([
    raw('report.old', '_a', 'p1', T0),
    raw('report.new', '_b', 'p1', T0 + 2 * DAY),
  ]), { recordType: 'CommunityReport' });
  const [g] = groupReports(records, [dismissal('p1', T0 + DAY)]);
  assert.equal(g.open, true);
  assert.equal(g.newCount, 1);
});

test('the same person reporting different items counts on each', () => {
  const kept = onePerReporter([raw('r1', '_a', 'p1', T0), raw('r2', '_a', 'p2', T0 + 1)]);
  assert.equal(kept.length, 2);
});

test('old computed names and new random names from one person are one report', () => {
  const kept = onePerReporter([
    raw('report.9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08', '_a', 'p1', T0),
    raw('report.3f1c2a8e-5b0d-4e8a-9c7f-1a2b3c4d5e6f', '_a', 'p1', T0 + DAY),
  ]);
  assert.deepEqual(kept.map((r) => r.recordName), ['report.9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08']);
});

test('the oldest is kept whatever order the records arrive in', () => {
  const a = raw('old', '_a', 'p1', T0);
  const b = raw('new', '_a', 'p1', T0 + 5);
  assert.deepEqual(onePerReporter([a, b]).map((r) => r.recordName), ['old']);
  assert.deepEqual(onePerReporter([b, a]).map((r) => r.recordName), ['old']);
});

test('reports with no creator or no target are all kept', () => {
  const anon = (name) => ({ ...raw(name, '_a', 'p1', T0), created: { timestamp: T0 } });
  const noTarget = (name) => ({ ...raw(name, '_a', 'p1', T0), fields: { reason: { value: 'spam' } } });
  assert.equal(onePerReporter([anon('a1'), anon('a2'), noTarget('n1'), noTarget('n2')]).length, 4);
});

test('an owner asking to delete on two days counts on each; twice in one UTC day, once (the newest)', () => {
  const req = (name, created) => raw(name, '_owner', 'c1', created, 'ownerRequest');
  const kept = onePerReporter([req('q1', T0), req('q2', T0 + 1000), req('q3', T0 + DAY)]);
  assert.deepEqual(kept.map((r) => r.recordName).sort(), ['q2', 'q3']);
});

test('an owner in Los Angeles asking again the next morning, after a dismissal the same UTC day, reopens it', async () => {
  // 6 pm Oct 11 in LA is 01:00Z Oct 12; 9 am Oct 12 in LA is 16:00Z Oct 12: two local days, one UTC day.
  const req = (name, iso) => raw(name, '_owner', 'c1', Date.parse(iso), 'ownerRequest');
  const { records } = await pagedQuery(db([req('q1', '2026-10-12T01:00:00Z'), req('q2', '2026-10-12T16:00:00Z')]),
    { recordType: 'CommunityReport' });
  const [g] = groupReports(records, [dismissal('c1', Date.parse('2026-10-12T03:00:00Z'))]);
  assert.equal(g.open, true);
  assert.equal(g.newCount, 1);
});

test('an owner request after a dismissal, on a later day, reopens the challenge', async () => {
  const req = (name, created) => raw(name, '_owner', 'c1', created, 'ownerRequest');
  const { records } = await pagedQuery(db([req('q1', T0), req('q2', T0 + 2 * DAY)]), { recordType: 'CommunityReport' });
  const [g] = groupReports(records, [dismissal('c1', T0 + DAY)]);
  assert.equal(g.open, true);
});

test('a report and an owner request from one person on one item are counted apart', () => {
  const kept = onePerReporter([raw('r', '_a', 'c1', T0, 'spam'), raw('q', '_a', 'c1', T0 + 1, 'ownerRequest')]);
  assert.equal(kept.length, 2);
});

test('the reporter never reaches the page, and the owner check still works on the kept report', async () => {
  const { records } = await pagedQuery(db([
    raw('report.q1', '_owner', 'c1', T0, 'ownerRequest'),
    raw('report.q2', '_owner', 'c1', T0 + 1000, 'ownerRequest'),
  ]), { recordType: 'CommunityReport' });
  assert.equal(records.length, 1);
  assert.equal(records[0].creator, undefined);
  assert.ok(!JSON.stringify(records).includes('_owner'));
  assert.equal(reportedByAuthor(records[0].recordName, '_owner'), true);
});

test('a query by creator, for erasing a person\'s reports, gets every one', async () => {
  const { records } = await pagedQuery(db([
    raw('report.1', '_a', 'p1', T0), raw('report.2', '_a', 'p1', T0 + 1),
  ]), { recordType: 'CommunityReport' }, { onlyCreator: '_a' });
  assert.equal(records.length, 2);
});

test('other record types are not collapsed as reports', async () => {
  const { records } = await pagedQuery(db([
    { ...raw('v1', '_a', 'p1', T0), recordType: 'CommunityVote' },
    { ...raw('v2', '_a', 'p1', T0 + 1), recordType: 'CommunityVote' },
  ]), { recordType: 'CommunityVote' });
  assert.equal(records.length, 2);
});
