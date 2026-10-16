// What Remove and Dismiss do, in order, against any store with ck.js's
// `query`, `create` and `delete`, so the order is tested with a fake one.

import {
  actionFields, buildSnapshot, removalPlan, suspensionUntil, suspensionRecordName, suspensionFields, ownedBy, TYPES,
  canSuspend, featureUntil, featuredRecordName, featuredFields,
  summaryRecordName, summaryFields, retentionCutoff, expiredReports, knownValue, walkerId, walkerVerdict,
  contributionStatusFields, nominationStatusNames, statusDecidedAt, statusesToWithdraw,
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
  // `trail`: the trail as featured, which is what a nominator's status names.
  return { until, trail: shown };
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
  // The same verdict summaryFields applied: History's numbers can't drift from it.
  const verdict = walkerVerdict(fact, counts);
  const known = Object.fromEntries(Object.entries(counts).filter(([v, n]) => knownValue(fact, v) && Number.isInteger(n) && n > 0));
  const written = await store.create('ModerationAction', actionFields({
    // reportCount: every walker counted for this fact; the snapshot's `walkers`
    // is how many gave the published answer (what the app shows).
    target: recordName, type: 'trailFact', action: 'published', reportCount: verdict.walkers,
    snapshot: JSON.stringify({ trailKey, fact, value: fields.value, walkers: fields.walkers, counts: known }),
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
 * one load can hold: run the delete again afterwards for the rest.
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
  const fields = actionFields({
    target: 'TrailFactReport', type: 'walkerReports', action: 'expired', reportCount: names.length,
    snapshot: JSON.stringify({ cutoff, count: names.length }),
  });
  const written = await store.create('ModerationAction', fields);
  return deleteInChunks(store, names, written, fields);
}

/**
 * Deletes `names` 200 at a time after the action `written` (sent as `fields`). A batch can fail
 * part-way (the store's error says how many of it were deleted, `deleted`).
 * If nothing was deleted, the action is taken back and the error thrown.
 * Otherwise the action stays, corrected to the number really deleted, and
 * that number is returned with the error.
 */
async function deleteInChunks(store, names, written, fields) {
  let deleted = 0;
  for (let i = 0; i < names.length; i += 200) {
    const chunk = names.slice(i, i + 200);
    try {
      await store.delete(chunk);
      deleted += chunk.length;
    } catch (error) {
      const partly = Number.isInteger(error?.deleted) ? Math.min(Math.max(error.deleted, 0), chunk.length) : 0;
      deleted += partly;
      if (deleted === 0) {
        try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
        throw error;
      }
      try {
        // Rebuilt from what was sent, not the server's copy: a replace keeps
        // no field it isn't given.
        await store.replaceNamed('ModerationAction', written.recordName, {
          ...fields, reportCount: deleted,
          note: `Stopped part-way: ${deleted} of ${names.length} deleted.`,
          snapshot: JSON.stringify({ ...JSON.parse(fields.snapshot), count: deleted, planned: names.length }),
        });
      } catch { /* History keeps the planned count; the error below is what matters */ }
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
  const fields = actionFields({
    target: 'TrailFactReport', type: 'walkerReports', action: 'erased', reportCount: names.length,
    snapshot: JSON.stringify({ count: names.length }),
  });
  const written = await store.create('ModerationAction', fields);
  return deleteInChunks(store, names, written, fields);
}

// MARK: - Contribution status (spec feat/contribution-status)

const NOMINATION = { kind: 'nomination', status: 'featured' };

/**
 * Tells a featured trail's nominators: one `ContributionStatus` per
 * nomination of the trail that carries a claim token (ck.js has already
 * turned each token into its record name, `statusName`; the token never
 * reaches here). Called after `featureTrail` has succeeded, with the trail
 * as featured. Nominations without a token get nothing, and none at all
 * writes nothing: no History, no error.
 *
 * Before anything is written, `ContributionStatus` is queried: if the
 * environment's schema lacks the type, the first save would create it with
 * CloudKit's default grants (anyone could create statuses), so nothing is
 * written and the query's error is thrown.
 *
 * A name already held by a record of another type is skipped and counted in
 * `blocked`: nominations are created by anyone, under a record name they
 * choose, so a crafted one could otherwise stop every nominator of the trail
 * from being told.
 *
 * A "statusPublished" ModerationAction with the count comes first (never a
 * token, a status name or a nominator); then each record, created, or
 * replaced when it exists, so publishing again rewrites the same records.
 * One failed record doesn't stop the rest. If none could be written, the
 * action is taken back and the first error thrown; otherwise the action is
 * corrected to the number written, returned with the first error.
 */
export async function publishNominationStatuses(store, { trail, now = Date.now() }) {
  const { records: nominations } = await store.query('TrailNomination', { equals: ['trailKey', trail.trailKey], max: 5000 });
  const { names, withoutToken } = nominationStatusNames(nominations, trail.trailKey);
  if (!names.length) return { written: 0, planned: 0, blocked: 0, withoutToken, error: null };
  // Checked before anything is written: a trail with no usable name or key
  // throws here, with nothing to take back.
  contributionStatusFields({ ...NOMINATION, trailKey: trail.trailKey, trailName: trail.trailName, decidedAt: now });
  await store.query('ContributionStatus', { equals: ['trailKey', trail.trailKey], max: 1 });
  const existing = await store.fetch(names);
  const todo = names.filter((n) => !existing.has(n) || existing.get(n)?.recordType === 'ContributionStatus');
  const blocked = names.length - todo.length;
  if (!todo.length) return { written: 0, planned: 0, blocked, withoutToken, error: null };
  const fields = actionFields({
    target: trail.trailKey, type: 'contribution', action: 'statusPublished', reportCount: todo.length,
    snapshot: JSON.stringify({ trailKey: trail.trailKey, trailName: trail.trailName, ...NOMINATION, count: todo.length }),
  });
  const written = await store.create('ModerationAction', fields);
  let done = 0;
  let firstError = null;
  for (const name of todo) {
    const decidedAt = statusDecidedAt(existing.get(name), { ...NOMINATION, trailKey: trail.trailKey }, now);
    const record = contributionStatusFields({ ...NOMINATION, trailKey: trail.trailKey, trailName: trail.trailName, decidedAt });
    try {
      if (existing.has(name)) await store.replaceNamed('ContributionStatus', name, record);
      else await store.createNamed('ContributionStatus', name, record);
      done += 1;
    } catch (error) {
      firstError = firstError ?? error;
    }
  }
  if (done < todo.length) {
    await settleHistory(store, written, fields, done, todo.length, 'written');
    if (done === 0) throw firstError;
  }
  return { written: done, planned: todo.length, blocked, withoutToken, error: firstError };
}

/**
 * The trail's nomination statuses, for Unfeature to count before it asks.
 * Filtered here too: the query's own filter is not trusted to be exact.
 */
export async function findNominationStatuses(store, { trailKey }) {
  const { records, more } = await store.query('ContributionStatus', { equals: ['trailKey', trailKey], max: 5000 });
  return { records: statusesToWithdraw(records, trailKey, NOMINATION.kind, NOMINATION.status), more };
}

/**
 * Withdraws the statuses `findNominationStatuses` found (only this trail's
 * nomination statuses, whatever is passed): a "statusWithdrawn" action with
 * the count first, then the records, 200 at a time. Phones drop "Featured"
 * when the record is gone. Nothing to withdraw writes nothing. A first
 * failure takes the action back and throws; a later one keeps the action,
 * corrected to the number deleted, and returns it with the error.
 */
export async function withdrawNominationStatuses(store, { trail, records }) {
  const names = statusesToWithdraw(records, trail.trailKey, NOMINATION.kind, NOMINATION.status).map((r) => r.recordName);
  if (!names.length) return { deleted: 0, error: null };
  const fields = actionFields({
    target: trail.trailKey, type: 'contribution', action: 'statusWithdrawn', reportCount: names.length,
    snapshot: JSON.stringify({ trailKey: trail.trailKey, trailName: trail.trailName, ...NOMINATION, count: names.length }),
  });
  const written = await store.create('ModerationAction', fields);
  return deleteInChunks(store, names, written, fields);
}

/**
 * After a failure part-way through writing statuses: nothing written takes
 * the action back; some written corrects it to that number. Rebuilt from the
 * fields sent, as `deleteInChunks` does.
 */
async function settleHistory(store, written, fields, done, planned, verb) {
  try {
    if (done === 0) {
      await store.delete([written.recordName]);
      return;
    }
    await store.replaceNamed('ModerationAction', written.recordName, {
      ...fields, reportCount: done,
      note: `Stopped part-way: ${done} of ${planned} ${verb}.`,
      snapshot: JSON.stringify({ ...JSON.parse(fields.snapshot), count: done, planned }),
    });
  } catch { /* the caller reports the original error */ }
}

/**
 * Feature, then tell the nominators. The feature stands whatever happens to
 * the statuses: a failure there comes back as `told.error` (Feature again
 * finishes the job, since publishing again rewrites the same records), never
 * as a thrown error that would read as "not featured".
 */
export async function featureTrailAndTell(store, options) {
  const out = await featureTrail(store, options);
  let told;
  try {
    told = await publishNominationStatuses(store, { trail: out.trail, now: options.now ?? Date.now() });
  } catch (error) {
    told = { written: 0, planned: null, blocked: 0, withoutToken: 0, error };
  }
  return { ...out, told };
}

/**
 * Unfeature, withdrawing the nominators' statuses first (`statuses`, from
 * `findNominationStatuses`). Withdrawn first so that a failure stops before
 * the trail leaves Featured, and Unfeature can simply be tried again: a
 * failure on the first batch throws; one part-way returns `unfeatured: false`
 * with the count and the error. If the statuses are withdrawn but the
 * unfeature itself then fails, that also returns `unfeatured: false`, with
 * how many were withdrawn, so the page can say the trail is still featured
 * while its nominators see Sent.
 */
export async function unfeatureTrailAndWithdraw(store, { trail, statuses = [], note = '' }) {
  const withdrawn = await withdrawNominationStatuses(store, { trail, records: statuses });
  if (withdrawn.error) return { unfeatured: false, withdrawn, error: withdrawn.error };
  if (!withdrawn.deleted) {
    await unfeatureTrail(store, { trail, note });
    return { unfeatured: true, withdrawn, error: null };
  }
  try {
    await unfeatureTrail(store, { trail, note });
  } catch (error) {
    return { unfeatured: false, withdrawn, error };
  }
  return { unfeatured: true, withdrawn, error: null };
}
