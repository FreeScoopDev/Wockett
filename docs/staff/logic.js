// The staff dashboard's rules, with no network and no page: grouping reports
// by item, open versus resolved, the removal snapshot, the activity counts and
// the route line. Tested by `node --test tests/staff/*.test.mjs` from the repo root.
//
// A record here is the adapter's plain shape (ck.js `plain`):
//   { recordName, recordType, created (ms since 1970), fields: { name: value },
//     creator (community items only: the author's account) }
// Who created a report is never part of it: the dashboard never shows who
// reported something.

import { WALKER_FACTS } from './walker-facts.js';

export { WALKER_FACTS };

/** The community types a moderator acts on, keyed by the app's `targetType`. */
export const TYPES = {
  route:     { recordType: 'SharedRoute',       label: 'Route' },
  post:      { recordType: 'WocketAchievement', label: 'Post' },
  challenge: { recordType: 'Challenge',         label: 'Challenge' },
  name:      { recordType: 'CommunityName',     label: 'Community name' },
};

/** `targetType` for a record type, or undefined. */
export function typeOfRecordType(recordType) {
  return Object.keys(TYPES).find((k) => TYPES[k].recordType === recordType);
}

/** `targetType` if it names one of TYPES, else undefined. Reports are written
 * by any iCloud user, so their text is never trusted as a key ("toString"). */
export function knownType(type) {
  return typeof type === 'string' && Object.hasOwn(TYPES, type) ? type : undefined;
}

/**
 * What a reported item really is: the fetched record's own type, never the
 * report's say-so. Undefined when it isn't community content (a crafted
 * report can name any record): such an item can only be dismissed.
 */
export function effectiveType(group, record) {
  if (record) return typeOfRecordType(record.recordType);
  return knownType(group?.type);
}

/** The app's report reasons (`CommunityReportReason` raw values). */
export const REASONS = {
  spam: 'Spam',
  offensive: 'Offensive',
  unsafe: 'Unsafe, or a place that shouldn\'t be shared',
  personalInfo: 'Shares someone\'s personal info',
  other: 'Something else',
};

/**
 * Reasons that aren't a user's report: they read in the queue but are never
 * offered as a removal reason. "ownerRequest" is the app's "ask to delete"
 * for a challenge others have joined.
 */
export const REQUEST_REASONS = {
  ownerRequest: 'Owner asked to delete it',
};

export function reasonLabel(reason) {
  if (typeof reason === 'string' && Object.hasOwn(REASONS, reason)) return REASONS[reason];
  if (typeof reason === 'string' && Object.hasOwn(REQUEST_REASONS, reason)) return REQUEST_REASONS[reason];
  return reason ? String(reason) : 'No reason given';
}

// MARK: - Reports queue

/**
 * Reports grouped by the item they name, with each item's latest moderation
 * action. An item is open while it has a report newer than its latest action:
 * a dismissed item that is reported again comes back.
 */
export function groupReports(reports, actions = []) {
  const lastAction = new Map();
  for (const a of actions) {
    const t = a.fields.targetRecordName;
    // Only actions on community items close reports: a trail or account
    // action under the same name must not (a nominator picks the trail key).
    if (!t || NON_ITEM_TARGETS.includes(a.fields.targetType)) continue;
    const prev = lastAction.get(t);
    if (!prev || a.created > prev.created) lastAction.set(t, a);
  }
  const groups = new Map();
  for (const r of reports) {
    const target = r.fields.targetRecordName;
    if (!target) continue;
    let g = groups.get(target);
    if (!g) {
      g = { target, type: r.fields.targetType ?? 'post', reports: [], firstAt: r.created, latestAt: r.created,
            authorName: '', summary: '' };
      groups.set(target, g);
    }
    g.reports.push(r);
    g.firstAt = Math.min(g.firstAt, r.created);
    // What the newest report saw: the item may have changed since the first.
    if (r.created >= g.latestAt) {
      g.latestAt = r.created;
      g.authorName = r.fields.targetAuthorName ?? g.authorName;
      g.summary = r.fields.targetSummary ?? g.summary;
    }
  }
  return [...groups.values()].map((g) => {
    const action = lastAction.get(g.target) ?? null;
    // Reasons and notes are the ones since the last action: a dismissed item
    // reported again is judged on what is new.
    const fresh = action ? g.reports.filter((r) => r.created > action.created) : g.reports;
    const counts = new Map();
    for (const r of fresh) {
      const reason = r.fields.reason ?? 'other';
      counts.set(reason, (counts.get(reason) ?? 0) + 1);
    }
    const reasons = [...counts.entries()]
      .map(([reason, count]) => ({ reason, count }))
      .sort((a, b) => b.count - a.count || a.reason.localeCompare(b.reason));
    const notes = fresh
      .filter((r) => (r.fields.note ?? '').trim() !== '')
      .sort((a, b) => b.created - a.created)
      .map((r) => ({ note: r.fields.note.trim(), reason: r.fields.reason ?? 'other', at: r.created }));
    const sinceAction = fresh.length;
    return {
      ...g,
      count: g.reports.length,
      newCount: sinceAction,
      reasons,
      notes,
      lastAction: action,
      fresh,
      open: sinceAction > 0,
    };
  });
}

