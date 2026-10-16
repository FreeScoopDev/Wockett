// Trail suggestions on the staff dashboard (spec feat/trail-suggestions, PR 1).
// Run from the repo root: node --test tests/staff/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import {
  decodePolyline, lineLength, overlapShare, sameLine, suggestionOf, suggestionIssueText, groupSuggestions, suggestionDecisions,
  suggestionStatusNames, acceptPlan, declinePlan, acceptTellText, suggestionToldText, suggestionHistoryText, gpxDocument, gpxFileName,
  osmEditLink, mapsLink, routePath, routePaths, contributionStatusFields, textLength, isTrailKey, longestStretch,
  lineIndex, UNITS_PER_CHARACTER, GROUPING_BUDGET, MAX_INDEX_ENTRIES, INDEX_ENTRY_WORK, SAMPLE_WORK, samplesOf, flatLength,
  SUGGESTION_CAPS, LINE_CHAR_LIMIT, OVERLAP_TOLERANCE_M, OVERLAP_SHARE, OVERLAP_STEP_M, SHORT_SUGGESTION_M, LONG_SUGGESTION_M,
  STRAIGHT_STRETCH_M, TOKENS_PER_SUGGESTER, SUGGESTION_FACTS, SUGGESTION_STATUS_TRAIL_KEY,
  NON_ITEM_TARGETS, ACTIONS, ACTIVITY_KINDS, actionFields, groupReports, queue, groupNominations, statusesToWithdraw,
} from '../../docs/staff/logic.js';
import {
  acceptSuggestions, acceptSuggestionsAndTell, publishSuggestionStatuses, declineSuggestions, findSuggestionsBy, deleteSuggestionsBy,
} from '../../docs/staff/actions.js';
import { pagedQuery, connect, nameLeaks, plain, suggesterToken, reporterToken } from '../../docs/staff/ck.js';

const NOW = Date.UTC(2026, 9, 16, 12, 0, 0);
const TOKEN = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';
// shasum -a 256 of the token's exact text, computed outside this code (the C1 test vector).
const TOKEN_NAME = 'status.949960179bb0c122dce42afa24e79611f32cbea403a75ffe8b4d5c07e73ed951';
const TOKEN2 = '0B4E1D7A-2F3C-4A5B-8C9D-AEBFC0D1E2F3';
const TOKEN3 = '5D2C9A41-7E6B-4F80-9A1C-3B2D4E5F6A7B';
const CREATOR = '_a1b2c3d4e5f60718293a4b5c6d7e8f90';
const OTHER = '_f9e8d7c6b5a4938271605f4e3d2c1b0a';
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

// MARK: Fixtures

/**
 * A Google encoded polyline, written here independently of the page's
 * decoder (Google's published algorithm), so the round trip compares two
 * implementations rather than one with itself.
 */
function encode(points, precision = 5) {
  const factor = 10 ** precision;
  let out = '';
  let pLat = 0;
  let pLng = 0;
  const one = (v) => {
    let n = v < 0 ? ~(v << 1) : v << 1;
    let s = '';
    while (n >= 0x20) {
      s += String.fromCharCode((0x20 | (n & 0x1f)) + 63);
      n >>= 5;
    }
    return s + String.fromCharCode(n + 63);
  };
  for (const p of points) {
    const lat = Math.round(p.latitude * factor);
    const lng = Math.round(p.longitude * factor);
    out += one(lat - pLat) + one(lng - pLng);
    pLat = lat;
    pLng = lng;
  }
  return out;
}

const ORIGIN = { latitude: 35.78, longitude: -78.64 };
/** The point `east`, `north` metres from `origin`. */
function at(east, north, origin = ORIGIN) {
  const latitude = origin.latitude + north / 111_195;
  const longitude = origin.longitude + east / (111_195 * Math.cos((origin.latitude * Math.PI) / 180));
  return { latitude, longitude };
}
/** A bending path: `n` points 20 m apart heading north-east, gently curving, shifted by `east` / `north`. */
function path(n = 60, { east = 0, north = 0, jitter = 0, seed = 1 } = {}) {
  let r = seed;
  const rand = () => { r = (r * 16807) % 2147483647; return (r / 2147483647) * 2 - 1; };
  return Array.from({ length: n }, (_, i) => at(i * 14 + 40 * Math.sin(i / 9) + east + rand() * jitter, i * 14 + north + rand() * jitter));
}

/** A path running due north with a small wiggle, `east` metres to the east: shifting it moves it straight sideways. */
function northPath(n = 60, east = 0) {
  return Array.from({ length: n }, (_, i) => at(east + 5 * Math.sin(i / 4), i * 20));
}

/** A suggestion as ck.js hands it to the page. */
const sugg = (recordName, points, { created = 1, name = 'Creek Path', submitter = `s-${recordName}`, statusName, note = '', region = 'nc',
  facts = {}, pointCount, lengthMeters, line } = {}) => ({
  recordName, recordType: 'TrailSuggestion', created, ...(submitter ? { submitter } : {}), ...(statusName ? { statusName } : {}),
  fields: {
    name, note, region, line: line ?? (points ? encode(points) : undefined),
    pointCount: pointCount ?? points?.length, lengthMeters: lengthMeters ?? (points ? lineLength(points.map(round5)) : undefined), ...facts,
  },
});
const round5 = (p) => ({ latitude: Math.round(p.latitude * 1e5) / 1e5, longitude: Math.round(p.longitude * 1e5) / 1e5 });
const NAME_A = `status.${'a'.repeat(64)}`;
const NAME_B = `status.${'b'.repeat(64)}`;
const NAME_C = `status.${'c'.repeat(64)}`;

/**
 * A store like ck.js's `connect()`, logging calls. `existing` maps names to
 * what `fetch` finds; `failWriteNames` fails those status writes;
 * `failWriteAt` the Nth status write and every one after; `failStatusQuery`
 * is thrown by ContributionStatus queries; `found` answers creator queries;
 * `failDeleteAt` the Nth delete that isn't History (with `partly` deleted).
 */
function fakeStore({ existing = new Map(), failWriteNames = [], failWriteAt = null, failStatusQuery = null, found = [],
  failDeleteAt = null, partly } = {}) {
  const calls = [];
  let writes = 0;
  let acts = 0;
  let deletes = 0;
  const write = (kind) => async (recordType, recordName, fields) => {
    calls.push([kind, recordType, recordName, fields]);
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
      return { records: [], more: false };
    },
    async queryByCreator(recordType, account, options) { calls.push(['queryByCreator', recordType, account, options]); return { records: found, more: false }; },
    async fetch(names) { calls.push(['fetch', names]); return new Map(names.filter((n) => existing.has(n)).map((n) => [n, existing.get(n)])); },
    async create(recordType, fields) { calls.push(['create', recordType, fields]); return { recordName: `act${++acts}`, recordType, created: 1, fields: {} }; },
    createNamed: write('createNamed'),
    replaceNamed: write('replaceNamed'),
    async delete(names) {
      calls.push(['delete', names]);
      if (/^act\d+$/.test(names[0])) return;
      deletes += 1;
      if (failDeleteAt !== null && deletes >= failDeleteAt) throw { ckErrorCode: 'NETWORK_ERROR', ...(partly === undefined ? {} : { deleted: partly }) };
    },
  };
}
const history = (store) => store.calls.filter((c) => c[0] === 'create' && c[1] === 'ModerationAction').map((c) => c[2]);
const statusWrites = (store) => store.calls.filter((c) => (c[0] === 'createNamed' || c[0] === 'replaceNamed') && c[1] === 'ContributionStatus');
const writtenTypes = (store) => [...new Set(store.calls.filter((c) => ['create', 'createNamed', 'replaceNamed'].includes(c[0])).map((c) => c[1]))].sort();

// MARK: The polyline decoder

test('the decoder reads Google\'s published example exactly', () => {
  // developers.google.com/maps/documentation/utilities/polylinealgorithm
  assert.deepEqual(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), [
    { latitude: 38.5, longitude: -120.2 }, { latitude: 40.7, longitude: -120.95 }, { latitude: 43.252, longitude: -126.453 },
  ]);
  assert.deepEqual(decodePolyline(''), [], 'no text is no points');
});

test('a line survives encoding and decoding to 1e-5 degrees, in every quadrant and at the edges of the globe', () => {
  let r = 7;
  const rand = () => { r = (r * 48271) % 2147483647; return r / 2147483647; };
  const points = [{ latitude: 0, longitude: 0 }, { latitude: 89.99999, longitude: 179.99999 }, { latitude: -90, longitude: -180 },
    { latitude: -0.00001, longitude: 0.00001 }, ...Array.from({ length: 500 }, () => ({ latitude: rand() * 180 - 90, longitude: rand() * 360 - 180 }))];
  const back = decodePolyline(encode(points));
  assert.equal(back.length, points.length);
  points.forEach((p, i) => {
    assert.ok(Math.abs(back[i].latitude - p.latitude) <= 0.000005 + 1e-12, `lat ${i}`);
    assert.ok(Math.abs(back[i].longitude - p.longitude) <= 0.000005 + 1e-12, `lng ${i}`);
  });
  // A real walk: 20 m steps survive to the centimetre-free precision the app sends.
  const walk = path(200).map(round5);
  assert.deepEqual(decodePolyline(encode(walk)).map(round5), walk);
});

test('anything that isn\'t an encoded polyline is refused, not guessed', () => {
  const good = encode([{ latitude: 35.78, longitude: -78.64 }, { latitude: 35.79, longitude: -78.65 }]);
  for (const bad of [
    good.slice(0, -1),            // the last value cut off
    `${good}_`,                   // a value with its continuation bit set and nothing after
    ` ${good}`,                   // a character below '?'
    `${good}>>`,                  // '>' is one below '?': read as a value, it would be a point 2 m away
    `${good}\u007f`,              // and above '~'
    'é',
    '~~~~~~~~~?',                 // a value too long to be a coordinate
    encode([{ latitude: 95, longitude: 0 }]),
    encode([{ latitude: 0, longitude: 181 }]),
    null, undefined, 42, ['_p~iF'],
  ]) {
    assert.equal(decodePolyline(bad), null, JSON.stringify(bad));
  }
});

test('lengths are measured along the line on the globe', () => {
  // 0.01° of latitude is 1,111.95 m on a 6,371,008.8 m sphere.
  assert.ok(Math.abs(lineLength([{ latitude: 35, longitude: -78 }, { latitude: 35.01, longitude: -78 }]) - 1111.95) < 0.1);
  assert.equal(lineLength([{ latitude: 35, longitude: -78 }]), 0);
  assert.equal(lineLength([]), 0);
});

// MARK: Grouping duplicates by line

test('the overlap rule\'s numbers are the documented ones', () => {
  assert.deepEqual([OVERLAP_TOLERANCE_M, OVERLAP_SHARE, OVERLAP_STEP_M], [30, 0.6, 25]);
});

test('the same path walked twice, with GPS wander, is one group', () => {
  const a = path(80, { jitter: 8, seed: 3 });
  const b = path(80, { jitter: 8, seed: 11 });
  assert.ok(sameLine(a, b));
  const groups = groupSuggestions([sugg('s1', a, { created: 1 }), sugg('s2', b, { created: 2, name: 'Old Mill Trail' })]);
  assert.equal(groups.length, 1);
  assert.deepEqual(groups[0].members.map((m) => m.recordName), ['s1', 's2']);
  assert.deepEqual(groups[0].names, [{ name: 'Creek Path', count: 1 }, { name: 'Old Mill Trail', count: 1 }], 'grouped by line, not name');
});

test('the same path walked the other way round is one group', () => {
  const a = path(80);
  assert.ok(sameLine(a, [...path(80, { jitter: 5, seed: 5 })].reverse()));
  assert.equal(groupSuggestions([sugg('s1', a), sugg('s2', [...a].reverse())]).length, 1);
});

