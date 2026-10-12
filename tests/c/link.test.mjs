// The challenge link page's rules (docs/c/link.js).
// Run from the repo root: node --test tests/c/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { challengeID, clean, describe, isSuspended, suspensionRecordName, MAX_TITLE_LENGTH } from '../../docs/c/link.js';

const ID = '6F1C2B9E-0D3A-4E57-9B1A-2C7D8E9F0A1B';
const record = (fields, recordType = 'Challenge') => ({
  recordName: ID, recordType,
  fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, { value: v }])),
});

test('challengeID reads one well-formed id', () => {
  assert.equal(challengeID(`?id=${ID}`), ID);
  assert.equal(challengeID(`?id=${ID}&utm_source=x`), ID);
  assert.equal(challengeID(`?id=${'a'.repeat(100)}`), 'a'.repeat(100));
});

test('challengeID rejects anything else, as ChallengeLink.swift does', () => {
  for (const search of ['', '?', '?id=', `?challenge=${ID}`, `?id=${ID}&id=x`, `?id=${'a'.repeat(101)}`,
    '?id=a%2Fb', '?id=%3Cscript%3E', '?id=abc.', '?id=%E2%80%AEabc', '?id=a%20b', undefined]) {
    assert.equal(challengeID(search), null, String(search));
  }
});

test('clean strips control, zero-width and direction characters', () => {
  assert.equal(clean('Weekend\u202e Runfest\u200b'), 'Weekend Runfest');
  assert.equal(clean('  two\n\tlines  '), 'two lines');
  assert.equal(clean('\u200b\u202e '), null);
  assert.equal(clean(42), null);
});

test('clean cuts long text by grapheme, never splitting an emoji', () => {
  const long = '👨‍👩‍👧'.repeat(MAX_TITLE_LENGTH + 5);
  const out = clean(long);
  assert.equal([...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment(out)].length, MAX_TITLE_LENGTH + 1);
  assert.ok(out.endsWith('👨‍👩‍👧…'));
});

test('describe: a running challenge shows its title and emoji', () => {
  const now = Date.UTC(2026, 9, 12);
  assert.deepEqual(describe(record({ title: 'Weekend Runfest', emoji: '🔥', endDate: now + 1000 }), null, now),
    { state: 'open', title: 'Weekend Runfest', emoji: '🔥' });
});

test('describe: an ended challenge says so', () => {
  const now = Date.UTC(2026, 9, 12);
  assert.equal(describe(record({ title: 'Old', endDate: now - 1 }), null, now).state, 'ended');
});

test('describe: missing, other types and untitled records stay generic', () => {
  assert.deepEqual(describe(undefined), { state: 'unknown' });
  assert.deepEqual(describe(record({ title: 'x' }, 'SharedRoute')), { state: 'unknown' });
  assert.deepEqual(describe(record({ title: '\u200b' })), { state: 'unknown' });
  assert.deepEqual(describe({ recordName: ID, serverErrorCode: 'NOT_FOUND' }), { state: 'unknown' });
});

const suspension = (until) => ({
  recordName: 'suspension._abc', recordType: 'Suspension',
  fields: until === undefined ? { accountRecordName: { value: '_abc' } }
    : { accountRecordName: { value: '_abc' }, until: { value: until } },
});

test('a suspended author\'s challenge stays generic, as the app hides it', () => {
  const now = Date.UTC(2026, 9, 12);
  const running = record({ title: 'Wockett support: your account is locked', endDate: now + 1000 });
  assert.deepEqual(describe(running, suspension(), now), { state: 'unknown' });           // permanent
  assert.deepEqual(describe(running, suspension(now + 1000), now), { state: 'unknown' }); // still in force
  assert.equal(describe(running, suspension(now - 1), now).state, 'open');                // ended
  assert.equal(describe(running, undefined, now).state, 'open');                          // none
});

test('isSuspended reads a missing until as permanent and ignores empty records', () => {
  assert.equal(isSuspended(suspension(), 0), true);
  assert.equal(isSuspended(undefined), false);
  assert.equal(isSuspended({ recordName: 'suspension._abc', serverErrorCode: 'NOT_FOUND' }), false);
});

test('suspensionRecordName follows the staff dashboard\'s naming', () => {
  assert.equal(suspensionRecordName({ created: { userRecordName: '_abc' } }), 'suspension._abc');
  assert.equal(suspensionRecordName({ created: {} }), null);
  assert.equal(suspensionRecordName(undefined), null);
});
