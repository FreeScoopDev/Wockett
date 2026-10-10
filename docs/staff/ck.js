// The one place the dashboard talks to CloudKit JS (Apple's library, loaded
// from Apple's CDN by index.html). Everything else works on plain records, so
// the rules in logic.js are tested without a network.
//
// Every call is made as the signed-in iCloud user. CloudKit's roles decide
// what that user may read, write and delete; this file grants nothing.

/** A CloudKit JS record as the plain shape logic.js uses. The creator is left out on purpose. */
export function plain(record) {
  const fields = {};
  for (const [key, field] of Object.entries(record.fields ?? {})) fields[key] = field?.value;
  return {
    recordName: record.recordName,
    recordType: record.recordType,
    created: record.created?.timestamp ?? 0,
    fields,
  };
}

/** Throws a response's first error, so every call fails the same way. */
function check(response) {
  if (response?.hasErrors) throw response.errors[0];
  return response;
}

/** Errors for records that are already gone are not failures when deleting. */
function onlyRealErrors(response) {
  const errors = (response?.errors ?? []).filter((e) => !['UNKNOWN_ITEM', 'NOT_FOUND'].includes(e.ckErrorCode));
  if (errors.length) throw errors[0];
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
    async query(recordType, { equals, sinceMs, max = 1000, pageSize = 200 } = {}) {
      const filterBy = [];
      if (equals) {
        filterBy.push({ fieldName: equals[0], comparator: 'EQUALS', fieldValue: { value: equals[1] } });
      }
      if (sinceMs !== undefined) {
        filterBy.push({ systemFieldName: 'createdTimestamp', comparator: 'GREATER_THAN_OR_EQUALS',
                        fieldValue: { value: sinceMs } });
      }
      const query = { recordType, filterBy, sortBy: [{ systemFieldName: 'createdTimestamp', ascending: false }] };
      const out = [];
      let response = check(await db.performQuery(query, { resultsLimit: Math.min(pageSize, max) }));
      out.push(...response.records.map(plain));
      while (response.moreRecordsComing && out.length < max) {
        response = check(await db.performQuery(response));
        out.push(...response.records.map(plain));
      }
      return { records: out.slice(0, max), more: response.moreRecordsComing || out.length > max };
    },

    /** The records that still exist among `recordNames`, by name. */
    async fetch(recordNames) {
      const found = new Map();
      for (let i = 0; i < recordNames.length; i += 200) {
        const response = await db.fetchRecords(recordNames.slice(i, i + 200));
        onlyRealErrors(response);
        for (const r of response.records ?? []) found.set(r.recordName, plain(r));
      }
      return found;
    },

    /** Creates one record with `fields` (plain values). */
    async create(recordType, fields) {
      const ckFields = {};
      for (const [key, value] of Object.entries(fields)) ckFields[key] = { value };
      const response = check(await db.saveRecords([{ recordType, fields: ckFields }]));
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