test('a walker who did part of a path is grouped with one who did all of it', () => {
  const whole = path(100);
  const part = path(100).slice(30, 70);
  assert.ok(sameLine(whole, part));
  assert.ok(sameLine(part, whole), 'either order');
  assert.ok(overlapShare(whole, part) < OVERLAP_SHARE, 'the longer line alone would not say so: the shorter one decides');
});

test('a path near but apart from another (50 m), and one that only crosses it, are separate groups', () => {
  const a = path(80);
  const parallel = northPath(80, 50);
  assert.ok(!sameLine(northPath(80), parallel));
  assert.ok(!sameLine(a, parallel));
  // Due east through the middle of `a`.
  const crossing = Array.from({ length: 60 }, (_, i) => at(-400 + i * 25, 560));
  assert.ok(!sameLine(a, crossing));
  const far = path(80, { north: 5000 });
  assert.ok(!sameLine(a, far));
  assert.equal(groupSuggestions([sugg('s1', northPath(80)), sugg('s2', parallel), sugg('s3', crossing), sugg('s4', far)]).length, 4);
});

test('the tolerance is where the rule turns: 25 m apart is the same path, 40 m is not', () => {
  const a = northPath(80);
  assert.ok(sameLine(a, northPath(80, 25)));
  assert.ok(!sameLine(a, northPath(80, 40)));
});

test('groups join through a shared member, and a line that can\'t be read is a group of its own', () => {
  const whole = path(120);
  const first = whole.slice(0, 50);
  const last = whole.slice(70);
  assert.ok(!sameLine(first, last));
  const groups = groupSuggestions([sugg('a', first), sugg('b', last), sugg('c', whole), sugg('x', null, { line: '!!' }), sugg('y', null, { line: '!!' })]);
  assert.equal(groups.length, 3);
  assert.deepEqual(groups.find((g) => g.members.length === 3).members.map((m) => m.recordName).sort(), ['a', 'b', 'c']);
});

// MARK: Caps and warnings

test('the caps are the spec\'s: 2,000 points, 20 km, 80-character name, 300-character note', () => {
  assert.deepEqual({ ...SUGGESTION_CAPS }, { points: 2000, meters: 20_000, name: 80, note: 300 });
  assert.ok(Object.isFrozen(SUGGESTION_CAPS));
});

test('a line over the point or length cap can\'t be the one accepted; the count is the line\'s, not the record\'s', () => {
  const many = Array.from({ length: 2001 }, (_, i) => at(i * 2, (i % 2) * 3));
  const s = suggestionOf(sugg('s', many, { pointCount: 10 }));
  assert.deepEqual(s.problems, ['points']);
  assert.ok(s.warnings.includes('mismatch'), 'the record said 10');
  assert.deepEqual(suggestionOf(sugg('s', many.slice(0, 2000))).problems, [], '2,000 is within the cap');
  const long = Array.from({ length: 300 }, (_, i) => at(0, i * 70));   // 20.93 km
  assert.deepEqual(suggestionOf(sugg('s', long)).problems, ['meters']);
  const justUnder = Array.from({ length: 286 }, (_, i) => at(0, i * 70));   // 19.95 km
  assert.deepEqual(suggestionOf(sugg('s', justUnder)).problems, []);
  // A text too long to be within the caps isn't decoded at all.
  assert.deepEqual(suggestionOf(sugg('s', null, { line: '?'.repeat(LINE_CHAR_LIMIT + 1) })).problems, ['lineTooLong']);
  assert.deepEqual(suggestionOf(sugg('s', null, { line: 'not a line' })).problems, ['unreadable']);
  assert.deepEqual(suggestionOf(sugg('s', [ORIGIN])).problems, ['unreadable'], 'one point is not a line');
});

test('name and note over the caps are flagged, counted as a person counts characters', () => {
  const family = '👨‍👩‍👧‍👦';
  assert.equal(textLength(family), 1);
  const line = path(60);
  assert.ok(!suggestionOf(sugg('s', line, { name: family.repeat(80) })).warnings.includes('name'), '80 characters is fine');
  assert.ok(suggestionOf(sugg('s', line, { name: 'x'.repeat(81) })).warnings.includes('name'));
  assert.ok(!suggestionOf(sugg('s', line, { note: 'x'.repeat(300) })).warnings.includes('note'));
  assert.ok(suggestionOf(sugg('s', line, { note: 'x'.repeat(301) })).warnings.includes('note'));
  assert.ok(suggestionOf(sugg('s', line, { name: '   ' })).warnings.includes('noName'));
  assert.ok(suggestionOf(sugg('s', line, { region: 'NC' })).warnings.includes('region'));
  assert.equal(suggestionOf(sugg('s', line, { name: '  Creek Path ' })).name, 'Creek Path');
});

test('very short, very long and straight-line stretches are warned about, and only then', () => {
  const ok = suggestionOf(sugg('s', path(60)));
  assert.deepEqual([...ok.problems, ...ok.warnings], [], 'an ordinary 1 km path has nothing to check');
  const short = Array.from({ length: 10 }, (_, i) => at(0, i * 30));   // 270 m
  assert.ok(suggestionOf(sugg('s', short)).warnings.includes('short'));
  assert.ok(!suggestionOf(sugg('s', Array.from({ length: 12 }, (_, i) => at(0, i * 30)))).warnings.includes('short'), '330 m');
  const long = Array.from({ length: 250 }, (_, i) => at((i % 2) * 10, i * 64));   // ~16 km
  assert.ok(suggestionOf(sugg('s', long)).warnings.includes('long'));
  assert.ok(!suggestionOf(sugg('s', long.slice(0, 200))).warnings.includes('long'));
  // A GPS gap: two points 600 m apart in the middle of a path.
  const gap = [...path(30), ...path(30, { east: 1000 })];
  const g = suggestionOf(sugg('s', gap));
  assert.ok(g.warnings.includes('straight'));
  assert.ok(g.longestStretch > STRAIGHT_STRETCH_M);
  assert.match(suggestionIssueText('straight', g), /^A straight stretch of \d+ m with no points/);
  assert.deepEqual([SHORT_SUGGESTION_M, LONG_SUGGESTION_M, STRAIGHT_STRETCH_M], [300, 15_000, 500]);
});

test('a record whose own length disagrees with its line is flagged; the page measures the line itself', () => {
  const line = path(60);
  const s = suggestionOf(sugg('s', line, { lengthMeters: 99_000 }));
  assert.ok(s.warnings.includes('mismatch'));
  assert.ok(Math.abs(s.lengthMeters - lineLength(line.map(round5))) < 0.01);
  assert.ok(suggestionOf(sugg('s', line, { lengthMeters: 'long' })).warnings.includes('mismatch'));
  assert.ok(!suggestionOf(sugg('s', line, { lengthMeters: lineLength(line) + 40 })).warnings.includes('mismatch'), 'within 50 m');
});

test('only the vocabulary\'s facts are kept, and liked is not one of a suggestion\'s', () => {
  assert.deepEqual(SUGGESTION_FACTS, ['dogs', 'stroller', 'wheelchair', 'surface']);
  const s = suggestionOf(sugg('s', path(60), { facts: { dogs: 'leashRequired', surface: 'lava', liked: 'up', stroller: 'yes', wheelchair: 'toString' } }));
  assert.deepEqual(s.facts, { dogs: 'leashRequired', stroller: 'yes' });
});

test('Accept uses the longest line within the caps, and re-checks the caps and the name itself', () => {
  const whole = path(100);
  const over = [...whole, ...Array.from({ length: 1950 }, (_, i) => at(1400 + (i % 2), 1400 + i * 0.2))];
  const groups = groupSuggestions([sugg('short', whole.slice(10, 60), { created: 1 }), sugg('whole', whole, { created: 2 }),
    sugg('over', over, { created: 3 })]);
  assert.deepEqual(groups.map((g) => g.members.map((m) => m.recordName)), [['short', 'whole'], ['over']],
    'an over-cap line is a group of its own: never compared, never used');
  assert.equal(groups[0].line.recordName, 'whole');
  assert.equal(groups[1].line, null);
  const plan = acceptPlan(groups[0], '  Creek Path ');
  assert.equal(plan.name, 'Creek Path');
  assert.equal(plan.recordName, 'whole');
  assert.deepEqual(plan.recordNames, ['short', 'whole'], 'every member leaves the queue');
  assert.throws(() => acceptPlan(groups[0], '  '), /needs a name/);
  assert.throws(() => acceptPlan(groups[0], 'x'.repeat(81)), /at most 80/);
  assert.doesNotThrow(() => acceptPlan(groups[0], 'x'.repeat(80)));
  // A page that hands over an over-cap line anyway is refused.
  const bad = groupSuggestions([sugg('over', over)])[0];
  assert.equal(bad.line, null);
  assert.throws(() => acceptPlan({ ...bad, line: bad.members[0] }, 'Creek Path'), /within the caps/);
  assert.throws(() => acceptPlan({ ...groups[0], line: { ...groups[0].line, problems: [], pointCount: 2001 } }, 'Creek Path'), /within the caps/);
  assert.throws(() => acceptPlan({ ...groups[0], line: { ...groups[0].line, problems: [], lengthMeters: 20_001 } }, 'Creek Path'), /within the caps/);
});

// MARK: Decisions and the queue

const decided = (action, recordNames, created) => ({ recordName: `act-${created}`, created,
  fields: { targetType: 'suggestion', action, snapshot: JSON.stringify({ recordNames }) } });

test('a suggestion is decided by an accepted or declined action newer than itself; groups are waiting, accepted or declined', () => {
  const line = path(60);
  const records = [sugg('s1', line, { created: 1 }), sugg('s2', line, { created: 2 }), sugg('t1', path(60, { north: 3000 }), { created: 3 })];
  assert.deepEqual(groupSuggestions(records).map((g) => g.state), ['waiting', 'waiting']);
  const accepted = groupSuggestions(records, [decided('accepted', ['s1', 's2'], 10), decided('declined', ['t1'], 11)]);
  assert.deepEqual(accepted.map((g) => [g.id, g.state, g.pending]).sort(), [['s1', 'accepted', 0], ['t1', 'declined', 0]]);
  // The name it was accepted as, from the newest acceptance.
  const named = (action, recordNames, created, name) => ({ ...decided(action, recordNames, created),
    fields: { targetType: 'suggestion', action, snapshot: JSON.stringify({ name, recordNames }) } });
  const renamed = groupSuggestions(records, [named('accepted', ['s1'], 10, 'Creek Path'), named('accepted', ['s2'], 12, 'Creek Path Trail'),
    named('declined', ['t1'], 13, 'Declined Name')]);
  assert.deepEqual(renamed.map((g) => g.acceptedName).sort(), ['', 'Creek Path Trail']);
  // A newer suggestion of an accepted path brings the group back, with the old members in it.
  const again = groupSuggestions([...records, sugg('s3', line, { created: 20 })], [decided('accepted', ['s1', 's2'], 10)]);
  const g = again.find((x) => x.id === 's1');
  assert.deepEqual([g.state, g.pending, g.members.length], ['waiting', 1, 3]);
  // An action older than the record (a record re-created under a decided name) decides nothing.
  assert.equal(groupSuggestions([sugg('s1', line, { created: 50 })], [decided('accepted', ['s1'], 10)])[0].state, 'waiting');
  // The latest decision wins.
  assert.equal(suggestionDecisions([decided('accepted', ['s1'], 10), decided('declined', ['s1'], 12)]).get('s1').action, 'declined');
  assert.equal(suggestionDecisions([decided('declined', ['s1'], 12), decided('accepted', ['s1'], 10)]).get('s1').action, 'declined');
  // Only suggestion actions count.
  assert.equal(suggestionDecisions([{ created: 5, fields: { targetType: 'trail', action: 'accepted', snapshot: JSON.stringify({ recordNames: ['s1'] }) } },
    { created: 5, fields: { targetType: 'contribution', action: 'declined', snapshot: JSON.stringify({ recordNames: ['s1'] }) } },
    { created: 6, fields: { targetType: 'suggestion', action: 'featured', snapshot: JSON.stringify({ recordNames: ['s1'] }) } },
    { created: 7, fields: { targetType: 'suggestion', action: 'accepted', snapshot: 'not json' } }]).size, 0);
});