/**
 * A group whose last action was a removal but whose item still exists: the
 * delete failed after the action was written. Back in the queue, flagged.
 */
/** Which targets to look up: open items, and items whose last action was a
 * removal while they still have reports (to catch a removal that failed). */
export function targetsToCheck(groups, max = 1000) {
  return groups
    .filter((g) => g.open || g.lastAction?.fields?.action === 'removed')
    .sort((a, b) => Number(b.open) - Number(a.open) || b.latestAt - a.latestAt)
    .slice(0, max)
    .map((g) => g.target);
}

/** A string CloudKit could accept as a record name: 1-255 printable ASCII. */
export function isValidRecordName(name) {
  return typeof name === 'string' && /^[\x21-\x7e]{1,255}$/.test(name);
}

export function reopenFailedRemovals(groups, live) {
  return groups.map((g) => (!g.open && g.lastAction?.fields?.action === 'removed' && live.has(g.target)
    ? { ...g, open: true, removalFailed: true }
    : g));
}

/** Action targets that aren't community items, so never close reports. */
export const NON_ITEM_TARGETS = ['trail', 'account', 'trailFact', 'walkerReports'];

/**
 * Open groups, newest report first, or most reported first (ties: newest).
 * `actedAt` maps targets acted on in this session to when: kept out while
 * CloudKit's index catches up with the action, but back as soon as a report
 * newer than the action arrives.
 */
export function queue(groups, order = 'newest', actedAt = new Map()) {
  const open = groups.filter((g) => g.open && !(actedAt.has(g.target) && g.latestAt <= actedAt.get(g.target)));
  return open.sort(order === 'most'
    ? (a, b) => b.newCount - a.newCount || b.latestAt - a.latestAt
    : (a, b) => b.latestAt - a.latestAt);
}

/** The reason a removal is filed under by default: the commonest one reported. */
export function topReason(group) {
  // Only a reason a moderator can file a removal under: an owner's request
  // isn't one, and a removal must never default to "Spam" for it.
  return group?.reasons?.find((r) => Object.hasOwn(REASONS, r.reason))?.reason ?? 'other';
}

/**
 * A reason's label on a report card. An owner's request is called that only
 * when one of the reports since the last action was filed by the item's
 * author (`filedByAuthor(reportRecordName, authorAccount)`, answered inside
 * ck.js); a request from someone else says so, and with no author to check
 * against it says it couldn't check. Older, already-handled reports never
 * vouch for a new one.
 */
export function reasonLabelFor(reason, group, record, filedByAuthor) {
  if (!Object.hasOwn(REQUEST_REASONS, reason)) return reasonLabel(reason);
  if (!record?.creator) return 'Says the owner asked (couldn\'t check)';
  const recent = group.fresh ?? group.reports;
  const fromOwner = recent.some((r) => r.fields.reason === reason && filedByAuthor(r.recordName, record.creator));
  return fromOwner ? reasonLabel(reason) : 'Says the owner asked (not from the owner\'s account)';
}

/** Every report on the item is an owner's request to delete it. */
export function isOwnerRequestOnly(group) {
  return Boolean(group?.reasons?.length) && group.reasons.every((r) => Object.hasOwn(REQUEST_REASONS, r.reason));
}

// MARK: - Removal

/**
 * What removing an item deletes, in order: the item, then what hangs off it
 * (a challenge's entries; the votes on a post or route). Related records are
 * found by query, so they are described here, not listed.
 */
export function removalPlan(type, recordName) {
  const t = TYPES[type];
  if (!t) throw new Error(`Unknown item type: ${type}`);
  const related = [];
  if (type === 'challenge') related.push({ recordType: 'ChallengeEntry', field: 'challengeRecordName', value: recordName });
  if (type === 'route' || type === 'post') related.push({ recordType: 'CommunityVote', field: 'targetRecordName', value: recordName });
  return { item: { recordType: t.recordType, recordName }, related };
}

export const SNAPSHOT_LIMIT = 4096;
const CUT = '…[cut]';

function utf8Length(s) {
  return new TextEncoder().encode(s).length;
}

/**
 * The removed item as JSON, at most `limit` bytes of UTF-8, so a removal can
 * be explained later. When too big, the longest text fields are shortened
 * (a route's waypoints first, being the bulk) and named in `cut`.
 */
