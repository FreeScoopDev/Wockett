// What Remove and Dismiss do, in order, against any store with ck.js's
// `query`, `create` and `delete`, so the order is tested with a fake one.

import {
  actionFields, buildSnapshot, removalPlan, suspensionUntil, suspensionRecordName, suspensionFields, ownedBy, TYPES,
  canSuspend, featureUntil, featuredRecordName, featuredFields,
  summaryRecordName, summaryFields, retentionCutoff, expiredReports, knownValue, walkerId,
} from './logic.js';

/**
 * Removes an item for everyone. The ModerationAction with the snapshot is
 * written first: if it can't be written, nothing is deleted. Then the item,
 * then what hangs off it. A record already gone counts as removed.
 * Returns how many related records were deleted, and the first error from
 * deleting them, if any (the item is removed either way).
 */
export async function removeItem(store, { type, record, reason, note = '', reportCount = 0 }) {
  const plan = removalPlan(type, record.recordName);
  const snapshot = buildSnapshot(record);
  const written = await store.create('ModerationAction', actionFields({
    target: record.recordName, type, action: 'removed', reason, note, reportCount, snapshot,
  }));
  try {
    await store.delete([plan.item.recordName]);
  } catch (error) {
    // The item is still up: take back the "removed" record, so History and
    // the queue don't say otherwise. If even that fails, the queue still
    // finds the live item (logic.js reopenFailedRemovals).
    try { await store.delete([written.recordName]); } catch { /* reported below */ }
    throw error;
  }
  let related = 0;
  let relatedError = null;
  for (const rel of plan.related) {
    // Found in full first, then deleted: re-querying after each delete can
    // return records CloudKit's index hasn't dropped yet. The item itself is
    // already gone, so a failure here is reported, not thrown.
    try {
      const { records } = await store.query(rel.recordType, { equals: [rel.field, rel.value], max: 10000 });
      if (records.length) await store.delete(records.map((r) => r.recordName));
      related += records.length;
    } catch (error) {
      relatedError = relatedError ?? error;
    }
  }
  return { related, relatedError };
}

/**
 * Closes an item's reports without removing it. For an item that is already
 * gone, `note` says so; there is nothing to snapshot.
 */
export async function dismissItem(store, { target, type, note = '', reportCount = 0 }) {
  await store.create('ModerationAction', actionFields({ target, type, action: 'dismissed', note, reportCount }));
}

/** The item types "Also remove their items" clears, in order. */
export const OWNED_TYPES = ['post', 'route', 'challenge'];

/**
 * Puts the Suspension record in place. An existing one is replaced in one
 * step (forceReplace), so no field of the old one (an end date when going
 * permanent) survives, and the account is never briefly unsuspended; if the
 * replace fails, the old one stands as it was. A new one is created.
 */
export async function replaceSuspension(store, account, until) {
  const recordName = suspensionRecordName(account);
  const fields = suspensionFields(account, until);
  const exists = (await store.fetch([recordName])).has(recordName);
  if (exists) await store.replaceNamed('Suspension', recordName, fields);
  else await store.createNamed('Suspension', recordName, fields);
}

/**
 * Suspends an account. Refused for the signed-in moderator's own account
 * and CloudKit's own-records placeholder. The "suspended" ModerationAction
 * is written first; then the Suspension record. If that fails, the action is
 * taken back. With `removeItems`, each item the account itself created
 * under `authorName` is then removed as Remove does (snapshot first), one at
 * a time: a failure skips that item only, and is counted, because the
 * suspension already stands.
 */
