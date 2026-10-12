// The challenge link's rules, shared with the app: PoCSquat/Services/Community/
// ChallengeLink.swift checks the id the same way. Change one, change the other.
// Pure, so tests/c/link.test.mjs runs them without a browser or a network.

export const MAX_ID_LENGTH = 100;
export const MAX_TITLE_LENGTH = 80;

/** The challenge id in a page's query string ("?id=…"), or null. */
export function challengeID(search) {
  const ids = new URLSearchParams(search ?? '').getAll('id');
  if (ids.length !== 1) return null;
  const id = ids[0];
  return id.length >= 1 && id.length <= MAX_ID_LENGTH && /^[A-Za-z0-9_-]+$/.test(id) ? id : null;
}

/**
 * Text from a record, safe to show: no control, zero-width or direction
 * characters (which can make a name read as something else), trimmed, cut to
 * `max` characters by grapheme so an emoji is never split. Empty → null.
 */
export function clean(value, max = MAX_TITLE_LENGTH) {
  if (typeof value !== 'string') return null;
  // Whitespace first, so a newline becomes a space rather than vanishing. The
  // joiners U+200C/U+200D stay: emoji like the family emoji and some scripts need them.
  const stripped = value
    .replace(/\s+/g, ' ')
    .replace(/[\u0000-\u001f\u007f-\u009f\u200b\u200e\u200f\u202a-\u202e\u2060-\u2069\ufeff]/g, '')
    .trim();
  if (!stripped) return null;
  const graphemes = [...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment(stripped)]
    .map((s) => s.segment);
  return graphemes.length > max ? `${graphemes.slice(0, max).join('').trimEnd()}…` : stripped;
}

/** The Suspension record that would name a challenge's creator, or null. */
export function suspensionRecordName(record) {
  const creator = record?.created?.userRecordName;
  return typeof creator === 'string' && creator ? `suspension.${creator}` : null;
}

/**
 * Whether a Suspension record (from the staff dashboard) is in force: no
 * `until` is permanent. The app hides a suspended author's challenges
 * (CommunityModerationStore.shouldHide); so does this page.
 */
export function isSuspended(suspension, now = Date.now()) {
  if (!suspension || !suspension.fields) return false;
  const until = suspension.fields.until?.value;
  return typeof until !== 'number' || until > now;
}

/**
 * What the page shows for a CloudKit JS record (or null when there is none)
 * and its creator's Suspension record, if any:
 * { state: 'open' | 'ended' | 'unknown', title, emoji }.
 */
export function describe(record, suspension = null, now = Date.now()) {
  if (!record || record.recordType !== 'Challenge' || !record.fields) return { state: 'unknown' };
  if (isSuspended(suspension, now)) return { state: 'unknown' };
  const title = clean(record.fields.title?.value);
  if (!title) return { state: 'unknown' };
  const emoji = clean(record.fields.emoji?.value, 2);
  const end = record.fields.endDate?.value;
  const ended = typeof end === 'number' && end < now;
  return { state: ended ? 'ended' : 'open', title, emoji };
}