export function buildSnapshot(item, limit = SNAPSHOT_LIMIT) {
  const snap = {
    recordType: item.recordType,
    recordName: item.recordName,
    created: item.created ?? null,
    fields: { ...(item.fields ?? {}) },
  };
  let json = JSON.stringify(snap);
  if (utf8Length(json) <= limit) return json;
  snap.cut = [];
  // Shorten the longest string field until it fits, a field at a time.
  for (let guard = 0; guard < 64 && utf8Length(json) > limit; guard += 1) {
    const longest = Object.entries(snap.fields)
      .filter(([, v]) => typeof v === 'string' && v.length > CUT.length)
      .sort((a, b) => b[1].length - a[1].length)[0];
    if (!longest) {
      // Nothing left to shorten (many small fields): keep only the identity.
      snap.fields = {};
      snap.cut = ['all fields'];
      return JSON.stringify(snap);
    }
    const [key, value] = longest;
    const over = utf8Length(json) - limit;
    // Cut by characters, at least the overflow plus the marker, at least half.
    const keep = Math.max(0, Math.min(value.length - over - CUT.length - 8, Math.floor(value.length / 2)));
    snap.fields[key] = [...value].slice(0, keep).join('') + CUT;
    if (!snap.cut.includes(key)) snap.cut.push(key);
    json = JSON.stringify(snap);
  }
  if (utf8Length(json) > limit) {
    // Too many fields to shorten in time: keep only the identity.
    snap.fields = {};
    snap.cut = ['all fields'];
    json = JSON.stringify(snap);
  }
  return json;
}

export const ACTIONS = ['removed', 'dismissed', 'suspended', 'lifted', 'featured', 'unfeatured', 'published', 'unpublished', 'expired'];

/** The fields of a `ModerationAction` record. */
export function actionFields({ target, type, action, reason = '', note = '', reportCount = 0, snapshot = '' }) {
  if (!ACTIONS.includes(action)) throw new Error(`Unknown action: ${action}`);
  if (action === 'removed' && !snapshot) throw new Error('A removal needs its snapshot first.');
  return {
    targetRecordName: target,
    targetType: type,
    action,
    reason,
    note: note.trim().slice(0, 1000),
    reportCount,
    snapshot,
  };
}

// MARK: - Browse

/** The display name a record shows for its author. */
export function authorOf(record) {
  const f = record.fields ?? {};
  return f.authorName ?? f.displayName ?? f.name ?? '';
}

/** Records whose author contains `query`, ignoring case and outer spaces. */
export function filterByAuthor(records, query) {
  const q = (query ?? '').trim().toLowerCase();
  if (!q) return records;
  return records.filter((r) => authorOf(r).toLowerCase().includes(q));
}

// MARK: - Activity

export const DAY = 86_400_000;

/** How many records were created in the last 7 and 30 days before `now`. */
export function countRecent(records, now) {
  let d7 = 0;
  let d30 = 0;
  for (const r of records) {
    const age = now - r.created;
    if (age < 0) continue;            // a clock ahead of ours: not "recent" yet
    if (age < 30 * DAY) d30 += 1;
    if (age < 7 * DAY) d7 += 1;
  }
  return { d7, d30 };
}

/** The Activity table: one row per kind, in a fixed order. */
export const ACTIVITY_KINDS = [
  { key: 'post', label: 'Posts', recordType: 'WocketAchievement' },
  { key: 'route', label: 'Shared routes', recordType: 'SharedRoute' },
  { key: 'challenge', label: 'Challenges', recordType: 'Challenge' },
  { key: 'entry', label: 'Challenge joins', recordType: 'ChallengeEntry' },
  { key: 'vote', label: 'Wocketts given', recordType: 'CommunityVote' },
  { key: 'name', label: 'New community names', recordType: 'CommunityName' },
  { key: 'report', label: 'Reports', recordType: 'CommunityReport' },
  { key: 'nomination', label: 'Trail nominations', recordType: 'TrailNomination' },
  { key: 'walkerReport', label: 'Walker reports', recordType: 'TrailFactReport' },
  { key: 'action', label: 'Moderation actions', recordType: 'ModerationAction' },
];

export function activity(recordsByType, now) {
  return ACTIVITY_KINDS.map((k) => ({ ...k, ...countRecent(recordsByType[k.recordType] ?? [], now) }));
}

// MARK: - Route line

/** A shared route's waypoints, or [] for anything that isn't a list of points. */
export function parseWaypoints(json) {
  try {
    const list = JSON.parse(json ?? '[]');
    if (!Array.isArray(list)) return [];
    return list.filter((p) => p && Number.isFinite(p.latitude) && Number.isFinite(p.longitude));
  } catch {
    return [];
  }
}

/**
 * An SVG path for `points` inside a `width` x `height` box with `pad` around
 * it, north up, keeping the route's shape: longitude is scaled by the cosine
 * of the latitude, and the longer side fills the box. Empty for fewer than
 * two points.
 */
export function routePath(points, width = 160, height = 120, pad = 8) {
  if (points.length < 2) return '';
  const lat0 = points.reduce((s, p) => s + p.latitude, 0) / points.length;
  const k = Math.cos((lat0 * Math.PI) / 180);
  const xs = points.map((p) => p.longitude * k);
  const ys = points.map((p) => -p.latitude);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const spanX = maxX - minX;
  const spanY = maxY - minY;
  const span = Math.max(spanX, spanY);
  if (span === 0) return '';
  const scale = Math.min((width - 2 * pad) / (spanX || span), (height - 2 * pad) / (spanY || span));
  const offX = pad + ((width - 2 * pad) - spanX * scale) / 2;
  const offY = pad + ((height - 2 * pad) - spanY * scale) / 2;
  return xs.map((x, i) => {
    const px = (offX + (x - minX) * scale).toFixed(1);
    const py = (offY + (ys[i] - minY) * scale).toFixed(1);
    return `${i === 0 ? 'M' : 'L'}${px} ${py}`;
  }).join(' ');
}