test('waiting groups come first, most walkers first; a walker counts once however many suggestions they sent', () => {
  const one = path(60);
  const two = path(60, { north: 3000 });
  const groups = groupSuggestions([
    sugg('a1', one, { created: 5, submitter: 'suggester-1' }), sugg('a2', one, { created: 6, submitter: 'suggester-1' }),
    sugg('b1', two, { created: 1, submitter: 'suggester-2' }), sugg('b2', two, { created: 2, submitter: 'suggester-3' }),
    sugg('c1', path(60, { north: 6000 }), { created: 9 }),
  ], [decided('declined', ['c1'], 10)]);
  assert.deepEqual(groups.map((g) => [g.id, g.walkers, g.state]), [['b1', 2, 'waiting'], ['a1', 1, 'waiting'], ['c1', 1, 'declined']]);
});

test('facts are counted once per walker (their newest), and names by how many gave them', () => {
  const line = path(60);
  const [g] = groupSuggestions([
    sugg('a', line, { created: 1, submitter: 'suggester-1', facts: { dogs: 'noDogs' }, name: 'Mill Path' }),
    sugg('b', line, { created: 2, submitter: 'suggester-1', facts: { dogs: 'leashRequired' }, name: 'mill path' }),
    sugg('c', line, { created: 3, submitter: 'suggester-2', facts: { dogs: 'leashRequired', surface: 'paved' }, name: 'Creek Path', note: 'Muddy after rain' }),
  ]);
  assert.deepEqual(g.facts, { dogs: { leashRequired: 2 }, surface: { paved: 1 } });
  assert.equal(g.name, 'Mill Path');
  assert.deepEqual(g.names, [{ name: 'Mill Path', count: 2 }, { name: 'Creek Path', count: 1 }]);
  assert.deepEqual(g.notes.map((n) => n.note), ['Muddy after rain']);
});

test('suggestion actions never close a community report or a nomination with the same name', () => {
  for (const t of ['suggestion', 'trailSuggestions']) assert.ok(NON_ITEM_TARGETS.includes(t), t);
  const report = { recordName: 'r1', created: 1, fields: { targetRecordName: 's1', targetType: 'post', reason: 'spam' } };
  for (const action of ['accepted', 'declined']) {
    const a = { created: 5, fields: { targetRecordName: 's1', targetType: 'suggestion', action, snapshot: '{}' } };
    assert.equal(queue(groupReports([report], [a])).length, 1, action);
  }
  const nom = { recordName: 'n1', recordType: 'TrailNomination', created: 1,
    fields: { trailKey: 'nc:w1', trailName: 'Lake Loop', latitude: 35.78, longitude: -78.64 } };
  assert.equal(groupNominations([nom], [{ created: 5, fields: { targetRecordName: 'nc:w1', targetType: 'suggestion', action: 'accepted' } }])[0].open, true);
  for (const action of ['accepted', 'declined']) assert.ok(ACTIONS.includes(action));
  assert.ok(ACTIVITY_KINDS.some((k) => k.recordType === 'TrailSuggestion'));
});

// MARK: Statuses: who is told

test('a suggestion status says kind suggestion, status added, trailKey "suggestion" and when; no name, nothing else', () => {
  assert.equal(SUGGESTION_STATUS_TRAIL_KEY, 'suggestion');
  assert.ok(!isTrailKey(SUGGESTION_STATUS_TRAIL_KEY), 'never a pack key, so Unfeature can\'t meet it');
  assert.deepEqual(contributionStatusFields({ kind: 'suggestion', status: 'added', trailKey: 'suggestion', trailName: ' Creek Path ', decidedAt: NOW,
    claimToken: TOKEN, creator: CREATOR }),
  { kind: 'suggestion', status: 'added', trailKey: 'suggestion', decidedAt: { value: NOW, type: 'TIMESTAMP' } },
  'the name stays Moderator-only: the status is world-readable');
  assert.throws(() => contributionStatusFields({ kind: 'suggestion', status: 'added', trailKey: 'nc:w1', trailName: 'X', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'nomination', status: 'featured', trailKey: 'suggestion', trailName: 'X', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'suggestion', status: 'featured', trailKey: 'suggestion', trailName: 'X', decidedAt: NOW }));
  assert.throws(() => contributionStatusFields({ kind: 'suggestion', status: 'added', trailKey: 'suggestion', decidedAt: NaN }));
  // Unfeature withdraws only nomination statuses of its trail: a suggestion's is never touched.
  const s = { recordName: NAME_A, fields: { kind: 'suggestion', status: 'added', trailKey: 'suggestion' } };
  assert.deepEqual(statusesToWithdraw([s], 'suggestion'), []);
});

test('Accept tells every claim token in the group once, at most 5 per walker, newest first; the rest are counted', () => {
  assert.equal(TOKENS_PER_SUGGESTER, 5);
  const m = (name, created, statusName, submitter) => ({ recordName: name, created, statusName, submitter });
  const flood = Array.from({ length: 8 }, (_, i) => m(`f${i}`, 100 - i, `status.${String(i).repeat(64)}`, 'suggester-9'));
  const out = suggestionStatusNames([m('a', 1, NAME_A, 'suggester-1'), m('b', 2, NAME_B, 'suggester-1'), m('dup', 3, NAME_A, 'suggester-2'),
    m('none', 4, undefined, 'suggester-3'), m('bad', 5, 'status.short', 'suggester-3'), m('anon', 6, NAME_C, null), ...flood]);
  assert.deepEqual(out.names, [NAME_A, NAME_B, NAME_C, ...flood.slice(0, 5).map((f) => f.statusName)].sort());
  assert.equal(out.withoutToken, 2);
  assert.equal(out.capped, 3);
  assert.equal(acceptTellText(out), 'It tells 8 suggestions: each shows Added in My contributions on the device that sent it. '
    + 'Not told: 2 without a token, 3 over the 5-per-walker limit.');
  assert.equal(acceptTellText({ names: [NAME_A], withoutToken: 0, capped: 0 }),
    'It tells 1 suggestion: each shows Added in My contributions on the device that sent it.');
  assert.equal(acceptTellText({ names: [], withoutToken: 1, capped: 0 }), 'None of these can be told: none carries a claim token. Not told: 1 without a token.');
});

test('Accept writes History first, then a status per token, and nothing anyone else can read but the statuses', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('s1', line, { created: 1, statusName: NAME_B, submitter: 'suggester-1' }),
    sugg('s2', line, { created: 2, statusName: NAME_A, submitter: 'suggester-2' }), sugg('s3', line, { created: 3 })]);
  const store = fakeStore();
  const { plan, told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', note: 'Looks right', now: NOW });
  assert.deepEqual(told, { written: 2, planned: 2, blocked: 0, withoutToken: 1, capped: 0, error: null });
  assert.deepEqual(store.calls.map((c) => [c[0], c[1]]), [['create', 'ModerationAction'], ['query', 'ContributionStatus'], ['fetch', [NAME_A, NAME_B]],
    ['create', 'ModerationAction'], ['createNamed', 'ContributionStatus'], ['createNamed', 'ContributionStatus']]);
  assert.deepEqual(store.calls[1][2], { equals: ['trailKey', 'suggestion'], max: 1 }, 'the schema check before the first write');
  const [accepted, toldAction] = history(store);
  assert.deepEqual(accepted, actionFields({ target: plan.recordName, type: 'suggestion', action: 'accepted', note: 'Looks right', reportCount: 3,
    snapshot: JSON.stringify({ name: 'Creek Path', region: 'nc', lengthMeters: Math.round(group.line.lengthMeters), pointCount: 60,
      recordName: 's1', recordNames: ['s1', 's2', 's3'], count: 3 }) }));
  assert.deepEqual(toldAction, actionFields({ target: 's1', type: 'contribution', action: 'statusPublished', reportCount: 2,
    snapshot: JSON.stringify({ trailKey: 'suggestion', trailName: 'Creek Path', kind: 'suggestion', status: 'added', count: 2, blocked: 0 }) }));
  for (const c of statusWrites(store)) {
    assert.deepEqual(c[3], { kind: 'suggestion', status: 'added', trailKey: 'suggestion', decidedAt: { value: NOW, type: 'TIMESTAMP' } });
  }
  assert.deepEqual(writtenTypes(store), ['ContributionStatus', 'ModerationAction'], 'no CommunityTrail, nothing public but the statuses');
  assert.ok(!JSON.stringify(history(store)).includes('status.'), 'History holds no status name');
});

test('a group with no tokens is accepted and tells no one, with no error and no status History', async () => {
  const [group] = groupSuggestions([sugg('s1', path(60))]);
  const store = fakeStore();
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual(told, { written: 0, planned: 0, blocked: 0, withoutToken: 1, capped: 0, error: null });
  assert.deepEqual(history(store).map((h) => h.action), ['accepted']);
  assert.ok(!store.calls.some((c) => c[1] === 'ContributionStatus'));
});

test('Accept refuses a name or line over the caps before writing anything', async () => {
  const [group] = groupSuggestions([sugg('s1', path(60), { statusName: NAME_A })]);
  for (const name of ['', 'x'.repeat(81)]) {
    const store = fakeStore();
    await assert.rejects(acceptSuggestionsAndTell(store, { group, name, now: NOW }));
    assert.deepEqual(store.calls, [], JSON.stringify(name));
  }
  const store = fakeStore();
  await assert.rejects(acceptSuggestions(store, { group: { ...group, line: null }, name: 'Creek Path' }), /within the caps/);
  assert.deepEqual(store.calls, []);
});

test('where the schema has no ContributionStatus, Accept stands and nothing is written to the missing type', async () => {
  const [group] = groupSuggestions([sugg('s1', path(60), { statusName: NAME_A })]);
  const missing = { serverErrorCode: 'BAD_REQUEST', reason: 'did not find record type: ContributionStatus' };
  const store = fakeStore({ failStatusQuery: missing });
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.equal(told.error, missing);
  assert.deepEqual(history(store).map((h) => h.action), ['accepted'], 'the decision stands; no status History');
  assert.ok(!store.calls.some((c) => ['createNamed', 'replaceNamed', 'fetch'].includes(c[0])));
  assert.match(suggestionToldText(told), /^Couldn't tell the walkers: CloudKit error BAD_REQUEST: did not find record type: ContributionStatus\. To finish, show Accepted and Accept it again\.$/);
});

test('one status that fails doesn\'t stop the rest, and History says how many were written; all failing takes it back', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('s1', line, { statusName: NAME_A }), sugg('s2', line, { statusName: NAME_B }),
    sugg('s3', line, { statusName: NAME_C })]);
  const store = fakeStore({ failWriteNames: [NAME_A] });
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual([told.written, told.planned, told.error.ckErrorCode], [2, 3, 'SERVER_RECORD_CHANGED']);
  assert.deepEqual(statusWrites(store).map((c) => c[2]), [NAME_A, NAME_B, NAME_C], 'every one tried');
  const fix = store.calls.find((c) => c[0] === 'replaceNamed' && c[1] === 'ModerationAction');
  assert.equal(fix[2], 'act2', 'the status action is corrected, not the decision');
  assert.deepEqual(fix[3], {
    ...actionFields({ target: 's1', type: 'contribution', action: 'statusPublished', reportCount: 3, snapshot: '' }),
    reportCount: 2, note: 'Stopped part-way: 2 of 3 written.',
    snapshot: JSON.stringify({ trailKey: 'suggestion', trailName: 'Creek Path', kind: 'suggestion', status: 'added', count: 2, blocked: 0, planned: 3 }),
  });
  assert.equal(suggestionToldText(told), 'Told 2 of 3 suggestions; the rest failed: CloudKit error SERVER_RECORD_CHANGED: [object Object]. '
    + 'To finish, show Accepted and Accept it again.');

  const all = fakeStore({ failWriteAt: 1 });
  const out = await acceptSuggestionsAndTell(all, { group, name: 'Creek Path', now: NOW });
  assert.equal(out.told.error.ckErrorCode, 'NETWORK_ERROR');
  assert.deepEqual(all.calls.filter((c) => c[0] === 'delete'), [['delete', ['act2']]], 'the status action taken back; the decision (act1) stays');
});

