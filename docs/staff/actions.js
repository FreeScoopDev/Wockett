// What Remove and Dismiss do, in order, against any store with ck.js's
// `query`, `create` and `delete`, so the order is tested with a fake one.

import { actionFields, buildSnapshot, removalPlan } from './logic.js';

/**
 * Removes an item for everyone. The ModerationAction with the snapshot is
 * written first: if it can't be written, nothing is deleted. Then the item,
 * then what hangs off it. A record already gone counts as removed.
 * Returns the number of related records deleted.
 */
export async function removeItem(store, { type, record, reason, note = '', reportCount = 0 }) {
  const plan = removalPlan(type, record.recordName);
  const snapshot = buildSnapshot(record);
  await store.create('ModerationAction', actionFields({
    target: record.recordName, type, action: 'removed', reason, note, reportCount, snapshot,
  }));
  await store.delete([plan.item.recordName]);
  let related = 0;
  for (const rel of plan.related) {
    // Found in full first, then deleted: re-querying after each delete can
    // return records CloudKit's index hasn't dropped yet.
    const { records } = await store.query(rel.recordType, { equals: [rel.field, rel.value], max: 10000 });
    if (records.length) await store.delete(records.map((r) => r.recordName));
    related += records.length;
  }
  return related;
}

/**
 * Closes an item's reports without removing it. For an item that is already
 * gone, `note` says so; there is nothing to snapshot.
 */
export async function dismissItem(store, { target, type, note = '', reportCount = 0 }) {
  await store.create('ModerationAction', actionFields({ target, type, action: 'dismissed', note, reportCount }));
}