// MARK: - Text

export function formatDistance(meters) {
  if (!Number.isFinite(meters)) return '';
  const km = meters / 1000;
  const mi = meters / 1609.344;
  return `${km.toFixed(km < 10 ? 1 : 0)} km (${mi.toFixed(mi < 10 ? 1 : 0)} mi)`;
}

/** A challenge's goal in words. */
export function challengeGoal(f) {
  switch (f.goalType) {
    case 'distance': return `${formatDistance(f.goalDistanceMeters)} total`;
    case 'sessions': return `${f.goalSessionCount ?? '?'} sessions`;
    case 'pace': return `pace under ${Math.round((f.goalPaceSecsPerKm ?? 0) / 60)} min/km`;
    default: return `${Number(f.goalSteps ?? 0).toLocaleString('en-US')} steps a day`;
  }
}

/** The item as users see it: a title and lines under it. */
export function describeItem(type, record) {
  const f = record.fields ?? {};
  switch (type) {
    case 'post':
      return { title: `${f.badgeEmoji ?? ''} ${f.badgeName ?? 'Post'}`.trim(), lines: f.message ? [f.message] : [] };
    case 'route':
      return {
        title: f.name ?? 'Route',
        lines: [[formatDistance(f.distanceMeters), f.difficultyTag, f.isLoop ? 'loop' : 'one way'].filter(Boolean).join(' · ')],
      };
    case 'challenge': {
      const day = (ms) => {
        const d = new Date(ms);
        return ms && Number.isFinite(d.getTime()) ? d.toISOString().slice(0, 10) : '?';
      };
      return {
        title: `${f.emoji ?? ''} ${f.title ?? 'Challenge'}`.trim(),
        lines: [`${day(f.startDate)} to ${day(f.endDate)}`, challengeGoal(f)],
      };
    }
    case 'name':
      return { title: f.name ?? record.recordName, lines: [] };
    default:
      return { title: record.recordName, lines: [] };
  }
}

/**
 * A CloudKit JS error as a sentence a moderator can act on. `isGone` errors
 * (the record no longer exists) are treated as done by the callers.
 */
export function describeError(error) {
  const code = error?.ckErrorCode ?? error?.serverErrorCode ?? '';
  switch (code) {
    case 'AUTHENTICATION_REQUIRED':
    case 'AUTHENTICATION_FAILED':
      return 'You are signed out. Sign in with your Apple ID again.';
    case 'NOT_AUTHORIZED':
    case 'ACCESS_DENIED':
      return 'This Apple ID isn\'t allowed to do that. Is it a Wockett moderator in this environment?';
    case 'NETWORK_ERROR':
      return 'Couldn\'t reach iCloud. Check the connection and try again.';
    case 'THROTTLED':
    case 'TRY_AGAIN_LATER':
    case 'SERVICE_UNAVAILABLE':
      return `iCloud asked us to slow down (${code}). Wait a minute and try again.`;
    case 'QUOTA_EXCEEDED':
      return 'The iCloud container is over its quota (QUOTA_EXCEEDED).';
    case 'UNKNOWN_ITEM':
    case 'NOT_FOUND':
      return 'That record no longer exists.';
    default: {
      const reason = error?.reason ?? error?.message ?? String(error ?? 'Unknown error');
      return code ? `CloudKit error ${code}: ${reason}` : reason;
    }
  }
}

/** The record is already gone: removing it again is done, not a failure. */
export function isGone(error) {
  const code = error?.ckErrorCode ?? error?.serverErrorCode;
  return code === 'UNKNOWN_ITEM' || code === 'NOT_FOUND';
}

/** "Not allowed": the signal that this Apple ID isn't a moderator. */
export function isNotAllowed(error) {
  const code = error?.ckErrorCode ?? error?.serverErrorCode;
  return code === 'NOT_AUTHORIZED' || code === 'ACCESS_DENIED';
}

