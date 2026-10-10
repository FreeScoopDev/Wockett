// What Remove and Dismiss do, in order, against any store with ck.js's
// `query`, `create` and `delete`, so the order is tested with a fake one.

import {
  actionFields, buildSnapshot, removalPlan, suspensionUntil, suspensionRecordName, suspensionFields, ownedBy, TYPES,
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
 * Suspends an account. The "suspended" ModerationAction is written first;
 * then the Suspension record (replacing one already there). If the record
 * can't be saved, the action is taken back. With `removeItems`, each item
 * the account itself created under `authorName` is then removed as Remove
 * does (snapshot first); a failure there is reported, not thrown, because
 * the suspension already stands.
 */
export async function suspendAccount(store, {
  account, authorName = '', length, reason, note = '', now = Date.now(), removeItems = false,
}) {
  const recordName = suspensionRecordName(account);
  const until = suspensionUntil(length, now);
  const written = await store.create('ModerationAction', actionFields({
    target: account, type: 'account', action: 'suspended', reason, note,
    snapshot: JSON.stringify({ account, authorName, until }),
  }));
  try {
    await store.upsert('Suspension', recordName, suspensionFields(account, until));
  } catch (error) {
    try { await store.delete([written.recordName]); } catch { /* the error below is what matters */ }
    throw error;
  }
  const result = { until, removed: 0, removeError: null };
  if (!removeItems || !authorName) return result;
  for (const type of OWNED_TYPES) {
    try {
      const { records } = await store.query(TYPES[type].recordType, { equals: ['authorName', authorName], max: 2000 });
      for (const record of ownedBy(records, account)) {
        await removeItem(store, { type, record, reason, note: note || 'Removed with a suspension' });
        result.removed += 1;
      }
    } catch (error) {
      result.removeError = result.removeError ?? error;
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