test('a status name already used by another record is skipped and counted, and can\'t stop the others', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('s1', line, { statusName: NAME_A }), sugg('s2', line, { statusName: NAME_B })]);
  const store = fakeStore({ existing: new Map([[NAME_A, { recordName: NAME_A, recordType: 'TrailSuggestion', fields: {} }]]) });
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual([told.written, told.blocked], [1, 1]);
  assert.deepEqual(statusWrites(store).map((c) => c[2]), [NAME_B]);
  assert.match(suggestionToldText(told), /^Told 1 suggestion\. 1 couldn't be told: another record already has that name/);
});

test('Accepting a group that came back tells every device in it, the ones decided before included', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('s1', line, { created: 1, statusName: NAME_A }), sugg('s2', line, { created: 2, statusName: NAME_B }),
    sugg('s3', line, { created: 20, statusName: NAME_C })], [decided('declined', ['s1'], 10), decided('accepted', ['s2'], 11)]);
  assert.deepEqual([group.state, group.pending], ['waiting', 1]);
  const store = fakeStore();
  await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual(statusWrites(store).map((c) => c[2]), [NAME_A, NAME_B, NAME_C], 'the same path: the walker declined before is told too');
  assert.deepEqual(JSON.parse(history(store)[0].snapshot).recordNames, ['s1', 's2', 's3']);
});

test('Accept again rewrites the same statuses and keeps when they were first decided', async () => {
  const [group] = groupSuggestions([sugg('s1', path(60), { statusName: NAME_A })]);
  const existing = new Map([[NAME_A, { recordName: NAME_A, recordType: 'ContributionStatus',
    fields: { kind: 'suggestion', status: 'added', trailKey: 'suggestion', decidedAt: 5 } }]]);
  const store = fakeStore({ existing });
  await publishSuggestionStatuses(store, { group, name: 'Creek Path', target: 's1', now: NOW });
  assert.deepEqual(statusWrites(store).map((c) => [c[0], c[2], c[3].decidedAt.value]), [['replaceNamed', NAME_A, 5]]);
});

test('Decline records the decision for every member and tells no one: no status, no lookup', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('s1', line, { statusName: NAME_A }), sugg('s2', line, { statusName: NAME_B })]);
  const store = fakeStore();
  const plan = await declineSuggestions(store, { group, note: 'A sidewalk' });
  assert.deepEqual(store.calls, [['create', 'ModerationAction', actionFields({ target: 's1', type: 'suggestion', action: 'declined',
    note: 'A sidewalk', reportCount: 2, snapshot: JSON.stringify({ name: 'Creek Path', recordNames: ['s1', 's2'], count: 2 }) })]]);
  assert.deepEqual(plan.recordNames, ['s1', 's2']);
  assert.throws(() => declinePlan({ members: [] }));
});

// MARK: History and the page's words

test('History reads a decision or a deletion in words, from counts', () => {
  const f = (targetType, snapshot, reportCount = 0) => ({ targetType, snapshot: JSON.stringify(snapshot), reportCount });
  assert.equal(suggestionHistoryText(f('suggestion', { name: 'Creek Path', recordNames: ['a', 'b', 'c'], count: 3 })), 'Creek Path · 3 suggestions');
  assert.equal(suggestionHistoryText(f('suggestion', { name: '', count: 1 })), '1 suggestion');
  assert.equal(suggestionHistoryText(f('trailSuggestions', { count: 4 })), '4 suggestions deleted at the walker\'s request');
  assert.equal(suggestionHistoryText(f('trailSuggestions', {}, 2)), '2 suggestions deleted at the walker\'s request');
  assert.equal(suggestionHistoryText({ targetType: 'suggestion', snapshot: '{' }), '');
});