/** "3 hours ago", "2 days ago", or the date. */
export function ago(ms, now = Date.now()) {
  const s = Math.round((now - ms) / 1000);
  if (s < 60) return 'just now';
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} hour${h === 1 ? '' : 's'} ago`;
  const d = Math.round(h / 24);
  if (d < 30) return `${d} days ago`;
  return new Date(ms).toISOString().slice(0, 10);
}

// MARK: - Suspensions

export const SUSPENSION_LENGTHS = {
  '7d': { label: '7 days', days: 7 },
  '30d': { label: '30 days', days: 30 },
  permanent: { label: 'Permanent', days: null },
};

/** When a suspension of `length` starting `now` ends, in ms; null for permanent. */
export function suspensionUntil(length, now) {
  if (!Object.hasOwn(SUSPENSION_LENGTHS, length)) throw new Error(`Unknown length: ${length}`);
  const { days } = SUSPENSION_LENGTHS[length];
  return days === null ? null : now + days * DAY;
}

/** One Suspension record per account, so suspending again replaces it. */
export function suspensionRecordName(account) {
  if (!isValidRecordName(account)) throw new Error('Not an account.');
  return `suspension.${account}`;
}

/**
 * The Suspension record's fields: the account and, unless permanent, the end
 * as a typed TIMESTAMP (the app reads it as a Date). Nothing else.
 */
export function suspensionFields(account, until) {
  return until === null
    ? { accountRecordName: account }
    : { accountRecordName: account, until: { value: until, type: 'TIMESTAMP' } };
}

/**
 * Accounts that can't be suspended: the signed-in moderator's own, and
 * CloudKit's placeholder for "your own records" (`__defaultOwner__`), which
 * would match everyone's own content on their own phone.
 */
export function canSuspend(account, moderator) {
  return isValidRecordName(account) && !account.startsWith('__') && account !== moderator;
}

/** Records the account itself created: never another account's item that uses the same name. */
export function ownedBy(records, account) {
  return records.filter((r) => account && r.creator === account);
}

/** `_87331bb1…` for showing an account without the whole ID. */
export function shortAccount(account) {
  return account && account.length > 10 ? `${account.slice(0, 9)}…` : (account ?? '');
}

/**
 * The Suspensions tab's rows, newest first: each suspension with the author
 * name from its latest "suspended" action, and whether it has ended.
 */
export function suspensionRows(suspensions, actions, now) {
  const names = new Map();
  const latest = new Map();
  for (const a of [...actions].sort((x, y) => x.created - y.created)) {
    if (a.fields.action !== 'suspended') continue;
    latest.set(a.fields.targetRecordName, a.created);
    try {
      const snap = JSON.parse(a.fields.snapshot ?? '{}');
      if (snap.authorName) names.set(a.fields.targetRecordName, snap.authorName);
    } catch { /* an unreadable snapshot names no one */ }
  }
  return suspensions
    .map((s) => {
      const until = s.fields.until ?? null;
      const account = s.fields.accountRecordName;
      return {
        account,
        recordName: s.recordName,
        until,
        ended: until !== null && until <= now,
        authorName: names.get(account) ?? '',
        // The latest suspension of the account, which a re-suspend replaces.
        created: Math.max(s.created, latest.get(account) ?? 0),
      };
    })
    .sort((a, b) => b.created - a.created);
}

// MARK: - Trail nominations and featured trails

/** The latest trail action per trail key. Only `targetType` "trail" counts. */
function latestActions(actions) {
  const last = new Map();
  for (const a of actions) {
    const t = a.fields.targetRecordName;
    if (!t || a.fields.targetType !== 'trail') continue;
    const prev = last.get(t);
    if (!prev || a.created > prev.created) last.set(t, a);
  }
  return last;
}

/**
 * A trail key as the pack builder makes it: a two-letter region, a colon,
 * then the source ref. Nominations are written by any iCloud user, so
 * anything else is ignored.
 */
export function isTrailKey(key) {
  return typeof key === 'string' && /^[a-z]{2}:[A-Za-z0-9/_.:-]{1,80}$/.test(key);
}

/** A nomination's trail, or null when its key, name or point isn't usable. */
function trailOf(n) {
  const f = n.fields;
  if (!isTrailKey(f.trailKey) || typeof f.trailName !== 'string' || !f.trailName.trim()) return null;
  if (!mapsLink(f.latitude, f.longitude, f.trailName)) return null;
  return { trailKey: f.trailKey, trailName: f.trailName.trim(), region: f.trailKey.slice(0, 2),
           latitude: f.latitude, longitude: f.longitude, lengthMeters: Number.isFinite(f.lengthMeters) ? f.lengthMeters : 0 };
}

/**
 * Nominations grouped by trail (`trailKey`). The trail is described as most
 * nominations describe it (name, and point to ~100 m), not by the newest:
 * one crafted nomination can't rename or move it. `names` lists every name
 * used, and `disagree` says they differ. A trail is open while it has a
 * nomination newer than its latest trail action; count, notes and order use
 * only those.
 */
export function groupNominations(nominations, actions = []) {
  const last = latestActions(actions);
  const groups = new Map();
  for (const n of nominations) {
    const trail = trailOf(n);
    if (!trail) continue;
    let g = groups.get(trail.trailKey);
    if (!g) {
      g = { trailKey: trail.trailKey, nominations: [], latestAt: n.created, votes: new Map() };
      groups.set(trail.trailKey, g);
    }
    g.nominations.push(n);
    g.latestAt = Math.max(g.latestAt, n.created);
    const id = `${trail.trailName.toLowerCase()}|${trail.latitude.toFixed(3)}|${trail.longitude.toFixed(3)}`;
    const v = g.votes.get(id) ?? { trail, count: 0, first: n.created };
    v.count += 1;
    v.first = Math.min(v.first, n.created);
    g.votes.set(id, v);
  }
  return [...groups.values()].map(({ votes, ...rest }) => {
    // Most nominations first; on a tie, the description that came first.
    const ranked = [...votes.values()].sort((a, b) => b.count - a.count || a.first - b.first);
    return {
      ...rest,
      trail: ranked[0].trail,
      names: [...new Set(ranked.map((v) => v.trail.trailName))],
      // Every description given, with how many gave it, so a moved point
      // shows even when the names agree.
      variants: ranked.map((v) => ({ trail: v.trail, count: v.count })),
      disagree: ranked.length > 1,
    };
  }).map((g) => {
    const action = last.get(g.trailKey) ?? null;
    const fresh = action ? g.nominations.filter((n) => n.created > action.created) : g.nominations;
    const notes = fresh
      .filter((n) => (n.fields.note ?? '').trim() !== '')
      .sort((a, b) => b.created - a.created)
      .map((n) => ({ note: n.fields.note.trim(), at: n.created }));
    return { ...g, count: g.nominations.length, newCount: fresh.length, notes, lastAction: action, open: fresh.length > 0 };
  });
}

/** Open trails, most nominated first (ties: newest), or newest first. */
export function nominationQueue(groups, order = 'most', actedAt = new Map()) {
  const open = groups.filter((g) => g.open && !(actedAt.has(g.trailKey) && g.latestAt <= actedAt.get(g.trailKey)));
  return open.sort(order === 'newest'
    ? (a, b) => b.latestAt - a.latestAt
    : (a, b) => b.newCount - a.newCount || b.latestAt - a.latestAt);
}

export const BLURB_LIMIT = 200;

export const FEATURE_LENGTHS = {
  '30d': { label: '30 days', days: 30 },
  '90d': { label: '90 days', days: 90 },
  open: { label: 'Until I unfeature it', days: null },
};

export function featureUntil(length, now) {
  if (!Object.hasOwn(FEATURE_LENGTHS, length)) throw new Error(`Unknown length: ${length}`);
  const { days } = FEATURE_LENGTHS[length];
  return days === null ? null : now + days * DAY;
}

/** `featured.nc.w123`: one record per trail. */
export function featuredRecordName(trailKey) {
  const name = `featured.${String(trailKey ?? '').replace(/:/g, '.')}`;
  if (!trailKey || !isValidRecordName(name)) throw new Error('Not a trail.');
  return name;
}

/** The FeaturedTrail record's fields; `until` typed, absent when open-ended. */
export function featuredFields(trail, blurb, until) {
  const text = String(blurb ?? '').trim().slice(0, BLURB_LIMIT);
  if (!text) throw new Error('A featured trail needs a note.');
  if (!isTrailKey(trail?.trailKey) || !String(trail.trailName ?? '').trim()
      || !mapsLink(trail.latitude, trail.longitude, trail.trailName)) {
    throw new Error('This trail has no usable name or location, so phones couldn\'t show it.');
  }
  const fields = {
    trailKey: trail.trailKey,
    trailName: trail.trailName,
    region: trail.region ?? '',
    latitude: trail.latitude,
    longitude: trail.longitude,
    lengthMeters: trail.lengthMeters ?? 0,
    blurb: text,
  };
  if (until !== null) fields.until = { value: until, type: 'TIMESTAMP' };
  return fields;
}

/**
 * An Apple Maps link to a point, or null. Built only from the two numbers
 * and the encoded name, so no user text can become a URL of its own.
 */
export function mapsLink(latitude, longitude, name) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  return `https://maps.apple.com/?ll=${latitude.toFixed(5)},${longitude.toFixed(5)}&q=${encodeURIComponent(String(name ?? 'Trail'))}`;
}