export async function suspendAccount(store, {
  account, authorName = '', length, reason, note = '', now = Date.now(), removeItems = false, moderator = null,
}) {
  if (!canSuspend(account, moderator)) throw new Error('This account can\'t be suspended (it is yours, or not an account).');
  const until = suspensionUntil(length, now);
  const written = await store.create('ModerationAction', actionFields({
    target: account, type: 'account', action: 'suspended', reason, note,
    snapshot: JSON.stringify({ account, authorName, length, until }),
  }));
  try {
    await replaceSuspension(store, account, until);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
  const result = { until, removed: 0, failed: 0, relatedLeft: 0, firstError: null };
  if (!removeItems || !authorName) return result;
  for (const type of OWNED_TYPES) {
    let records = [];
    try {
      ({ records } = await store.query(TYPES[type].recordType, { equals: ['authorName', authorName], max: 2000 }));
    } catch (error) {
      result.firstError = result.firstError ?? error;
      result.failed += 1;
      continue;
    }
    for (const record of ownedBy(records, account)) {
      try {
        const { relatedError } = await removeItem(store, { type, record, reason, note: note || 'Removed with a suspension' });
        result.removed += 1;
        if (relatedError) {
          result.relatedLeft += 1;
          result.firstError = result.firstError ?? relatedError;
        }
      } catch (error) {
        result.failed += 1;
        result.firstError = result.firstError ?? error;
      }
    }
  }
  return result;
}

/** Their items: what the account itself created under its name, by type. */
export async function itemsOf(store, { account, authorName }) {
  const out = {};
  for (const type of OWNED_TYPES) {
    const { records } = await store.query(TYPES[type].recordType, { equals: ['authorName', authorName], max: 2000 });
    out[type] = ownedBy(records, account);
  }
  return out;
}

/**
 * Lifts a suspension: a "lifted" action, then the record deleted. If the
 * delete fails, the action is taken back.
 */
export async function liftSuspension(store, { account, note = '' }) {
  const written = await store.create('ModerationAction', actionFields({
    target: account, type: 'account', action: 'lifted', note,
  }));
  try {
    await store.delete([suspensionRecordName(account)]);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
}

/**
 * Features a trail. The "featured" ModerationAction is written first (with
 * the trail and the note); then the FeaturedTrail record, replaced in one
 * step if the trail is already featured. If that fails, the action is taken
 * back.
 */
export async function featureTrail(store, { trail, blurb, length, keepUntil, now = Date.now() }) {
  // `keepUntil` (a time, or null for no end) keeps the current end when only the note changes.
  const until = keepUntil !== undefined ? keepUntil : featureUntil(length, now);
  const recordName = featuredRecordName(trail.trailKey);
  const existing = (await store.fetch([recordName])).get(recordName) ?? null;
  // Featuring again keeps the trail as first featured: the name and point the
  // app matches by stay the ones Joe checked, whatever later nominations say.
  // Only the note and the end change.
  const shown = existing ? {
    trailKey: trail.trailKey,
    trailName: existing.fields.trailName ?? trail.trailName,
    region: existing.fields.region ?? trail.region,
    latitude: existing.fields.latitude ?? trail.latitude,
    longitude: existing.fields.longitude ?? trail.longitude,
    lengthMeters: existing.fields.lengthMeters ?? trail.lengthMeters,
  } : trail;
  const fields = featuredFields(shown, blurb, until);
  const written = await store.create('ModerationAction', actionFields({
    target: trail.trailKey, type: 'trail', action: 'featured', note: fields.blurb,
    snapshot: JSON.stringify({ trail: shown, blurb: fields.blurb, length: keepUntil !== undefined ? 'kept' : length, until }),
  }));
  try {
    if (existing) await store.replaceNamed('FeaturedTrail', recordName, fields);
    else await store.createNamed('FeaturedTrail', recordName, fields);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
  return { until };
}

/** Unfeatures a trail: an "unfeatured" action, then the record deleted; taken back if that fails. */
export async function unfeatureTrail(store, { trail, note = '' }) {
  const written = await store.create('ModerationAction', actionFields({
    target: trail.trailKey, type: 'trail', action: 'unfeatured', note,
    snapshot: JSON.stringify({ trail }),
  }));
  try {
    await store.delete([featuredRecordName(trail.trailKey)]);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
}

/** Clears a trail's nominations without featuring it; they come back if it's nominated again. */
export async function dismissNominations(store, { trail, note = '', count = 0 }) {
  await store.create('ModerationAction', actionFields({
    target: trail.trailKey, type: 'trail', action: 'dismissed', note, reportCount: count,
    snapshot: JSON.stringify({ trail }),
  }));
}

// MARK: - Walker reports

/**
 * Publishes what walkers say about one trail and fact: a "published"
 * ModerationAction first (the counts, never who gave them), then the
 * `TrailFactSummary`, replaced in one step if one is already published. If
 * that fails, the action is taken back. `counts` is `{ value: walkers }`;
 * `summaryFields` applies Joe's rule to it and refuses anything it doesn't
 * allow (too few walkers, a tie or split, `liked`), before anything is written.
 */
export async function publishSummary(store, { trailKey, fact, counts, now = Date.now() }) {
  const fields = summaryFields(trailKey, fact, counts, now);
  const recordName = summaryRecordName(trailKey, fact);
  const exists = (await store.fetch([recordName])).has(recordName);
  const written = await store.create('ModerationAction', actionFields({
    target: recordName, type: 'trailFact', action: 'published', reportCount: fields.walkers,
    snapshot: JSON.stringify({ trailKey, fact, value: fields.value, walkers: fields.walkers,
      counts: Object.fromEntries(Object.entries(counts).filter(([v, n]) => knownValue(fact, v) && Number.isInteger(n))) }),
  }));
  try {
    if (exists) await store.replaceNamed('TrailFactSummary', recordName, fields);
    else await store.createNamed('TrailFactSummary', recordName, fields);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
  return { recordName, fields };
}

/**
 * Withdraws a published summary: an "unpublished" action, then the record
 * deleted; the action is taken back if the delete fails. Phones drop it at
 * their next refresh.
 */
export async function unpublishSummary(store, { trailKey, fact, recordName: given, note = '' }) {
  // The summary's own record name when the page has it (one made by hand in
  // the Console may not follow the naming rule); otherwise the rule's.
  const recordName = given ?? summaryRecordName(trailKey, fact);
  const written = await store.create('ModerationAction', actionFields({
    target: recordName, type: 'trailFact', action: 'unpublished', note,
    snapshot: JSON.stringify({ trailKey, fact }),
  }));
  try {
    await store.delete([recordName]);
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
  return { recordName };
}

/**
 * The walker reports older than the retention window (12 months before
 * `now`), for the confirm dialog to count. `more` says there were more than
 * one load holds: run the delete again afterwards.
 */
export async function findExpiredReports(store, { now = Date.now(), max = 5000 } = {}) {
  const cutoff = retentionCutoff(now);
  const { records, more } = await store.query('TrailFactReport', { beforeMs: cutoff, max });
  // Filtered here too: the query's own filter is not trusted to be exact.
  return { cutoff, records: expiredReports(records, cutoff), more };
}

/**
 * Deletes the expired reports found by `findExpiredReports`: an "expired"
 * action with the count first, then the reports, 200 at a time. Only reports
 * created before `cutoff` are ever deleted, whatever is passed. Published
 * summaries are never touched. If nothing could be deleted, the action is
 * taken back and the error thrown; a failure part-way returns how many were
 * deleted and the error, and the action stays (the deleted ones are gone).
 */
export async function deleteExpiredReports(store, { records, cutoff }) {
  if (!Number.isFinite(cutoff)) throw new Error('No cutoff.');
  const names = expiredReports(records, cutoff).map((r) => r.recordName);
  if (!names.length) return { deleted: 0, error: null };
  const written = await store.create('ModerationAction', actionFields({
    target: 'TrailFactReport', type: 'walkerReports', action: 'expired', reportCount: names.length,
    snapshot: JSON.stringify({ cutoff, count: names.length }),
  }));
  return deleteInChunks(store, names, written);
}

/**
 * Deletes `names` 200 at a time after the action `written`. If nothing
 * could be deleted, the action is taken back and the error thrown; a failure
 * part-way returns how many were deleted and the error, and the action stays.
 */
async function deleteInChunks(store, names, written) {
  let deleted = 0;
  for (let i = 0; i < names.length; i += 200) {
    const chunk = names.slice(i, i + 200);
    try {
      await store.delete(chunk);
      deleted += chunk.length;
    } catch (error) {
      if (deleted === 0) {
        try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
        throw error;
      }
      return { deleted, error };
    }
  }
  return { deleted, error: null };
}

/**
 * The walker reports one person made, for a request to delete them (by
 * email, with the identifier the app shows them: their CloudKit user record
 * name). Refuses anything that isn't such an id before asking CloudKit.
 */
export async function findReportsBy(store, { identifier, max = 5000 }) {
  const account = walkerId(identifier);
  if (!account) throw new Error('That isn\'t a Wockett identifier: it starts with _ and has only letters and digits.');
  const { records, more } = await store.queryByCreator('TrailFactReport', account, { max });
  return { account, records, more };
}

/**
 * Deletes the reports `findReportsBy` found: an "erased" action with the
 * count first (never the identifier: the request was to remove their data),
 * then the reports, 200 at a time, as the 12-month delete does. Published
 * summaries are not touched; they hold no one's answers, only counts.
 */
export async function deleteReportsBy(store, { records }) {
  const names = records.filter((r) => r?.recordType === 'TrailFactReport').map((r) => r.recordName);
  if (!names.length) return { deleted: 0, error: null };
  const written = await store.create('ModerationAction', actionFields({
    target: 'TrailFactReport', type: 'walkerReports', action: 'erased', reportCount: names.length,
    snapshot: JSON.stringify({ count: names.length }),
  }));
  return deleteInChunks(store, names, written);
}