test('every warning and problem code has words of its own', () => {
  const s = { pointCount: 2001, lengthMeters: 21_000, longestStretch: 612 };
  const codes = ['unreadable', 'lineTooLong', 'points', 'meters', 'short', 'long', 'straight', 'mismatch', 'noName', 'name', 'note', 'region'];
  const texts = codes.map((c) => suggestionIssueText(c, s));
  assert.equal(new Set(texts).size, codes.length);
  for (const [i, t] of texts.entries()) assert.notEqual(t, codes[i], codes[i]);
  assert.equal(suggestionIssueText('points', s), 'Over the caps: more than 2,000 points.');
  assert.match(suggestionIssueText('meters', s), /21 km \(13 mi\) long \(at most 20 km/);
});

// MARK: Links, drawing and GPX

test('the start point\'s Maps and OpenStreetMap editor links are built from the numbers only', () => {
  assert.equal(osmEditLink(35.78, -78.64), 'https://www.openstreetmap.org/edit#map=18/35.78000/-78.64000');
  assert.equal(osmEditLink(91, 0), null);
  assert.equal(osmEditLink(NaN, 0), null);
  assert.equal(osmEditLink('35', '-78'), null);
  assert.equal(mapsLink(35.78, -78.64, 'Creek & "Path"'), 'https://maps.apple.com/?ll=35.78000,-78.64000&q=Creek%20%26%20%22Path%22');
});

test('several lines are drawn at one scale, and one line draws exactly as routePath does', () => {
  const a = [{ latitude: 35, longitude: -78 }, { latitude: 35.01, longitude: -78 }];
  const b = [{ latitude: 35, longitude: -78 }, { latitude: 35.02, longitude: -78 }];
  assert.equal(routePaths([a], 160, 120, 10).paths[0], routePath(a, 160, 120, 10));
  const { paths, at: place } = routePaths([a, b, [a[0]]], 160, 120, 10);
  assert.equal(paths[1], 'M80.0 110.0 L80.0 10.0');
  assert.equal(paths[0], 'M80.0 110.0 L80.0 60.0', 'half as long, in the same box');
  assert.equal(paths[2], '', 'one point draws nothing');
  assert.deepEqual(place(a[0]), { x: '80.0', y: '110.0' });
  assert.equal(routePaths([[a[0]], []]).at, null);
});

test('GPX holds the line and the name, escaped, and nothing else', () => {
  const gpx = gpxDocument('Creek & <Mill> "Path"\u0001', [{ latitude: 35.78, longitude: -78.64 }, { latitude: 35.781234, longitude: -78.6412345 }]);
  assert.equal(gpx, '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<gpx version="1.1" creator="Wockett Staff" xmlns="http://www.topografix.com/GPX/1/1">\n'
    + '  <metadata><name>Creek &amp; &lt;Mill&gt; &quot;Path&quot;</name></metadata>\n'
    + '  <trk>\n    <name>Creek &amp; &lt;Mill&gt; &quot;Path&quot;</name>\n    <trkseg>\n'
    + '      <trkpt lat="35.78000" lon="-78.64000"/>\n      <trkpt lat="35.78123" lon="-78.64123"/>\n'
    + '    </trkseg>\n  </trk>\n</gpx>\n');
  assert.throws(() => gpxDocument('x', [{ latitude: 1, longitude: 1 }]));
  assert.equal(gpxFileName('Creek & Mill Path!'), 'wockett-suggestion-creek-mill-path.gpx');
  assert.equal(gpxFileName('../../etc/passwd'), 'wockett-suggestion-etc-passwd.gpx');
  assert.equal(gpxFileName('Café Trail'), 'wockett-suggestion-cafe-trail.gpx');
  assert.equal(gpxFileName('🌲'), 'wockett-suggestion.gpx');
  assert.match(gpxFileName('x'.repeat(200)), /^wockett-suggestion-x{40}\.gpx$/);
});

// MARK: ck.js keeps the token and the account

/** `suggestion.<UUID>` for a short tag, as the app names suggestions (a fixed UUID per tag). */
const SN = (tag) => {
  const h = sha(tag);
  return `suggestion.${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
/** A raw CloudKit JS suggestion; `tag` becomes its `suggestion.<UUID>` name unless `recordName` is given. */
const rawSugg = (tag, points, { token, who = CREATOR, created = 1, name = 'Creek Path', recordName = SN(tag) } = {}) => ({
  recordName, recordType: 'TrailSuggestion', created: { timestamp: created, userRecordName: who },
  fields: { name: { value: name }, note: { value: '' }, region: { value: 'nc' }, line: { value: encode(points) },
    pointCount: { value: points.length }, lengthMeters: { value: lineLength(points.map(round5)) },
    ...(token === undefined ? {} : { claimToken: { value: token } }) },
});

test('a suggestion reaches the page with its status name and a page-load walker token, never its claim token or account', async () => {
  const line = path(60);
  const db = { async performQuery() {
    return { records: [rawSugg('1', line, { token: TOKEN }), rawSugg('2', line, { token: TOKEN2 }),
      rawSugg('3', line, { who: OTHER }), rawSugg('4', line, { token: 'junk', who: OTHER })], moreComing: false };
  } };
  const { records, hidden } = await pagedQuery(db, { recordType: 'TrailSuggestion' });
  assert.equal(hidden, 0);
  assert.deepEqual(records.map((r) => r.statusName), [TOKEN_NAME, `status.${sha(TOKEN2)}`, undefined, undefined]);
  assert.equal(records[0].submitter, records[1].submitter, 'one person, one token');
  assert.notEqual(records[0].submitter, records[2].submitter);
  assert.match(records[0].submitter, /^suggester-\d+$/);
  for (const secret of [TOKEN, TOKEN2, CREATOR, OTHER, 'claimToken']) assert.ok(!JSON.stringify(records).includes(secret), secret);
  assert.equal(records[0].creator, undefined);
  assert.equal(plain(rawSugg('x', line, { token: TOKEN })).fields.claimToken, undefined);
});

test('a suggestion whose record name holds its own token or account never reaches the page, and is counted', async () => {
  const line = path(60);
  const leaky = [
    rawSugg('x', line, { token: TOKEN, recordName: `suggestion.${TOKEN.toLowerCase()}` }),   // its own token
    rawSugg('x', line, { token: TOKEN, recordName: `suggestion.${TOKEN}` }),                 // the same, as Swift writes it
    rawSugg('x', line, { token: TOKEN2, recordName: `s.${CREATOR}` }),                       // its account
    rawSugg('x', line, { token: TOKEN2, recordName: `suggestion.${CREATOR.toUpperCase()}` }),
    rawSugg('x', line, { token: TOKEN2, recordName: `suggestion.${OTHER}` }),                // someone else's account
    rawSugg('x', line, { token: TOKEN2, recordName: `status.${sha(TOKEN2)}` }),               // a status name
    rawSugg('x', line, { token: TOKEN2, recordName: `suggestion.${TOKEN2.replace(/-/g, '')}` }),
    rawSugg('x', line, { token: TOKEN2, recordName: `${SN('ok')}x` }),
  ];
  const fine = [rawSugg('ok', line, { token: TOKEN3 }), rawSugg('upper', line, { token: TOKEN3, recordName: SN('upper').toUpperCase().replace('SUGGESTION', 'suggestion') }),
    rawSugg('empty', line, { token: '' }), rawSugg('none', line)];
  assert.deepEqual(leaky.map(nameLeaks), leaky.map(() => true));
  assert.deepEqual(fine.map(nameLeaks), fine.map(() => false), 'suggestion.<UUID> in either case, with any or no token, is fine');
  const db = { async performQuery() { return { records: [...leaky, ...fine], moreComing: false }; } };
  const { records, hidden } = await pagedQuery(db, { recordType: 'TrailSuggestion' });
  assert.deepEqual(records.map((r) => r.recordName), fine.map((r) => r.recordName));
  assert.equal(hidden, leaky.length);
  // Decline writes only what reached the page into History.
  const store = fakeStore();
  await declineSuggestions(store, { group: groupSuggestions(records)[0] });
  for (const r of leaky) assert.ok(!JSON.stringify(store.calls).includes(r.recordName), r.recordName);
  // Finding one account's suggestions to delete them still finds them: deleting writes only a count.
  const mine = await pagedQuery(db, { recordType: 'TrailSuggestion' }, { onlyCreator: CREATOR });
  assert.equal(mine.records.length, leaky.length + fine.length, 'all of them are CREATOR\'s, and all can be deleted');
});

// MARK: Removal on request

test('finding a walker\'s suggestions refuses a bad identifier before asking CloudKit', async () => {
  const bad = fakeStore();
  await assert.rejects(findSuggestionsBy(bad, { identifier: 'bob@example.com' }), /isn't a Wockett identifier/);
  assert.deepEqual(bad.calls, []);
  const store = fakeStore({ found: [{ recordName: 's1', recordType: 'TrailSuggestion', created: 1 }] });
  const out = await findSuggestionsBy(store, { identifier: ` ${CREATOR} ` });
  assert.deepEqual(store.calls[0].slice(0, 3), ['queryByCreator', 'TrailSuggestion', CREATOR]);
  assert.equal(out.records.length, 1);
});

test('deleting a walker\'s suggestions writes History with the count only, then deletes only suggestions, 200 at a time', async () => {
  const records = Array.from({ length: 250 }, (_, i) => ({ recordName: `s${i}`, recordType: 'TrailSuggestion', created: i }));
  const store = fakeStore();
  const out = await deleteSuggestionsBy(store, { account: CREATOR, records: [...records, { recordName: NAME_A, recordType: 'ContributionStatus' }] });
  assert.deepEqual(out, { deleted: 250, error: null });
  assert.deepEqual(history(store), [actionFields({ target: 'TrailSuggestion', type: 'trailSuggestions', action: 'erased', reportCount: 250,
    snapshot: JSON.stringify({ count: 250 }) })]);
  assert.ok(!JSON.stringify(store.calls).includes(CREATOR), 'no identifier in History');
  const deleted = store.calls.filter((c) => c[0] === 'delete').map((c) => c[1]);
  assert.deepEqual(deleted.map((d) => d.length), [200, 50]);
  assert.ok(!deleted.flat().includes(NAME_A), 'a status is never deleted with them');
  assert.deepEqual(await deleteSuggestionsBy(fakeStore(), { records: [] }), { deleted: 0, error: null });
});

test('a deletion that fails part-way keeps History with the number really deleted; a first failure takes it back', async () => {
  const records = Array.from({ length: 300 }, (_, i) => ({ recordName: `s${i}`, recordType: 'TrailSuggestion', created: i }));
  const later = fakeStore({ failDeleteAt: 2, partly: 30 });
  const out = await deleteSuggestionsBy(later, { records });
  assert.equal(out.deleted, 230);
  const fix = later.calls.find((c) => c[0] === 'replaceNamed')[3];
  assert.deepEqual([fix.reportCount, fix.action, fix.targetType, fix.note], [230, 'erased', 'trailSuggestions', 'Stopped part-way: 230 of 300 deleted.']);
  assert.deepEqual(JSON.parse(fix.snapshot), { count: 230, planned: 300 });
  const first = fakeStore({ failDeleteAt: 1 });
  await assert.rejects(deleteSuggestionsBy(first, { records }));
  assert.deepEqual(first.calls.at(-1), ['delete', ['act1']]);
});

// MARK: End to end through ck.js

/** CloudKit JS's public database, in memory, logging every save. A save of a name in `failNames` fails. */
function fakeCloudKit(records, { failNames = [] } = {}) {
  const byName = new Map(records.map((r) => [r.recordName, r]));
  const saved = [];
  const deleted = [];
  let auto = 0;
  const save = (r) => {
    const rec = { ...r, recordName: r.recordName ?? `auto-${++auto}`, created: { timestamp: NOW + auto, userRecordName: '_moderator0000000000' } };
    saved.push(rec);
    byName.set(rec.recordName, rec);
    return rec;
  };
  const db = {
    async performQuery(query) {
      const eq = query.filterBy?.find((f) => f.fieldName);
      const by = query.filterBy?.find((f) => f.systemFieldName === 'createdUserRecordName');
      const found = [...byName.values()].filter((r) => r.recordType === query.recordType
        && (!eq || r.fields?.[eq.fieldName]?.value === eq.fieldValue.value)
        && (!by || r.created?.userRecordName === by.fieldValue.value.recordName));
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
    async deleteRecords(names) { for (const n of names) { deleted.push(n); byName.delete(n); } return { records: names.map((recordName) => ({ recordName })) }; },
  };
  return { saved, deleted, byName, CloudKit: { configure() {}, getDefaultContainer() { return { publicCloudDatabase: db }; } } };
}

test('end to end: Accept tells each device once, and no token, account or status name reaches History, the page or a GPX', async () => {
  const line = path(80);
  // CREATOR suggested the path from two devices; OTHER once; someone before tokens existed; and a different path.
  const cloud = fakeCloudKit([
    rawSugg('a', line, { token: TOKEN, created: 1 }),
    rawSugg('b', [...path(80, { jitter: 6, seed: 9 })].reverse(), { token: TOKEN3, created: 2, name: 'creek path' }),
    rawSugg('c', path(80, { jitter: 6, seed: 4 }), { token: TOKEN2, who: OTHER, created: 3, name: 'Old Mill Trail' }),
    rawSugg('d', line.slice(0, 40), { who: '_z000000000000000', created: 4 }),
    rawSugg('e', path(80, { north: 4000 }), { token: '11111111-2222-4333-8444-555555555555', who: OTHER, created: 5 }),
  ]);
  const store = connect({ CloudKit: cloud.CloudKit });
  const { records } = await store.query('TrailSuggestion', { max: 2000 });
  const groups = groupSuggestions(records);
  assert.equal(groups.length, 2);
  const group = groups.find((g) => g.members.length === 4);
  assert.equal(group.walkers, 3);
  assert.equal(suggestionStatusNames(group.members).names.length, 3);
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual([told.written, told.withoutToken], [3, 1]);
  const statuses = cloud.saved.filter((r) => r.recordType === 'ContributionStatus');
  assert.deepEqual(statuses.map((r) => r.recordName).sort(), [TOKEN_NAME, `status.${sha(TOKEN2)}`, `status.${sha(TOKEN3)}`].sort());
  for (const r of statuses) {
    assert.deepEqual(Object.keys(r.fields).sort(), ['decidedAt', 'kind', 'status', 'trailKey']);
    assert.deepEqual([r.fields.kind.value, r.fields.status.value, r.fields.trailKey.value], ['suggestion', 'added', 'suggestion']);
  }
  assert.deepEqual([...new Set(cloud.saved.map((r) => r.recordType))].sort(), ['ContributionStatus', 'ModerationAction'], 'no CommunityTrail');
  // Nothing of the suggestion itself is in a record everyone can read: no name given or accepted, no note, no line.
  for (const text of ['Creek Path', 'creek path', 'Old Mill Trail', encode(line), SN('a')]) {
    assert.ok(!JSON.stringify(statuses).includes(text), `${text} reached a world-readable status`);
  }
  const actions = cloud.saved.filter((r) => r.recordType === 'ModerationAction');
  assert.deepEqual(actions.map((r) => r.fields.action.value), ['accepted', 'statusPublished']);
  const secrets = [TOKEN, TOKEN2, TOKEN3, TOKEN.toLowerCase(), CREATOR, OTHER, '_z000000000000000', 'claimToken'];
  for (const secret of secrets) {
    assert.ok(!JSON.stringify(cloud.saved).includes(secret), `${secret} reached CloudKit`);
    assert.ok(!JSON.stringify(records).includes(secret), `${secret} reached the page`);
    assert.ok(!gpxDocument(group.name, group.line.line).includes(secret), `${secret} reached the GPX`);
  }
  for (const name of [TOKEN_NAME, sha(TOKEN), sha(TOKEN2), sha(TOKEN3)]) assert.ok(!JSON.stringify(actions).includes(name), 'History holds counts, not status names');
  assert.deepEqual(JSON.parse(actions[0].fields.snapshot.value).recordNames, [SN('a'), SN('b'), SN('c'), SN('d')]);

  // After Accept, the group has left the queue, and the other path is still waiting.
  const { records: actionRecords } = await store.query('ModerationAction');
  const after = groupSuggestions(records, actionRecords);
  assert.deepEqual(after.map((g) => [g.members.length, g.state]), [[1, 'waiting'], [4, 'accepted']]);

  // Declining the other path writes one action and no status.
  const before = cloud.saved.length;
  await declineSuggestions(store, { group: after[0] });
  assert.deepEqual(cloud.saved.slice(before).map((r) => [r.recordType, r.fields.action.value]), [['ModerationAction', 'declined']]);

  // A removal request for OTHER deletes their two suggestions and nothing else; History keeps the count.
  const found = await findSuggestionsBy(store, { identifier: OTHER });
  assert.deepEqual(found.records.map((r) => r.recordName).sort(), [SN('c'), SN('e')]);
  assert.ok(!JSON.stringify(found.records).includes(OTHER));
  const out = await deleteSuggestionsBy(store, found);
  assert.deepEqual(out, { deleted: 2, error: null });
  assert.deepEqual(cloud.deleted.sort(), [SN('c'), SN('e')]);
  assert.equal(cloud.byName.get(`status.${sha(TOKEN2)}`).recordType, 'ContributionStatus', 'their Added status stays');
  for (const secret of secrets) assert.ok(!JSON.stringify(cloud.saved).includes(secret), `${secret} reached History`);
});

test('end to end: one of a walker\'s two devices failing still tells the other, and History says 1 of 2', async () => {
  const line = path(60);
  const cloud = fakeCloudKit([rawSugg('a', line, { token: TOKEN }), rawSugg('b', line, { token: TOKEN3, created: 2 })],
    { failNames: [TOKEN_NAME] });
  const store = connect({ CloudKit: cloud.CloudKit });
  const { records } = await store.query('TrailSuggestion');
  const [group] = groupSuggestions(records);
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual([told.written, told.planned, told.error?.ckErrorCode], [1, 2, 'NETWORK_ERROR']);
  assert.ok(TOKEN_NAME < `status.${sha(TOKEN3)}`, 'the failing one is written first');
  const toldAction = cloud.byName.get(cloud.saved.find((r) => r.fields?.action?.value === 'statusPublished').recordName);
  assert.equal(toldAction.fields.reportCount.value, 1);
  assert.equal(toldAction.fields.note.value, 'Stopped part-way: 1 of 2 written.');
  for (const secret of [TOKEN, TOKEN3, CREATOR, sha(TOKEN), sha(TOKEN3)]) assert.ok(!JSON.stringify(toldAction).includes(secret), secret);
});

// MARK: Critic and test-auditor run 1 (2026-10-16)

/** Points every `step` metres from `from` to `to` (each an [east, north] in metres). */
function seg(from, to, step = 20) {
  const n = Math.max(1, Math.round(Math.hypot(to[0] - from[0], to[1] - from[1]) / step));
  return Array.from({ length: n + 1 }, (_, i) => at(from[0] + ((to[0] - from[0]) * i) / n, from[1] + ((to[1] - from[1]) * i) / n));
}

test('a short walk on a stretch two paths share joins one of them, never both into one group', () => {
  const shared = seg([0, 0], [0, 400]);
  const a = [...seg([-3000, 0], [0, 0]), ...shared.slice(1)];
  const b = [...shared, ...seg([0, 400], [3000, 400]).slice(1)];
  assert.ok(!sameLine(a, b));
  assert.ok(sameLine(shared, a) && sameLine(shared, b), 'the short one lies along both');
  const groups = groupSuggestions([sugg('a', a, { created: 1, statusName: NAME_A }), sugg('b', b, { created: 2, statusName: NAME_B }),
    sugg('c', shared, { created: 3, statusName: NAME_C })]);
  assert.equal(groups.length, 2);
  const withC = groups.filter((g) => g.members.some((m) => m.recordName === 'c'));
  assert.equal(withC.length, 1);
  assert.equal(withC[0].members.length, 2);
  // Accepting the group with C tells C and that group's own walker, never the other path's.
  const told = suggestionStatusNames(withC[0].members).names;
  assert.equal(told.length, 2);
  assert.ok(told.includes(NAME_C) && !(told.includes(NAME_A) && told.includes(NAME_B)));
});

test('the share turns at exactly 60%, sampled every 25 m, within exactly the tolerance', () => {
  // 99 m sampled at 0, 25, 50, 75, 99: three of five within 30 m of a line ending at 30 m.
  assert.equal(overlapShare([at(0, 0), at(0, 99)], [at(0, -200), at(0, 30)]), 0.6);
  assert.ok(sameLine([at(0, 0), at(0, 99)], [at(0, -200), at(0, 30)]));
  assert.ok(!sameLine([at(0, 0), at(0, 100)], [at(0, -200), at(0, 30)]), '0.5');
  // The same with the near samples last: the early exit must not give up one sample too soon.
  assert.ok(sameLine([at(0, 99), at(0, 0)], [at(0, -200), at(0, 30)]));
  assert.ok(!sameLine([at(0, 110), at(0, 0)], [at(0, -200), at(0, 30)]), '0.5');
  const a = [at(0, 0), at(0, 220)];
  assert.ok(sameLine(a, [at(0, -2000), at(0, 105), at(3000, 105)]), '0.6');
  assert.ok(!sameLine(a, [at(0, -2000), at(0, 80), at(3000, 80)]), '0.5');
  assert.ok(sameLine(northPath(80), northPath(80, 28)));
  assert.ok(sameLine(northPath(80), northPath(80, 29.5)), 'within 30 m counts, right up to it');
  assert.ok(!sameLine(northPath(80), northPath(80, 30.5)));
  assert.ok(!sameLine(northPath(80), northPath(80, 32)));
  // Sampled along the line, not just at its points: a V touches the straight line only at its ends.
  assert.ok(!sameLine([at(0, 0), at(0, 1000)], [at(0, -10), at(600, 500), at(0, 1010)]));
});

test('grouping stays fast: crafted over-cap lines are never compared, and 20 long overlapping lines group in seconds, not minutes', () => {
  const huge = (k) => sugg(`huge${k}`, null, { line: encode(Array.from({ length: 9001 }, (_, i) => at((i % 2) * 600 + k, i * 600))) });
  let t = performance.now();
  const crafted = groupSuggestions([huge(0), huge(5), huge(10)]);
  assert.equal(crafted.length, 3);
  // Generous for a busy CI runner: before these were bounded, this took over 100 s.
  assert.ok(performance.now() - t < 5000, `${Math.round(performance.now() - t)} ms`);
  // 20 lines of 2,000 points, ~15 km each, all in one box, 60 m apart: every pair is checked and differs.
  const lines = Array.from({ length: 20 }, (_, k) => sugg(`l${k}`, Array.from({ length: 2000 }, (_, i) => at(i * 7.4, k * 60 + 20 * Math.sin(i / 30)))));
  t = performance.now();
  const groups = groupSuggestions(lines);
  const ms = performance.now() - t;
  assert.equal(groups.length, 20);
  assert.ok(ms < 10_000, `${Math.round(ms)} ms (about 0.2 s alone; it took 19 s before early exit and the grid)`);
});

test('a long straight segment costs an index as long as it is, not as big as the area it spans (critic run 2)', () => {
  // 19.8 km on the diagonal in two points: filed by area this was about 225,000 entries.
  const diagonal = lineIndex([at(0, 0), at(14_000, 14_000)], OVERLAP_TOLERANCE_M);
  assert.ok(diagonal.entries <= 15_000, `${diagonal.entries} entries`);
  assert.ok(diagonal.near({ x: 7000 * 1.0, y: 7000 * 1.0 }), 'still finds the line in the middle');
  const straight = lineIndex([at(0, 0), at(0, 19_800)], OVERLAP_TOLERANCE_M);
  assert.ok(straight.entries <= 15_000, `${straight.entries} entries`);
});

test('grouping has a hard ceiling: past the budget the rest are shown ungrouped, never lost', () => {
  const line = path(60);
  const records = Array.from({ length: 6 }, (_, k) => sugg(`s${k}`, line, { created: k }));
  const all = groupSuggestions(records);
  assert.equal(all.length, 1);
  const tight = groupSuggestions(records, [], 1);
  assert.equal(tight.reduce((n, g) => n + g.members.length, 0), 6, 'every suggestion still shown');
  assert.ok(tight.some((g) => g.ungrouped) && tight.length > 1);
  // The critic's worst shapes, at full size: they finish, and every suggestion is on the page.
  const diag = Array.from({ length: 60 }, (_, k) => sugg(`d${k}`, [at(k * 100, 0), at(k * 100 + 14_000, 14_000)], { created: k }));
  const star = Array.from({ length: 300 }, (_, k) => {
    const a = (k / 300) * Math.PI;
    return sugg(`x${k}`, Array.from({ length: 200 }, (_, i) => at(Math.cos(a) * (i * 70 - 7000), Math.sin(a) * (i * 70 - 7000))), { created: k });
  });
  for (const [label, set] of [['diagonal', diag], ['star', star]]) {
    const t = performance.now();
    const groups = groupSuggestions(set);
    const ms = performance.now() - t;
    assert.equal(groups.reduce((n, g) => n + g.members.length, 0), set.length, label);
    assert.ok(ms < 10_000, `${label}: ${Math.round(ms)} ms (about 0.4 s alone; 15 s and 2.9 GB for 60 diagonals before)`);
  }
});

test('the decoder refuses a value too long to be a coordinate, and never yields NaN', () => {
  for (const bad of ['_'.repeat(220) + '??' + '_ibE_ibE_ibE_ibE', `${'_'.repeat(210)}??????`, '~~~~~~~~~??', '______[?',
    `${encode([{ latitude: 1, longitude: 1 }, { latitude: 1.1, longitude: 1.1 }])}\u007f??`]) {
    assert.equal(decodePolyline(bad), null, JSON.stringify(bad.slice(0, 20)));
  }
  // Six chunks is enough for any coordinate: a delta of the whole globe still decodes.
  assert.deepEqual(decodePolyline(encode([{ latitude: -90, longitude: -180 }, { latitude: 90, longitude: 180 }])),
    [{ latitude: -90, longitude: -180 }, { latitude: 90, longitude: 180 }]);
});

test('the mismatch rule is 50 m or 10%, whichever is more, and a missing or NaN length is a mismatch', () => {
  const near = (line, claimed) => suggestionOf(sugg('s', line, { lengthMeters: claimed })).warnings.includes('mismatch');
  const short = seg([0, 0], [0, 300], 25);
  const L = lineLength(short.map(round5));
  assert.ok(!near(short, L + 45) && near(short, L + 55) && near(short, L - 55));
  const long = seg([0, 0], [0, 2000], 25);
  const L2 = lineLength(long.map(round5));
  assert.ok(!near(long, L2 * 1.09) && near(long, L2 * 1.11));
  assert.ok(near(short, NaN) && near(short, '300'));
});

test('the thresholds sit where the constants say: short 300 m, long 15 km, straight 500 m, over-cap 20 km', () => {
  const w = (line) => suggestionOf(sugg('s', line));
  assert.ok(w(seg([0, 0], [0, 290])).warnings.includes('short'));
  assert.ok(!w(seg([0, 0], [0, 310])).warnings.includes('short'));
  assert.ok(w(seg([0, 0], [0, 15_300], 50)).warnings.includes('long'));
  assert.ok(!w(seg([0, 0], [0, 14_700], 50)).warnings.includes('long'));
  const over = w(seg([0, 0], [0, 20_200], 50));
  assert.deepEqual(over.problems, ['meters']);
  assert.ok(!over.warnings.includes('long'), 'over the cap is a problem, not "very long"');
  assert.deepEqual(w(seg([0, 0], [0, 19_900], 50)).problems, []);
  // A gap between the first two points counts as much as one in the middle.
  const gapFirst = [at(0, 0), ...seg([0, 600], [0, 1000])];
  assert.ok(longestStretch(gapFirst) > 590);
  assert.ok(w(gapFirst).warnings.includes('straight'));
  assert.ok(!w([at(0, 0), ...seg([0, 300], [0, 1000])]).warnings.includes('straight'), '300 m');
  // Characters as a person counts them, for the note too; a region is exactly two letters.
  const family = '👨‍👩‍👧‍👦';
  assert.ok(!w(seg([0, 0], [0, 500])).warnings.includes('note'));
  assert.ok(!suggestionOf(sugg('s', seg([0, 0], [0, 500]), { note: family.repeat(300) })).warnings.includes('note'));
  for (const region of ['abc', 'ncx', 'n', '']) assert.ok(suggestionOf(sugg('s', seg([0, 0], [0, 500]), { region })).warnings.includes('region'), region);
  // The decode limit: at the limit it is read (and over the point cap); one more is not read.
  assert.deepEqual(suggestionOf(sugg('s', null, { line: '?'.repeat(LINE_CHAR_LIMIT) })).problems, ['points']);
});

test('Accept takes a line exactly at the caps and an 80-character name as a person counts it', () => {
  const [g] = groupSuggestions([sugg('s', path(60))]);
  const line = { ...g.line, problems: [] };
  assert.doesNotThrow(() => acceptPlan({ ...g, line: { ...line, pointCount: 2000 } }, 'Creek Path'));
  assert.doesNotThrow(() => acceptPlan({ ...g, line: { ...line, lengthMeters: 20_000 } }, 'Creek Path'));
  assert.doesNotThrow(() => acceptPlan(g, '👨‍👩‍👧‍👦'.repeat(80)));
  assert.throws(() => acceptPlan({ ...g, line: { ...line, lengthMeters: NaN } }, 'Creek Path'));
});

test('Accept tells at most 5 devices per walker through the store, and the same device again costs nothing', async () => {
  const line = path(60);
  const names = Array.from({ length: 7 }, (_, i) => `status.${String(i).repeat(64)}`);
  const [group] = groupSuggestions(names.map((n, i) => sugg(`s${i}`, line, { created: 10 - i, statusName: n, submitter: 'suggester-9' })));
  const store = fakeStore();
  const { told } = await acceptSuggestionsAndTell(store, { group, name: 'Creek Path', now: NOW });
  assert.deepEqual([told.written, told.capped], [5, 2]);
  assert.equal(statusWrites(store).length, 5);
  // Six suggestions from one phone and one from a second: both phones are told.
  const same = suggestionStatusNames([...Array.from({ length: 6 }, (_, i) => ({ recordName: `p${i}`, created: 10 - i, statusName: NAME_A, submitter: 'suggester-1' })),
    { recordName: 'q', created: 1, statusName: NAME_B, submitter: 'suggester-1' }]);
  assert.deepEqual([same.names, same.capped], [[NAME_A, NAME_B], 0]);
});

test('History names the trimmed accepted name and the line used; a skipped name still reaches the page when every write fails', async () => {
  const line = path(60);
  const [group] = groupSuggestions([sugg('first', line.slice(0, 40), { created: 1, statusName: NAME_A }), sugg('longest', line, { created: 2, statusName: NAME_B })]);
  assert.equal(group.line.recordName, 'longest');
  const store = fakeStore();
  await acceptSuggestionsAndTell(store, { group, name: '  Mill Run ', now: NOW });
  const [accepted, told] = history(store);
  assert.equal(accepted.targetRecordName, 'longest');
  assert.equal(JSON.parse(accepted.snapshot).name, 'Mill Run');
  assert.equal(told.targetRecordName, 'longest');
  assert.equal(JSON.parse(told.snapshot).trailName, 'Mill Run');
  const decline = fakeStore();
  await declineSuggestions(decline, { group });
  assert.equal(history(decline)[0].targetRecordName, 'longest');
  const squatted = fakeStore({ existing: new Map([[NAME_A, { recordName: NAME_A, recordType: 'TrailSuggestion', fields: {} }]]), failWriteAt: 1 });
  const out = await acceptSuggestionsAndTell(squatted, { group, name: 'Mill Run', now: NOW });
  assert.deepEqual([out.told.blocked, out.told.error.ckErrorCode], [1, 'NETWORK_ERROR']);
  assert.equal(suggestionToldText({ written: 0, planned: 0, blocked: 0, error: null }), '');
});

test('Decline keeps no name over the caps in History, and a huge one can\'t stop it', async () => {
  const [g] = groupSuggestions([sugg('s', path(60), { name: 'x'.repeat(10_000) })]);
  assert.equal(declinePlan(g).snapshot.name, '');
  const [ok] = groupSuggestions([sugg('s', path(60), { name: 'Creek Path' })]);
  assert.equal(declinePlan(ok).snapshot.name, 'Creek Path');
});

test('groups are ordered newest first among equals, decided ones by time alone; notes newest first; one acceptance makes a group accepted', () => {
  const one = path(60);
  const two = path(60, { north: 3000 });
  const three = path(60, { north: 6000 });
  const waiting = groupSuggestions([sugg('old', one, { created: 1 }), sugg('new', two, { created: 2 })]);
  assert.deepEqual(waiting.map((g) => g.id), ['new', 'old']);
  const decidedGroups = groupSuggestions([sugg('big1', one, { created: 1, submitter: 'suggester-1' }), sugg('big2', one, { created: 2, submitter: 'suggester-2' }),
    sugg('small', two, { created: 5 })], [decided('declined', ['big1', 'big2', 'small'], 10)]);
  assert.deepEqual(decidedGroups.map((g) => g.id), ['small', 'big1'], 'decided: newest first, not most walkers');
  const [mixed] = groupSuggestions([sugg('m1', three, { created: 1 }), sugg('m2', three, { created: 2 })],
    [decided('declined', ['m1'], 10), decided('accepted', ['m2'], 11)]);
  assert.equal(mixed.state, 'accepted');
  const [noted] = groupSuggestions([sugg('n1', one, { created: 1, note: 'first' }), sugg('n2', one, { created: 2, note: 'second' })]);
  assert.deepEqual(noted.notes.map((n) => n.note), ['second', 'first']);
});

test('a suggester\'s token is its own: the page can\'t link someone\'s walker reports to their suggestions', () => {
  const who = '_linkcheck000000000000';
  const walker = reporterToken(who);
  const suggester = suggesterToken(who);
  assert.match(walker, /^walker-\d+$/);
  assert.match(suggester, /^suggester-\d+$/);
  assert.equal(suggesterToken(who), suggester, 'stable for the page load');
  assert.equal(suggesterToken(''), undefined);
});

test('GPX strips what XML can\'t hold, names an unnamed track, and file names never end in a dash; OSM refuses a point off the globe', () => {
  const pts = [{ latitude: 1, longitude: 1 }, { latitude: 1.1, longitude: 1.1 }];
  const gpx = gpxDocument('O\'Neil\u0002￿ Path', pts);
  assert.match(gpx, /<name>O&apos;Neil Path<\/name>/);
  assert.match(gpxDocument('', pts), /<name>Trail suggestion<\/name>/);
  assert.equal(gpxFileName(`${'x'.repeat(39)} y`), `wockett-suggestion-${'x'.repeat(39)}.gpx`);
  assert.equal(osmEditLink(0, 181), null);
  assert.equal(osmEditLink(-90, -180), 'https://www.openstreetmap.org/edit#map=18/-90.00000/-180.00000');
});

test('a removal request deletes only suggestions, whatever else is passed', async () => {
  const store = fakeStore();
  await deleteSuggestionsBy(store, { records: [{ recordName: 's1', recordType: 'TrailSuggestion' }, { recordName: 'a1', recordType: 'ModerationAction' },
    { recordName: 'n1', recordType: 'TrailNomination' }] });
  assert.deepEqual(store.calls.filter((c) => c[0] === 'delete').map((c) => c[1]), [['s1']]);
});

test('a very large group still draws: no spread of every point', () => {
  const lines = Array.from({ length: 70 }, (_, k) => Array.from({ length: 2000 }, (_, i) => ({ latitude: 35 + i * 1e-5, longitude: -78 + k * 1e-5 })));
  const { paths } = routePaths(lines);
  assert.equal(paths.filter(Boolean).length, 70);
});

// MARK: Critic run 3 (2026-10-16)

test('a line across the 180th meridian is over the caps as grouping measures it, and costs nothing', () => {
  const anti = Array.from({ length: 6 }, (_, i) => ({ latitude: 0, longitude: i % 2 ? 180 : -180 }));
  assert.ok(lineLength(anti) < 1, 'a few metres on the globe');
  assert.ok(flatLength(anti) > 1e7, 'forty thousand km on the flat map');
  const s = suggestionOf(sugg('s', anti));
  assert.deepEqual(s.problems, ['meters']);
  const t = performance.now();
  const groups = groupSuggestions([sugg('a', anti), sugg('b', anti)]);
  assert.ok(performance.now() - t < 1000, `${Math.round(performance.now() - t)} ms (4 s and 1.8 GB before)`);
  assert.equal(groups.length, 2);
  // An ordinary line measures the same both ways.
  const line = path(60).map(round5);
  assert.ok(Math.abs(flatLength(line) - lineLength(line)) < 1);
});

test('crafted lines stacked in one place cost what they check: the budget stops them, and every suggestion stays on the page', () => {
  // A 2,000-point line back and forth over 10 m, and 1,999 within-cap zigzags passing 45 m from it at every angle.
  const blob = sugg('blob', Array.from({ length: 2000 }, (_, i) => at((i % 2) * 10, 0)));
  assert.deepEqual(suggestionOf(blob).problems, []);
  const radial = Array.from({ length: 1999 }, (_, k) => {
    const a = (k / 1999) * Math.PI;
    return sugg(`p${k}`, Array.from({ length: 560 }, (_, i) => {
      const d = (i - 280) * 34;
      const w = (i % 2) * 8;
      return at(45 + Math.cos(a) * d - Math.sin(a) * w, 45 + Math.sin(a) * d + Math.cos(a) * w);
    }), { created: k + 1 });
  });
  assert.deepEqual(suggestionOf(radial[0]).problems, []);
  const t = performance.now();
  const groups = groupSuggestions([blob, ...radial]);
  const ms = performance.now() - t;
  assert.equal(groups.reduce((n, g) => n + g.members.length, 0), 2000);
  assert.ok(groups.some((g) => g.ungrouped), 'the budget ran out and said so');
  assert.ok(ms < 15_000, `${Math.round(ms)} ms (about 1.3 s alone; 53 s before)`);
});

test('a suggestion the budget stopped part-way through its comparisons is flagged ungrouped, never shown as a path of its own', () => {
  // A and B are different paths whose boxes meet (they cross); C lies along B (the second anchor).
  const a = seg([0, 0], [600, 3000]);
  const b = seg([300, 0], [300, 2800]);
  const c = seg([300, 500], [300, 1500]);
  const records = [sugg('A', a, { created: 1 }), sugg('B', b, { created: 2 }), sugg('C', c, { created: 3 })];
  const full = groupSuggestions(records);
  assert.deepEqual(full.map((g) => g.members.map((m) => m.recordName).sort()).sort(), [['A'], ['B', 'C']]);
  let sawStopped = false;
  for (let budget = 0; budget <= 30_000; budget += 20) {
    const groups = groupSuggestions(records, [], budget);
    const withC = groups.find((g) => g.members.some((m) => m.recordName === 'C'));
    assert.ok(withC.members.some((m) => m.recordName === 'B') || withC.ungrouped, `budget ${budget}: C alone and unflagged`);
    if (withC.ungrouped && groups.some((g) => g.id === 'B' && !g.ungrouped)) sawStopped = true;
  }
  assert.ok(sawStopped, 'some budget stops C between the two anchors');
  // The memory ceiling works the same way.
  const tight = groupSuggestions(records, [], GROUPING_BUDGET, 1);
  assert.ok(tight.find((g) => g.members.some((m) => m.recordName === 'C')).ungrouped);
  assert.deepEqual([GROUPING_BUDGET, MAX_INDEX_ENTRIES, INDEX_ENTRY_WORK, SAMPLE_WORK], [40_000_000, 1_200_000, 10, 5]);
});

test('the index finds exactly the points within the tolerance, and charges every distance it measures', () => {
  // Against a brute-force distance to the original segments, on the index's own flat map.
  let r = 11;
  const rand = () => { r = (r * 48271) % 2147483647; return r / 2147483647; };
  const toSeg = (p, a, b) => {
    const dx = b.x - a.x; const dy = b.y - a.y; const l2 = dx * dx + dy * dy;
    const t = l2 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0;
    return Math.hypot(p.x - a.x - t * dx, p.y - a.y - t * dy);
  };
  for (let n = 0; n < 40; n += 1) {
    const pts = [];
    let x = 0; let y = 0; let h = rand() * 6.28;
    for (let i = 0; i < 30; i += 1) { h += (rand() - 0.5) * 2; const step = 5 + rand() * 300; x += Math.cos(h) * step; y += Math.sin(h) * step; pts.push(at(x, y)); }
    const index = lineIndex(pts, OVERLAP_TOLERANCE_M);
    const k = Math.cos((pts[0].latitude * Math.PI) / 180);
    const xy = pts.map((p) => ({ x: 6_371_008.8 * ((p.longitude - pts[0].longitude) * Math.PI / 180) * k, y: 6_371_008.8 * ((p.latitude - pts[0].latitude) * Math.PI / 180) }));
    for (let j = 0; j < 400; j += 1) {
      const i = 1 + Math.floor(rand() * (xy.length - 1));
      const t = rand();
      const base = { x: xy[i - 1].x + (xy[i].x - xy[i - 1].x) * t, y: xy[i - 1].y + (xy[i].y - xy[i - 1].y) * t };
      const a = rand() * 6.28;
      const d = 20 + rand() * 20;
      const p = { x: base.x + Math.cos(a) * d, y: base.y + Math.sin(a) * d };
      let best = Infinity;
      for (let q = 1; q < xy.length; q += 1) best = Math.min(best, toSeg(p, xy[q - 1], xy[q]));
      assert.equal(index.near(p), best <= OVERLAP_TOLERANCE_M, `line ${n}, point ${j}: ${best.toFixed(3)} m`);
    }
  }
  // 2,000 pieces stacked in one place: a miss next to them is charged for every one it measured.
  const blob = lineIndex(Array.from({ length: 2000 }, (_, i) => at((i % 2) * 10, 0)), OVERLAP_TOLERANCE_M);
  let spent = 0;
  assert.equal(blob.near({ x: 5, y: 45 }, (n) => { spent += n; }), false);
  assert.ok(spent >= 1999, `${spent} units for one miss`);
});

test('a flood of over-cap records costs little: at most 2,001 points are read from any line, and long text is not counted to the end', () => {
  // 40,000 characters of the smallest point there is: 20,000 points.
  const flood = 'A?@?'.repeat(10_000);
  assert.equal(flood.length, LINE_CHAR_LIMIT);
  assert.equal(decodePolyline(flood).length, 20_000);
  assert.equal(decodePolyline(flood, 5, 2001).length, 2001);
  const claimed = suggestionOf(sugg('s', null, { line: flood, pointCount: 20_000, lengthMeters: 0 })).lengthMeters;
  const records = Array.from({ length: 2000 }, (_, k) => sugg(`f${k}`, null, { line: flood, created: k, pointCount: 20_000, lengthMeters: claimed }));
  const t = performance.now();
  const items = records.map((r) => suggestionOf(r));
  const groups = groupSuggestions(records);
  const ms = performance.now() - t;
  for (const s of items) {
    assert.ok(s.line.length <= 2001, `${s.line.length} points kept`);
    assert.deepEqual(s.problems, ['points']);
    assert.ok(!s.warnings.includes('mismatch'), 'a count over the cap agrees with "more than 2,000"');
  }
  assert.equal(groups.length, 2000);
  assert.ok(ms < 15_000, `${Math.round(ms)} ms (13 s and 3 GB before)`);
  assert.ok(suggestionOf(sugg('s', null, { line: flood, pointCount: 10, lengthMeters: claimed })).warnings.includes('mismatch'), 'a count within the cap is wrong');
  // A megabyte of note or name is over the cap without being counted.
  const big = 'x'.repeat(1_000_000);
  let t2 = performance.now();
  assert.equal(textLength(big, 300), 301);
  assert.ok(suggestionOf(sugg('s', path(60), { note: big, name: big })).warnings.includes('note'));
  assert.ok(performance.now() - t2 < 200, `${Math.round(performance.now() - t2)} ms`);
  t2 = performance.now();
  assert.equal(textLength('👨‍👩‍👧‍👦'.repeat(5000), 80), 81, 'stops counting past the cap');
  assert.ok(performance.now() - t2 < 50);
  assert.equal(textLength('abc'), 3);
  assert.equal(textLength('x'.repeat(81), 80), 81);
  assert.equal(textLength('x'.repeat(80), 80), 80);
  assert.equal(textLength('x'.repeat(5000), 80), 81, 'stops at the cap, not the end');
});

test('the budget is checked before every anchor, and building an index is charged for its entries', () => {
  // 50 separate paths (5 km, 80 m apart), and a shorter line crossing all of their boxes.
  const anchors = Array.from({ length: 50 }, (_, k) => sugg(`a${k}`, seg([k * 80, 0], [k * 80 + 40, 5000], 50), { created: k }));
  const probe = sugg('probe', seg([0, 1500], [3990, 1520]), { created: 99 });
  const full = {};
  groupSuggestions([...anchors, probe], [], GROUPING_BUDGET, MAX_INDEX_ENTRIES, full);
  assert.ok(full.indexes >= 40, `${full.indexes} indexes with room to spare`);
  assert.ok(full.spent >= full.entries * INDEX_ENTRY_WORK, 'every entry built is charged');
  // A budget that runs out after the first index: the probe stops, flagged, without building the rest.
  for (const budget of [1, 1000, 10_000]) {
    const meter = {};
    const groups = groupSuggestions([...anchors, probe], [], budget, MAX_INDEX_ENTRIES, meter);
    assert.ok((meter.indexes ?? 0) <= 2, `budget ${budget}: ${meter.indexes} indexes`);
    assert.equal(groups.reduce((n, g) => n + g.members.length, 0), 51);
  }
});

const overCapName = (name) => suggestionOf(sugg('s', path(60), { name })).warnings.includes('name');

test('a name or note can\'t hide a megabyte in one character (critic run 5)', () => {
  const heavy = `e${'\u0301'.repeat(3000)}`;
  assert.equal(textLength(heavy), 1);
  const s = suggestionOf(sugg('s', path(60), { name: heavy, note: `x${'\u0301'.repeat(10_000)}` }));
  assert.ok(s.warnings.includes('name') && s.warnings.includes('note'));
  const [g] = groupSuggestions([sugg('s', path(60), { name: heavy })]);
  assert.equal(declinePlan(g).snapshot.name, '');
  assert.throws(() => acceptPlan(g, heavy), /at most 80/);
  // Any real name fits: 80 family emoji are 880 units, 80 characters with one accent each are 160; 2,560 units is the most.
  assert.ok(!suggestionOf(sugg('s', path(60), { name: 'é'.normalize('NFD').repeat(80) })).warnings.includes('name'));
  assert.ok(!overCapName(`e${'\u0301'.repeat(2559)}`) && overCapName(`e${'\u0301'.repeat(2560)}`));
  assert.equal(UNITS_PER_CHARACTER, 32);
});

test('a card draws the accepted line and at most 20 others', () => {
  const app = staff('app.js');
  assert.match(fn(app, 'suggestionSvg'), /\.slice\(0, 20\)\.map\(\(m\) => m\.line\)/);
  assert.match(fn(app, 'suggestionCard'), /clip\(g\.name, 200\)/);
  assert.match(fn(app, 'suggestionCard'), /clip\(n\.note, 600\)/);
});

test('samples are made once per line, every 25 m, and land where the line is', () => {
  const line = seg([0, 0], [0, 1000]);
  const samples = samplesOf(line);
  assert.ok(samples.length === 41 || samples.length === 42, `${samples.length}: every 25 m, both ends`);
  assert.ok(Math.abs(samples[20].latitude - at(0, 500).latitude) < 1e-7);
  assert.ok(Math.abs(samples.at(-1).latitude - at(0, 1000).latitude) < 1e-9);
  assert.ok(Math.abs(samples.at(-1).longitude - at(0, 1000).longitude) < 1e-9);
});

// MARK: The page and the schema

const staff = (file) => readFileSync(new URL(`../../docs/staff/${file}`, import.meta.url), 'utf8');

test('nothing in the dashboard writes a CommunityTrail: collect-only until PR 4', () => {
  for (const file of readdirSync(new URL('../../docs/staff/', import.meta.url))) {
    if (file.endsWith('.js')) assert.doesNotMatch(staff(file), /['"]CommunityTrail['"]/, file);
  }
});

/** One function's source in app.js, from its declaration to the next top-level function. */
function fn(app, name) {
  const start = app.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} is in app.js`);
  const end = app.indexOf('\nfunction ', start + 1);
  const end2 = app.indexOf('\nasync function ', start + 1);
  return app.slice(start, Math.min(...[end, end2].filter((n) => n > 0)));
}

