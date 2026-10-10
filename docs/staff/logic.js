// The staff dashboard's rules, with no network and no page: grouping reports
// by item, open versus resolved, the removal snapshot, the activity counts and
// the route line. Tested by `node --test tests/staff/*.test.mjs` from the repo root.
//
// A record here is the adapter's plain shape (ck.js `plain`):
//   { recordName, recordType, created (ms since 1970), fields: { name: value },
//     creator (community items only: the author's account) }
// Who created a report is never part of it: the dashboard never shows who
// reported something.

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

export function reasonLabel(reason) {
  if (typeof reason === 'string' && Object.hasOwn(REASONS, reason)) return REASONS[reason];
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
export const NON_ITEM_TARGETS = ['trail', 'account'];

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
  return group?.reasons?.[0]?.reason ?? 'other';
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

export const ACTIONS = ['removed', 'dismissed', 'suspended', 'lifted', 'featured', 'unfeatured'];

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