/** The Featured tab's rows, newest first, with whether each has ended. */
export function featuredRows(records, now) {
  return records
    .map((r) => {
      const until = r.fields.until ?? null;
      return {
        recordName: r.recordName,
        trail: { trailKey: r.fields.trailKey, trailName: r.fields.trailName ?? r.fields.trailKey, region: r.fields.region ?? '',
                 latitude: r.fields.latitude, longitude: r.fields.longitude, lengthMeters: r.fields.lengthMeters ?? 0 },
        blurb: r.fields.blurb ?? '',
        until,
        ended: until !== null && until <= now,
        created: r.created,
      };
    })
    .sort((a, b) => b.created - a.created);
}

// MARK: - Walker reports (spec feat/trail-walker-reports)
//
// After a hike, walkers answer a few chips about the trail (walker-facts.js).
// Each answer is a `TrailFactReport` that only a Moderator can read: grouped
// by creator, world-readable reports would be a list of the trails one
// account walked. Here they are counted per trail and fact, Joe's rule says
// whether the walkers agree, and Publish writes a `TrailFactSummary` that
// everyone reads. A summary holds the trail key, its region, the fact, the
// winning value, the number of walkers and when it was computed. Nothing
// about who reported.
//
// A report record here carries `reporter`: an opaque token ck.js gives each
// creator for this page load (`walker-1`, …), never the account itself. It
// is used only to count each walker once.