test('the page offers the tab, counts the Accept confirm from the group as Accept writes it, and saves GPX without a network', () => {
  assert.match(staff('index.html'), /<button data-view="suggestions">Trail suggestions<\/button>/);
  const app = staff('app.js');
  assert.match(app, /suggestions: renderSuggestions,/);
  const accept = fn(app, 'confirmAcceptSuggestion');
  assert.match(accept, /const tell = suggestionStatusNames\(group\.members\);\n/);
  assert.doesNotMatch(accept, /tell\.names\s*=|tell\.names\.(splice|pop|shift|length\s*=)/, 'the count is not altered after it is taken');
  assert.match(accept, /el\('p', \{\}, acceptTellText\(tell\), /);
  // Asks first, re-checks the name in the dialog, then accepts, then remembers the decision.
  assert.match(accept, /if \(event\.submitter\?\.value !== 'accept'\) return;[\s\S]*acceptPlan\(group, name\);[\s\S]*return;[\s\S]*await acceptSuggestionsAndTell\(store, \{ group, name, note: form\.elements\.note\.value \}\);\n\s*rememberDecision\('accepted', plan\);/);
  assert.match(fn(app, 'confirmDeclineSuggestion'), /if \(event\.submitter\?\.value !== 'decline'\) return;[\s\S]*await declineSuggestions\(store,[\s\S]*rememberDecision\('declined', plan\);/);
  assert.match(fn(app, 'confirmDeleteSuggestionsByIdentifier'), /if \(event\.submitter\?\.value !== 'delete'\) return;[\s\S]*await deleteSuggestionsBy\(store, \{ records \}\)/);
  assert.match(fn(app, 'askDeleteSuggestionsByIdentifier'), /if \(event\.submitter\?\.value !== 'find'\) return;[\s\S]*await findSuggestionsBy\(/);
  // GPX: the accepted name if any, made on the page.
  assert.match(fn(app, 'suggestionCard'), /const name = g\.acceptedName \|\| g\.name;\n\s*saveFile\(gpxFileName\(name\), gpxDocument\(name, line\.line\), 'application\/gpx\+xml'\);/);
  assert.match(fn(app, 'saveFile'), /URL\.createObjectURL\(new Blob\(\[text\], \{ type \}\)\)/);
  // No network but CloudKit through ck.js: the only `fetch(` is the store's.
  assert.deepEqual([...app.matchAll(/(\S*)fetch\(/g)].map((m) => m[1]).filter((pre) => !pre.endsWith('store.')), []);
  assert.doesNotMatch(app, /XMLHttpRequest|sendBeacon|WebSocket|EventSource|import\(/);
  // The suggestions screen: Delete is drawn before loading; the missing type reads as empty; left-out records are said.
  const screen = fn(app, 'renderSuggestions');
  assert.ok(screen.indexOf('deleteButton));') < screen.indexOf("store.query('TrailSuggestion'"), 'the removal button comes before anything slow');
  assert.ok(screen.indexOf('Grouping suggestions') < screen.indexOf('groupSuggestions('), 'drawn again before grouping');
  assert.match(screen, /if \(!current\(seq\) \|\| !isUnknownRecordType\(error\)\) throw error;/);
  assert.match(screen, /suggestions\.hidden \? el\('p'/);
  assert.match(screen, /const ungrouped = all\.filter\(\(g\) => g\.ungrouped\)\.length;/);
  assert.match(screen, /ungrouped \? el\('p', \{ class: 'small status error' \}, `\$\{suggestionCount\(ungrouped\)\} shown ungrouped/);
  assert.match(screen, /groupSuggestions\(suggestions\.records, \[\.\.\.actions\.records, \.\.\.suggestionsDecided\]\)/);
  assert.match(app, /f\.targetType === 'suggestion' \|\| f\.targetType === 'trailSuggestions' \? el\('div', \{\}, suggestionHistoryText\(f\)\) : null,/);
});

function schemaBlock(type) {
  const schema = readFileSync(new URL('../../cloudkit/schema.ckdb', import.meta.url), 'utf8');
  const match = schema.match(new RegExp(`RECORD TYPE ${type} \\(([\\s\\S]*?)\\n    \\);`));
  assert.ok(match, `${type} is in the schema`);
  return match[1];
}

test('a suggestion is readable only by a Moderator, created by any signed-in user, and holds exactly these fields', () => {
  assert.deepEqual(schemaBlock('TrailSuggestion').split('\n').map((l) => l.trim().replace(/\s+/g, ' ')).filter(Boolean), [
    '"___createTime" TIMESTAMP QUERYABLE SORTABLE,', '"___createdBy" REFERENCE QUERYABLE,', '"___etag" STRING,',
    '"___modTime" TIMESTAMP,', '"___modifiedBy" REFERENCE,', '"___recordID" REFERENCE QUERYABLE,',
    'claimToken STRING,', 'dogs STRING,', 'lengthMeters DOUBLE,', 'line STRING,', 'name STRING,', 'note STRING,',
    'pointCount INT64,', 'region STRING QUERYABLE,', 'stroller STRING,', 'surface STRING,', 'wheelchair STRING,',
    'GRANT READ, WRITE TO Moderator,', 'GRANT CREATE TO "_icloud"',
  ]);
  // No other type was touched to get there, and no public type for suggestions exists yet.
  assert.doesNotMatch(readFileSync(new URL('../../cloudkit/schema.ckdb', import.meta.url), 'utf8'), /CommunityTrail/);
});
