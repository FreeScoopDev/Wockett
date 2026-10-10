// The one place the dashboard talks to CloudKit JS (Apple's library, loaded
// from Apple's CDN by index.html). Everything else works on plain records, so
// the rules in logic.js are tested without a network.
//
import { isGone, isValidRecordName } from './logic.js';

// Every call is made as the signed-in iCloud user. CloudKit's roles decide
// what that user may read, write and delete; this file grants nothing.

/**
 * Record types whose creator the page may know: community content, where
 * the creator is the author (public anyway, and what Suspend acts on).
 * Never a report: who reported something stays out of the page.
 */
export const CREATOR_TYPES = new Set(['SharedRoute', 'WocketAchievement', 'Challenge', 'ChallengeEntry', 'CommunityName']);

/** A CloudKit JS record as the plain shape logic.js uses. */
export function plain(record) {
  const fields = {};
  for (const [key, field] of Object.entries(record.fields ?? {})) fields[key] = field?.value;
  const out = {
    recordName: record.recordName,
    recordType: record.recordType,
    created: record.created?.timestamp ?? 0,
    fields,
  };
  const creator = record.created?.userRecordName;
  if (creator && CREATOR_TYPES.has(record.recordType)) out.creator = creator;
  return out;
}

/** Throws a response's first error, so every call fails the same way. */
function check(response) {
  if (response?.hasErrors) throw response.errors[0];
  return response;
}

/** Errors for records that are already gone are not failures when deleting. */
function onlyRealErrors(response) {
  const errors = (response?.errors ?? []).filter((e) => !isGone(e));
  if (errors.length) throw errors[0];
}

/**
 * The records that still exist among `recordNames`, by name. Names CloudKit
 * couldn't accept are skipped, and a per-record error leaves that name out
 * (shown as gone), so one crafted report can't stop the rest loading.
 */
export async function fetchExisting(db, recordNames) {
  const found = new Map();
  const names = recordNames.filter(isValidRecordName);
  for (let i = 0; i < names.length; i += 200) {
    const response = await db.fetchRecords(names.slice(i, i + 200));
    for (const r of response?.records ?? []) {
      if (r?.recordName && r.fields) found.set(r.recordName, plain(r));
    }
  }
  return found;
}

/**
 * Whether a query response has another page. CloudKit JS calls it
 * `moreComing`, with a `continuationMarker` for the next page; both are read
 * so a renamed property can't silently stop every query at one page.
 * Unverified against a live container until the Development run.
 */
export function hasMorePages(response) {
  return Boolean(response?.moreComing ?? response?.moreRecordsComing ?? response?.continuationMarker);
}

/** The query CloudKit JS is sent: newest first, optional equality and age filters. */
export function buildQuery(recordType, { equals, sinceMs } = {}) {
  const filterBy = [];
  if (equals) {
    filterBy.push({ fieldName: equals[0], comparator: 'EQUALS', fieldValue: { value: equals[1] } });
  }
  if (sinceMs !== undefined) {
    filterBy.push({ systemFieldName: 'createdTimestamp', comparator: 'GREATER_THAN_OR_EQUALS',
                    fieldValue: { value: sinceMs, type: 'TIMESTAMP' } });
  }
  return { recordType, filterBy, sortBy: [{ systemFieldName: 'createdTimestamp', ascending: false }] };
}

/**
 * One nomination per person per trail, the newest (records arrive newest
 * first). The app names a nomination so CloudKit refuses a second, but any
 * client can create records under other names: without this, one account
 * could outvote everyone. Done here, on the raw records, because the
 * nominator never leaves this file (`plain` drops it).
 */
export function onePerNominator(records) {
  const seen = new Set();
  return records.filter((r) => {
    const who = r.created?.userRecordName;
    const key = r.fields?.trailKey?.value;
    if (!who || !key) return true;
    const id = `${who}\n${key}`;
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

/** Every page of a query, up to `max` records. `more` says some were left out. */
export async function pagedQuery(db, query, { max = 1000, pageSize = 200 } = {}) {
  const raw = [];
  let response = check(await db.performQuery(query, { resultsLimit: Math.min(pageSize, max) }));
  raw.push(...response.records);
  while (hasMorePages(response) && raw.length < max) {
    response = check(await db.performQuery(response));
    raw.push(...response.records);
  }
  const kept = query.recordType === 'TrailNomination' ? onePerNominator(raw) : raw;
  return { records: kept.slice(0, max).map(plain), more: hasMorePages(response) || raw.length > max };
}

/**
 * CloudKit JS fields from plain values. A value that is already
 * `{ value, type }` (a TIMESTAMP, say) is sent as it is, so its type isn't
 * left for CloudKit to guess from a bare number.
 */
export function ckFields(fields) {
  const out = {};
  for (const [key, value] of Object.entries(fields)) {
    out[key] = value && typeof value === 'object' && 'value' in value ? value : { value };
  }
  return out;
}

export function connect({ CloudKit, containerIdentifier, apiToken, environment }) {
  CloudKit.configure({
    containers: [{
      containerIdentifier,
      environment,
      apiTokenAuth: {
        apiToken,
        persist: true,
        signInButton: { id: 'apple-sign-in', theme: 'black' },
        signOutButton: { id: 'apple-sign-out', theme: 'black' },
      },
    }],
  });
  const container = CloudKit.getDefaultContainer();
  const db = container.publicCloudDatabase;

  return {
    /** The signed-in user, or null. */
    setUpAuth: () => container.setUpAuth(),
    whenUserSignsIn: () => container.whenUserSignsIn(),
    whenUserSignsOut: () => container.whenUserSignsOut(),

    /**
     * Records of `recordType`, newest first, following pages up to `max`.
     * `equals` is [field, value]; `sinceMs` keeps records created since then.
     */
    query(recordType, { equals, sinceMs, max = 1000, pageSize = 200 } = {}) {
      return pagedQuery(db, buildQuery(recordType, { equals, sinceMs }), { max, pageSize });
    },

    fetch: (recordNames) => fetchExisting(db, recordNames),

    /**
     * Creates one record named `recordName`. With no change tag, CloudKit
     * treats the save as a create (unverified against a live container).
     */
    async createNamed(recordType, recordName, fields) {
      const response = check(await db.saveRecords([{ recordType, recordName, fields: ckFields(fields) }]));
      return plain(response.records[0]);
    },

    /**
     * Replaces `recordName` in one step: CloudKit's forceReplace ignores the
     * change tag and keeps none of the old record's fields that aren't sent.
     * Atomic, so the record is never briefly missing. (The batch API's name
     * is from Apple's docs; unverified against a live container. If it
     * fails, the old record is untouched.)
     */
    async replaceNamed(recordType, recordName, fields) {
      const response = check(await db.newRecordsBatch()
        .forceReplace({ recordType, recordName, fields: ckFields(fields) })
        .commit());
      return plain(response.records[0]);
    },

    /** Creates one record with `fields` (plain values). */
    async create(recordType, fields) {
      const response = check(await db.saveRecords([{ recordType, fields: ckFields(fields) }]));
      return plain(response.records[0]);
    },

    /** Deletes records by name; ones already gone count as deleted. */
    async delete(recordNames) {
      for (let i = 0; i < recordNames.length; i += 200) {
        onlyRealErrors(await db.deleteRecords(recordNames.slice(i, i + 200)));
      }
    },
  };
}
