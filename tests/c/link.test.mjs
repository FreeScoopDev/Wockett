// The challenge link page's rules (docs/c/link.js).
// Run from the repo root: node --test tests/c/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { challengeID, clean, describe, MAX_TITLE_LENGTH } from '../../docs/c/link.js';

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
  assert.deepEqual(describe(record({ title: 'Weekend Runfest', emoji: '🔥', endDate: now + 1000 }), now),
    { state: 'open', title: 'Weekend Runfest', emoji: '🔥' });
});

test('describe: an ended challenge says so', () => {
  const now = Date.UTC(2026, 9, 12);
  assert.equal(describe(record({ title: 'Old', endDate: now - 1 }), now).state, 'ended');
});

test('describe: missing, other types and untitled records stay generic', () => {
  assert.deepEqual(describe(undefined), { state: 'unknown' });
  assert.deepEqual(describe(record({ title: 'x' }, 'SharedRoute')), { state: 'unknown' });
  assert.deepEqual(describe(record({ title: '\u200b' })), { state: 'unknown' });
  assert.deepEqual(describe({ recordName: ID, serverErrorCode: 'NOT_FOUND' }), { state: 'unknown' });
});
