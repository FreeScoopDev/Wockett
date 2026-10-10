// What Remove and Dismiss do, in order, against any store with ck.js's
// `query`, `create` and `delete`, so the order is tested with a fake one.

import { actionFields, buildSnapshot, removalPlan } from './logic.js';

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
