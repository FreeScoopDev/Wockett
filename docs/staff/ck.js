// The one place the dashboard talks to CloudKit JS (Apple's library, loaded
// from Apple's CDN by index.html). Everything else works on plain records, so
// the rules in logic.js are tested without a network.
//
import { isGone, isValidRecordName, isClaimToken, contributionStatusName } from './logic.js';

// Every call is made as the signed-in iCloud user. CloudKit's roles decide
// what that user may read, write and delete; this file grants nothing.

/**
 * Record types whose creator the page may know: community content, where
 * the creator is the author (public anyway, and what Suspend acts on).
 * Never a report: who reported something stays out of the page.
 */
export const CREATOR_TYPES = new Set(['SharedRoute', 'WocketAchievement', 'Challenge', 'ChallengeEntry', 'CommunityName']);

/**
 * Fields the page never holds. A nomination's `claimToken` is the secret its
 * phone uses to find its own status record (spec feat/contribution-status):
 * shown, logged or copied anywhere, it would tell whoever saw it which status
 * is whose. `nominationStatusName` turns it into the status name here and
 * nothing else keeps it.
 */
export const NEVER_PLAIN_FIELDS = new Set(['claimToken']);

/** A CloudKit JS record as the plain shape logic.js uses. */
export function plain(record) {
  const fields = {};
  for (const [key, field] of Object.entries(record.fields ?? {})) {
    if (!NEVER_PLAIN_FIELDS.has(key)) fields[key] = field?.value;
  }
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

/**
 * Deletes `recordNames`, 200 per call. A call is not all-or-nothing: on a
 * real error, the error thrown carries `deleted`, how many were deleted
 * (calls before it, plus the records in its call that didn't fail). An error
 * that names no record may be about the whole call, so it counts that call
 * as deleting nothing: under-counting only means a re-run finds the rest.
 */
export async function deleteAll(db, recordNames) {
  let deleted = 0;
  for (let i = 0; i < recordNames.length; i += 200) {
    const chunk = recordNames.slice(i, i + 200);
    const response = await db.deleteRecords(chunk);
    const errors = (response?.errors ?? []).filter((e) => !isGone(e));
    if (errors.length) {
      const error = errors[0];
      const failed = new Set(errors.map((e) => e?.recordName));
      const inCall = failed.has(undefined) || failed.has(null) || failed.has('')
        ? 0
        : chunk.filter((name) => !failed.has(name)).length;
      try { error.deleted = deleted + inCall; } catch { /* a frozen error just has no count */ }
      throw error;
    }
    deleted += chunk.length;
  }
  return deleted;
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

/**
 * The query CloudKit JS is sent: newest first, optional equality and age
 * filters. `sinceMs` keeps records created at or after it, `beforeMs` records
 * created before it, `createdBy` records the account `createdBy` created.
 */
export function buildQuery(recordType, { equals, sinceMs, beforeMs, createdBy } = {}) {
  const filterBy = [];
  if (createdBy !== undefined) {
    // Needs `___createdBy` QUERYABLE on the type (TrailFactReport has it).
    filterBy.push({ systemFieldName: 'createdUserRecordName', comparator: 'EQUALS',
                    fieldValue: { value: { recordName: createdBy }, type: 'REFERENCE' } });
  }
  if (equals) {
    filterBy.push({ fieldName: equals[0], comparator: 'EQUALS', fieldValue: { value: equals[1] } });
  }
  if (sinceMs !== undefined) {
    filterBy.push({ systemFieldName: 'createdTimestamp', comparator: 'GREATER_THAN_OR_EQUALS',
                    fieldValue: { value: sinceMs, type: 'TIMESTAMP' } });
  }
  if (beforeMs !== undefined) {
    filterBy.push({ systemFieldName: 'createdTimestamp', comparator: 'LESS_THAN',
                    fieldValue: { value: beforeMs, type: 'TIMESTAMP' } });
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

/**
 * Who filed each report, kept inside this module and never returned: the
 * page may only ask whether a report came from the item's own author
 * (`reportedByAuthor`), which is how an owner's request to delete is told
 * from someone else claiming to be the owner.
 */
const reportFilers = new Map();

/** Whether the report named `reportRecordName` was filed by `authorAccount`. */
export function reportedByAuthor(reportRecordName, authorAccount) {
  const filer = reportFilers.get(reportRecordName);
  return Boolean(filer && authorAccount && filer === authorAccount);
}

/**
 * Walker reports: who made each one, as a token that means nothing outside
 * this page load (`walker-1`, `walker-2`, …), so the page can count each
 * walker once without ever holding the account. The same account gets the
 * same token for as long as the page is open.
 */
const reporterTokens = new Map();

export function reporterToken(account) {
  if (typeof account !== 'string' || !account) return undefined;
  if (!reporterTokens.has(account)) reporterTokens.set(account, `walker-${reporterTokens.size + 1}`);
  return reporterTokens.get(account);
}

/** Every page of a query, up to `max` records. `more` says some were left out. */
export async function pagedQuery(db, query, { max = 1000, pageSize = 200, onlyCreator } = {}) {
  let raw = [];
  let response = check(await db.performQuery(query, { resultsLimit: Math.min(pageSize, max) }));
  raw.push(...response.records);
  while (hasMorePages(response) && raw.length < max) {
    response = check(await db.performQuery(response));
    raw.push(...response.records);
  }
  // Checked here as well as by the query's filter: a filter CloudKit ignored
  // or misread must not hand back someone else's records for deletion. The
  // account itself stays in this file.
  if (onlyCreator !== undefined) raw = raw.filter((r) => onlyCreator && r.created?.userRecordName === onlyCreator);
  if (query.recordType === 'CommunityReport') {
    for (const r of raw) if (r.created?.userRecordName) reportFilers.set(r.recordName, r.created.userRecordName);
  }
  const kept = query.recordType === 'TrailNomination' ? onePerNominator(raw) : raw;
  const records = [];
  for (const r of kept.slice(0, max)) {
    const out = plain(r);
    if (r.recordType === 'TrailFactReport') {
      const token = reporterToken(r.created?.userRecordName);
      if (token) out.reporter = token;
    }
    if (r.recordType === 'TrailNomination') {
      const statusName = await nominationStatusName(r);
      if (statusName) out.statusName = statusName;
    }
    records.push(out);
  }
  return { records, more: hasMorePages(response) || raw.length > max };
}

/**
 * The status record name for a raw nomination's claim token, or undefined
 * when it has none (sent before the app wrote one) or one that isn't a UUID.
 * The token goes no further than this function.
 */
export async function nominationStatusName(record) {
  const token = record?.fields?.claimToken?.value;
  return isClaimToken(token) ? contributionStatusName(token) : undefined;
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
     * `equals` is [field, value]; `sinceMs` keeps records created since then,
     * `beforeMs` records created before then.
     */
    query(recordType, { equals, sinceMs, beforeMs, max = 1000, pageSize = 200 } = {}) {
      return pagedQuery(db, buildQuery(recordType, { equals, sinceMs, beforeMs }), { max, pageSize });
    },

    /**
     * Records of `recordType` that `account` created, newest first: the
     * filter is sent to CloudKit and checked again on what comes back. The
     * records come back without the account.
     */
    queryByCreator(recordType, account, { max = 5000, pageSize = 200 } = {}) {
      return pagedQuery(db, buildQuery(recordType, { createdBy: account }), { max, pageSize, onlyCreator: account });
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

    /**
     * Deletes records by name; ones already gone count as deleted. A call is
     * not all-or-nothing, so a failure carries `deleted`: how many of
     * `recordNames` were deleted, including any in the failing call (`deleteAll`).
     */
    delete: (recordNames) => deleteAll(db, recordNames),
  };
}