/** Joe's rule (2026-10-15): at least this many distinct walkers answered the fact… */
export const MIN_REPORTERS = 3;
/** …and at least this share of them (2/3, kept as a fraction so 2 of 3 is exact) gave one value. */
export const AGREEMENT = Object.freeze({ numerator: 2, denominator: 3 });
/** Reports older than this many months are deleted from the dashboard (Joe, 2026-10-15). */
export const RETENTION_MONTHS = 12;

/** Whether `fact` is one of the closed vocabulary's facts. */
export function knownFact(fact) {
  return typeof fact === 'string' && Object.hasOwn(WALKER_FACTS, fact);
}

/** Whether `value` is one of `fact`'s values. */
export function knownValue(fact, value) {
  return knownFact(fact) && typeof value === 'string' && Object.hasOwn(WALKER_FACTS[fact].values, value);
}

/** Whether a summary may ever be published for `fact` (`liked` may not). */
export function isPublishableFact(fact) {
  return knownFact(fact) && WALKER_FACTS[fact].publish === true;
}

export function factLabel(fact) {
  return knownFact(fact) ? WALKER_FACTS[fact].label : String(fact ?? '');
}

export function valueLabel(fact, value) {
  return knownValue(fact, value) ? WALKER_FACTS[fact].values[value] : String(value ?? '');
}

/**
 * The verdict for one trail and fact from how many distinct walkers gave each
 * value (`{ value: walkers }`). Pure, and the whole of Joe's rule:
 * - `countedOnly`: the fact is never published (`liked`);
 * - `tooFew`: fewer than MIN_REPORTERS walkers answered;
 * - `tie`: two values share the most walkers (nothing wins a tie);
 * - `split`: the top value has less than AGREEMENT of the walkers;
 * - `ready`: publishable, with `value` and `agreeing`.
 * `walkers` is everyone who answered the fact; it is what a summary states.
 */
export function walkerVerdict(fact, counts) {
  const entries = Object.entries(counts ?? {})
    .filter(([value, n]) => knownValue(fact, value) && Number.isInteger(n) && n > 0)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const walkers = entries.reduce((sum, [, n]) => sum + n, 0);
  const base = { walkers, value: null, agreeing: entries[0]?.[1] ?? 0 };
  if (!isPublishableFact(fact)) return { ...base, status: 'countedOnly', publish: false };
  if (walkers < MIN_REPORTERS) return { ...base, status: 'tooFew', publish: false };
  if (entries.length > 1 && entries[0][1] === entries[1][1]) return { ...base, status: 'tie', publish: false };
  const [value, agreeing] = entries[0];
  // agreeing / walkers >= numerator / denominator, in whole numbers.
  if (agreeing * AGREEMENT.denominator < walkers * AGREEMENT.numerator) return { ...base, status: 'split', publish: false };
  return { walkers, value, agreeing, status: 'ready', publish: true };
}

/** The verdict in words, for the dashboard. */
export function verdictText(fact, verdict) {
  switch (verdict.status) {
    case 'ready':
      return `Ready to publish: ${valueLabel(fact, verdict.value)} (${verdict.agreeing} of ${verdict.walkers} walkers agree)`;
    case 'countedOnly':
      return 'Counted only. No summary is published for this (Joe\'s decision, 2026-10-15); the app doesn\'t show it.';
    case 'tooFew':
      return `Not enough walkers yet: ${verdict.walkers} of the ${MIN_REPORTERS} needed`;
    case 'tie':
      return 'Walkers are tied, so nothing is published';
    case 'split':
      return `Walkers disagree: the most given answer has ${verdict.agreeing} of ${verdict.walkers}, under 2/3`;
    default:
      return '';
  }
}

/**
 * Reports counted per trail and fact. Each walker counts once per trail and
 * fact, with their newest answer: the app names a report so CloudKit refuses a
 * second, but any client can create records under other names. Reports with
 * an unknown fact or value, or an impossible trail key, are ignored and
 * counted in `ignored`; reports whose walker is unknown can't be counted once
 * each, so they are left out and counted in `unattributed`.
 * The region is the key's, never the report's own say-so.
 */
export function tallyWalkerReports(reports) {
  const newest = new Map();
  let ignored = 0;
  let unattributed = 0;
  for (const r of reports) {
    const f = r.fields ?? {};
    if (!isTrailKey(f.trailKey) || !knownValue(f.fact, f.value)) { ignored += 1; continue; }
    if (typeof r.reporter !== 'string' || !r.reporter) { unattributed += 1; continue; }
    const id = `${r.reporter}\n${f.trailKey}\n${f.fact}`;
    const prev = newest.get(id);
    if (!prev || r.created > prev.created) newest.set(id, r);
  }
  const trails = new Map();
  for (const r of newest.values()) {
    const { trailKey, fact, value } = r.fields;
    let t = trails.get(trailKey);
    if (!t) {
      t = { trailKey, region: trailKey.slice(0, 2), latestAt: r.created, reports: 0, facts: new Map() };
      trails.set(trailKey, t);
    }
    t.latestAt = Math.max(t.latestAt, r.created);
    t.reports += 1;
    const counts = t.facts.get(fact) ?? {};
    counts[value] = (counts[value] ?? 0) + 1;
    t.facts.set(fact, counts);
  }
  const factOrder = Object.keys(WALKER_FACTS);
  return {
    ignored,
    unattributed,
    trails: [...trails.values()].map((t) => ({
      trailKey: t.trailKey,
      region: t.region,
      latestAt: t.latestAt,
      reports: t.reports,
      facts: [...t.facts.entries()]
        .sort((a, b) => factOrder.indexOf(a[0]) - factOrder.indexOf(b[0]))
        .map(([fact, counts]) => ({
          fact,
          counts: Object.keys(WALKER_FACTS[fact].values).map((value) => ({ value, walkers: counts[value] ?? 0 })),
          verdict: walkerVerdict(fact, counts),
        })),
    })).sort((a, b) => b.latestAt - a.latestAt),
  };
}

/**
 * A trail key a summary can be named after: the region, a colon and a plain
 * ref (`nc:w123`), so turning the colon into a dot can't make two keys one
 * name. A key with dots, slashes or a second colon is refused, not guessed.
 */
export function isSummaryKey(key) {
  return typeof key === 'string' && /^[a-z]{2}:[A-Za-z0-9_-]{1,80}$/.test(key);
}

/**
 * `factsummary.dogs.nc.w123`: one record per trail and fact, so publishing
 * again replaces it and Un-publish knows what to delete. The app can name it
 * the same way.
 */
export function summaryRecordName(trailKey, fact) {
  if (!isSummaryKey(trailKey)) throw new Error(`Can't name a summary for the trail key "${trailKey}".`);
  if (!knownFact(fact)) throw new Error(`Unknown fact: ${fact}`);
  const name = `factsummary.${fact}.${trailKey.replace(':', '.')}`;
  if (!isValidRecordName(name)) throw new Error('Not a valid record name.');
  return name;
}

/**
 * The `TrailFactSummary` record's fields from one trail's counts for one
 * fact (`{ value: walkers }`). The rule is applied here, never trusted from a
 * caller, and the fields are built only from the key and the verdict:
 * nothing else can reach them. Refuses anything the rule doesn't allow,
 * including any `liked` summary.
 */
export function summaryFields(trailKey, fact, counts, now) {
  if (!isSummaryKey(trailKey)) throw new Error(`Can't publish for the trail key "${trailKey}".`);
  if (!isPublishableFact(fact)) throw new Error(`No summary is published for "${factLabel(fact)}".`);
  const verdict = walkerVerdict(fact, counts);
  if (!verdict.publish) throw new Error(`Not publishable: ${verdictText(fact, verdict)}.`);
  if (!Number.isFinite(now)) throw new Error('Not a time.');
  return {
    trailKey,
    region: trailKey.slice(0, 2),
    fact,
    value: verdict.value,
    walkers: verdict.walkers,
    computedAt: { value: now, type: 'TIMESTAMP' },
  };
}

/** `{ value: walkers }` from a tallied fact's `counts` list. */
export function countsOf(factRow) {
  return Object.fromEntries((factRow?.counts ?? []).map((c) => [c.value, c.walkers]));
}

/** The published summaries, as plain rows keyed by record name. Unknown facts or values are kept, flagged. */
export function summaryRows(records) {
  return records.map((r) => ({
    recordName: r.recordName,
    trailKey: r.fields.trailKey,
    fact: r.fields.fact,
    value: r.fields.value,
    walkers: r.fields.walkers,
    computedAt: r.fields.computedAt ?? null,
    created: r.created,
    known: knownValue(r.fields.fact, r.fields.value),
  }));
}

/**
 * How a published summary stands against the reports now:
 * `current` (same value and walkers), `outdated` (still ready, but a different
 * value or count: Publish updates it), `unsupported` (the reports no longer
 * clear the rule, or it's for a fact that is never published: Un-publish it).
 */
export function summaryStanding(summary, verdict) {
  if (!summary) return null;
  if (!verdict || !verdict.publish || !summary.known) return 'unsupported';
  return summary.value === verdict.value && summary.walkers === verdict.walkers ? 'current' : 'outdated';
}

/**
 * When the retention window starts: `months` calendar months before `now`,
 * in UTC. A day the earlier month lacks rolls over (29 Feb 2028 → 1 Mar 2027).
 */
export function retentionCutoff(now, months = RETENTION_MONTHS) {
  const d = new Date(now);
  if (!Number.isFinite(d.getTime())) throw new Error('Not a time.');
  d.setUTCMonth(d.getUTCMonth() - months);
  return d.getTime();
}

/** Reports created strictly before `cutoff`: the ones to delete. */
export function expiredReports(reports, cutoff) {
  return reports.filter((r) => Number.isFinite(r.created) && r.created < cutoff);
}
